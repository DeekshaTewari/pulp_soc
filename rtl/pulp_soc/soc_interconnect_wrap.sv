//-----------------------------------------------------------------------------
// Title         : SoC Interconnect Wrapper
//-----------------------------------------------------------------------------
// File          : soc_interconnect_wrap_v2.sv
// Author        : Manuel Eggimann  <meggimann@iis.ee.ethz.ch>
// Created       : 30.10.2020
//-----------------------------------------------------------------------------
// Description :
// This module instantiates the SoC interconnect and attaches the various SoC
// ports. Furthermore, the wrapper also instantiates the required protocol converters
// (AXI, APB).
//-----------------------------------------------------------------------------
// Copyright (C) 2013-2020 ETH Zurich, University of Bologna
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//-----------------------------------------------------------------------------

`include "soc_mem_map.svh"
`include "tcdm_macros.svh"
`include "axi/assign.svh"


module soc_interconnect_wrap
    import pkg_soc_interconnect::addr_map_rule_t;
    #(
      parameter int  NR_HWPE_PORTS = 0,
      parameter int  NR_L2_PORTS = 4,
      // AXI Input Plug
      localparam int AXI_IN_ADDR_WIDTH = 32, // All addresses in the SoC must be 32-bit
      localparam int AXI_IN_DATA_WIDTH = 64, // The internal AXI->TCDM protocol converter does not support any other
                                             // datawidths than 64-bit
      parameter int  AXI_IN_ID_WIDTH = 6,
      parameter int  AXI_USER_WIDTH = 6,
      // Axi Output Plug
      localparam int AXI_OUT_ADDR_WIDTH = 32, // All addresses in the SoC must be 32-bit
      localparam int AXI_OUT_DATA_WIDTH = 32  // The internal TCDM->AXI protocol converter does not support any other
                                              // datawidths than 32-bit
    ) (
       input logic clk_i,
       input logic rst_ni,
       input logic test_en_i,
       XBAR_TCDM_BUS.Slave      tcdm_fc_data, //Data Port of the Fabric Controller
       XBAR_TCDM_BUS.Slave      tcdm_fc_instr, //Instruction Port of the Fabric Controller
       XBAR_TCDM_BUS.Slave      tcdm_udma_tx, //TX Channel for the uDMA
       XBAR_TCDM_BUS.Slave      tcdm_udma_rx, //RX Channel for the uDMA
       XBAR_TCDM_BUS.Slave      tcdm_debug, //Debug access port from either the legacy or the riscv-debug unit
       XBAR_TCDM_BUS.Slave      tcdm_hwpe[NR_HWPE_PORTS], //Hardware Processing Element ports
       AXI_BUS.Slave            axi_master_plug, // Normaly used for cluster -> SoC communication
       AXI_BUS.Master           axi_slave_plug, // Normaly used for SoC -> cluster communication
       APB_BUS.Master           apb_peripheral_bus, // Connects to all the SoC Peripherals
       XBAR_TCDM_BUS.Master     l2_interleaved_slaves[NR_L2_PORTS], // Connects to the interleaved memory banks
       XBAR_TCDM_BUS.Master     l2_private_slaves[2], // Connects to core-private memory banks
       XBAR_TCDM_BUS.Master     boot_rom_slave, //Connects to the bootrom
       AXI_BUS.Master           mask_gen_slave,
       AXI_BUS.Master           mask_decompress_slave
     );

    //**Do not change these values unles you verified that all downstream IPs are properly parametrized and support it**
    localparam ADDR_WIDTH = 32;
    localparam DATA_WIDTH = 32;


    //////////////////////////////////////////////////////////////
    // 64-bit AXI to TCDM Bridge (Cluster to SoC communication) //
    //////////////////////////////////////////////////////////////
    XBAR_TCDM_BUS axi_bridge_2_interconnect[pkg_soc_interconnect::NR_CLUSTER_2_SOC_TCDM_MASTER_PORTS](); //We need 4
                                                                                                         //32-bit TCDM
                                                                                                         //ports to
                                                                                                         //achieve full
                                                                                                         //bandwidth
                                                                                                         //with one
                                                                                                         //64-bit AXI
                                                                                                         //port

    axi64_2_lint32_wrap #(
                     .AXI_USER_WIDTH(AXI_USER_WIDTH),
                     .AXI_ID_WIDTH(AXI_IN_ID_WIDTH)
                     ) i_axi64_to_lint32(
                                         .clk_i,
                                         .rst_ni,
                                         .test_en_i,
                                         .axi_master(axi_master_plug),
                                         .tcdm_slaves(axi_bridge_2_interconnect)
                                         );



    ////////////////////////////////////////
    // Address Rules for the interconnect //
    ////////////////////////////////////////
    localparam NR_RULES_L2_DEMUX = 4;
    //Everything that is not routed to port 1 or 2 ends up in port 0 by default
    localparam addr_map_rule_t [NR_RULES_L2_DEMUX-1:0] L2_DEMUX_RULES = '{
       '{ idx: 1 , start_addr: `SOC_MEM_MAP_PRIVATE_BANK0_START_ADDR , end_addr: `SOC_MEM_MAP_PRIVATE_BANK1_END_ADDR} , //Both , bank0 and bank1 are in the  same address block
       '{ idx: 1 , start_addr: `SOC_MEM_MAP_BOOT_ROM_START_ADDR      , end_addr: `SOC_MEM_MAP_BOOT_ROM_END_ADDR}      ,
       '{ idx: 2 , start_addr: `SOC_MEM_MAP_TCDM_START_ADDR          , end_addr: `SOC_MEM_MAP_TCDM_END_ADDR }         ,
       '{ idx: 2 , start_addr: `SOC_MEM_MAP_TCDM_ALIAS_START_ADDR    , end_addr: `SOC_MEM_MAP_TCDM_ALIAS_END_ADDR}};

    localparam NR_RULES_INTERLEAVED_REGION = 2;
    localparam addr_map_rule_t [NR_RULES_INTERLEAVED_REGION-1:0] INTERLEAVED_ADDR_SPACE = '{
       '{ idx: 1 , start_addr: `SOC_MEM_MAP_TCDM_START_ADDR          , end_addr: `SOC_MEM_MAP_TCDM_END_ADDR },
       '{ idx: 1 , start_addr: `SOC_MEM_MAP_TCDM_ALIAS_START_ADDR    , end_addr: `SOC_MEM_MAP_TCDM_ALIAS_END_ADDR}};

    localparam NR_RULES_CONTIG_CROSSBAR = 3;
    localparam addr_map_rule_t [NR_RULES_CONTIG_CROSSBAR-1:0] CONTIGUOUS_CROSSBAR_RULES = '{
        '{ idx: 0 , start_addr: `SOC_MEM_MAP_PRIVATE_BANK0_START_ADDR , end_addr: `SOC_MEM_MAP_PRIVATE_BANK0_END_ADDR} ,
        '{ idx: 1 , start_addr: `SOC_MEM_MAP_PRIVATE_BANK1_START_ADDR , end_addr: `SOC_MEM_MAP_PRIVATE_BANK1_END_ADDR} ,
        '{ idx: 2 , start_addr: `SOC_MEM_MAP_BOOT_ROM_START_ADDR      , end_addr: `SOC_MEM_MAP_BOOT_ROM_END_ADDR}};

    localparam NR_RULES_AXI_CROSSBAR = 4;
    localparam addr_map_rule_t [NR_RULES_AXI_CROSSBAR-1:0] AXI_CROSSBAR_RULES = '{
       '{ idx: 0, start_addr: `SOC_MEM_MAP_AXI_PLUG_START_ADDR,    end_addr: `SOC_MEM_MAP_AXI_PLUG_END_ADDR},
       '{ idx: 1, start_addr: `SOC_MEM_MAP_PERIPHERALS_START_ADDR, end_addr: `SOC_MEM_MAP_PERIPHERALS_END_ADDR},
       '{ idx: 2, start_addr: `SOC_MEM_MAP_MASK_GEN_START_ADDR, end_addr: `SOC_MEM_MAP_MASK_GEN_END_ADDR},
       '{ idx: 3, start_addr: `SOC_MEM_MAP_MASK_DECOMPRESS_START_ADDR, end_addr: `SOC_MEM_MAP_MASK_DECOMPRESS_END_ADDR}};

    //////////////////////////////
    // Instantiate Interconnect //
    //////////////////////////////


    //Internal wiring to APB protocol converter
    AXI_BUS #(.AXI_ADDR_WIDTH(32),
              .AXI_DATA_WIDTH(32),
              .AXI_ID_WIDTH(pkg_soc_interconnect::AXI_ID_OUT_WIDTH),
              .AXI_USER_WIDTH(AXI_USER_WIDTH)
              ) axi_to_axi_lite_bridge();

    //Wiring signals to interconncet. Unfortunately Synopsys-2019.3 does not support assignment patterns in port lists
    //directly
    XBAR_TCDM_BUS master_ports[pkg_soc_interconnect::NR_TCDM_MASTER_PORTS](); //increase the package localparma as well
                                //if you want to add new master ports. The parameter is used by other IPs to calcualte
                                //the required AXI ID width.
    `TCDM_ASSIGN_INTF(master_ports[0], tcdm_fc_data)
    `TCDM_ASSIGN_INTF(master_ports[1], tcdm_fc_instr)
    `TCDM_ASSIGN_INTF(master_ports[2], tcdm_udma_tx)
    `TCDM_ASSIGN_INTF(master_ports[3], tcdm_udma_rx)
    `TCDM_ASSIGN_INTF(master_ports[4], tcdm_debug)

    //Assign the 4 master ports from the AXI plug to the interface array

    //Synopsys 2019.3 has a bug; It doesn't handle expressions for array indices on the left-hand side of assignments.
    // Using a macro instead of a package parameter is an ugly but necessary workaround.
    // E.g. assign a[param+i] = b[i] doesn't work, but assign a[i] = b[i-param] does.
    `define NR_SOC_TCDM_MASTER_PORTS 5
    for (genvar i = 0; i < 4; i++) begin
        `TCDM_ASSIGN_INTF(master_ports[`NR_SOC_TCDM_MASTER_PORTS + i], axi_bridge_2_interconnect[i])
    end

    XBAR_TCDM_BUS contiguous_slaves[3]();
    `TCDM_ASSIGN_INTF(l2_private_slaves[0], contiguous_slaves[0])
    `TCDM_ASSIGN_INTF(l2_private_slaves[1], contiguous_slaves[1])
    `TCDM_ASSIGN_INTF(boot_rom_slave, contiguous_slaves[2])

    AXI_BUS #(.AXI_ADDR_WIDTH(32),
              .AXI_DATA_WIDTH(32),
              .AXI_ID_WIDTH(pkg_soc_interconnect::AXI_ID_OUT_WIDTH),
              .AXI_USER_WIDTH(AXI_USER_WIDTH)
              ) axi_slaves[4]();
    `AXI_ASSIGN(axi_slave_plug, axi_slaves[0])
    `AXI_ASSIGN(axi_to_axi_lite_bridge, axi_slaves[1])
    `AXI_ASSIGN(mask_gen_slave, axi_slaves[2])
    `AXI_ASSIGN(mask_decompress_slave, axi_slaves[3])

    //Interconnect instantiation
    soc_interconnect #(
                       .NR_MASTER_PORTS(pkg_soc_interconnect::NR_TCDM_MASTER_PORTS), // FC instructions, FC data, uDMA RX, uDMA TX, debug access, 4 four 64-bit
                                              // axi plug
                       .NR_MASTER_PORTS_INTERLEAVED_ONLY(NR_HWPE_PORTS), // HWPEs (PULP accelerators) only have access
                                                                         // to the interleaved memory region
                       .NR_ADDR_RULES_L2_DEMUX(NR_RULES_L2_DEMUX),
                       .NR_SLAVE_PORTS_INTERLEAVED(NR_L2_PORTS), // Number of interleaved memory banks
                       .NR_ADDR_RULES_SLAVE_PORTS_INTLVD(NR_RULES_INTERLEAVED_REGION),
                       .NR_SLAVE_PORTS_CONTIG(3), // Bootrom + number of private memory banks (normally 1 for
                                                  // programm instructions and 1 for programm stack )
                       .NR_ADDR_RULES_SLAVE_PORTS_CONTIG(NR_RULES_CONTIG_CROSSBAR),
                       .NR_AXI_SLAVE_PORTS(4), // 1 for AXI to cluster, 1 for SoC peripherals (converted to APB)
                       .NR_ADDR_RULES_AXI_SLAVE_PORTS(NR_RULES_AXI_CROSSBAR),
                       .AXI_MASTER_ID_WIDTH(1), //Doesn't need to be changed. All axi masters in the current
                                                //interconnect come from a TCDM protocol converter and thus do not have and AXI ID.
                                                //However, the unerlaying IPs do not support an ID lenght of 0, thus we use 1.
                       .AXI_USER_WIDTH(AXI_USER_WIDTH)
                       ) i_soc_interconnect (
                                             .clk_i,
                                             .rst_ni,
                                             .test_en_i,
                                             .master_ports(master_ports),
                                             .master_ports_interleaved_only(tcdm_hwpe),
                                             .addr_space_l2_demux(L2_DEMUX_RULES),
                                             .addr_space_interleaved(INTERLEAVED_ADDR_SPACE),
                                             .interleaved_slaves(l2_interleaved_slaves),
                                             .addr_space_contiguous(CONTIGUOUS_CROSSBAR_RULES),
                                             .contiguous_slaves(contiguous_slaves),
                                             .addr_space_axi(AXI_CROSSBAR_RULES),
                                             .axi_slaves(axi_slaves)
                                             );


    ////////////////////////
    // AXI4 to APB Bridge //
    ///////////////////////////////////////////////////////////////////////////////////////////
    // We do the conversion in two steps: We convert AXI4 to AXI4 lite and from there to APB //
    ///////////////////////////////////////////////////////////////////////////////////////////

    AXI_LITE #(
               .AXI_ADDR_WIDTH(32),
               .AXI_DATA_WIDTH(32)) axi_lite_to_apb_bridge();

    axi_to_axi_lite_intf #(
                           .AXI_ADDR_WIDTH(32),
                           .AXI_DATA_WIDTH(32),
                           .AXI_ID_WIDTH(pkg_soc_interconnect::AXI_ID_OUT_WIDTH),
                           .AXI_USER_WIDTH(AXI_USER_WIDTH),
                           .AXI_MAX_WRITE_TXNS(1),
                           .AXI_MAX_READ_TXNS(1),
                           .FALL_THROUGH(1)
                           ) i_axi_to_axi_lite (
                                                .clk_i,
                                                .rst_ni,
                                                .testmode_i(test_en_i),
                                                .slv(axi_to_axi_lite_bridge),
                                                .mst(axi_lite_to_apb_bridge)
                                                );

    // The AXI-Lite to APB bridge is capable of connecting one AXI to multiple APB ports using address mapping rules.
    // We do not use this feature and just supply a default rule that matches everything in the peripheral region

    localparam addr_map_rule_t [0:0] APB_BRIDGE_RULES = '{
        '{ idx: 0, start_addr: `SOC_MEM_MAP_PERIPHERALS_START_ADDR, end_addr: `SOC_MEM_MAP_PERIPHERALS_END_ADDR}};

    axi_lite_to_apb_intf #(
                           .NoApbSlaves(1),
                           .NoRules(1),
                           .AddrWidth(32),
                           .DataWidth(32),
                           .rule_t(addr_map_rule_t)
                           ) i_axi_lite_to_apb (
                                                .clk_i,
                                                .rst_ni,
                                                .slv(axi_lite_to_apb_bridge),
                                                .paddr_o(apb_peripheral_bus.paddr),
                                                .pprot_o(),
                                                .pselx_o(apb_peripheral_bus.psel),
                                                .penable_o(apb_peripheral_bus.penable),
                                                .pwrite_o(apb_peripheral_bus.pwrite),
                                                .pwdata_o(apb_peripheral_bus.pwdata),
                                                .pstrb_o(),
                                                .pready_i(apb_peripheral_bus.pready),
                                                .prdata_i(apb_peripheral_bus.prdata),
                                                .pslverr_i(apb_peripheral_bus.pslverr),
                                                .addr_map_i(APB_BRIDGE_RULES)
                                                );


endmodule : soc_interconnect_wrap
