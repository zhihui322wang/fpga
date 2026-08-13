//===================================================================
// ila_stubs.v — 仿真专用 stub，替换 fpga_ila 的 soft_ila_top / ila_hub_top
//
// 目的：让 iverilog 在【不引入 ip库 完整 ILA RTL】的情况下编译 WebSoC，
//       从而快速验证核心逻辑（含 UART 复用 mux）。端口名/位宽与
//       ip库/fpga_ila.../rtl/soft_ila_top.v、ila_hub_top.v 完全一致，
//       保证顶层 webserver_cpu_top.v 的连接不被改动即可编译通过。
//
// 注意：本文件只用于仿真，绝不参与 Vivado 综合（综合用真实 ILA RTL）。
//===================================================================
`timescale 1ns / 1ps

module soft_ila_top #(
    parameter CORE_EN        = 1,
    parameter DATA_DEPTH     = 1024,
    parameter MAX_WINDOWS    = 4,
    parameter SAMPLE_HZ      = 32'd125000000,
    parameter RST_ACTIVE_LOW = 1,
    parameter NUM_PROBES     = 32,

    parameter PROBE0_WIDTH=1,  PROBE1_WIDTH=1,  PROBE2_WIDTH=1,  PROBE3_WIDTH=1,
    parameter PROBE4_WIDTH=1,  PROBE5_WIDTH=1,  PROBE6_WIDTH=1,  PROBE7_WIDTH=1,
    parameter PROBE8_WIDTH=1,  PROBE9_WIDTH=1,  PROBE10_WIDTH=1, PROBE11_WIDTH=1,
    parameter PROBE12_WIDTH=1, PROBE13_WIDTH=1, PROBE14_WIDTH=1, PROBE15_WIDTH=1,
    parameter PROBE16_WIDTH=1, PROBE17_WIDTH=1, PROBE18_WIDTH=1, PROBE19_WIDTH=1,
    parameter PROBE20_WIDTH=1, PROBE21_WIDTH=1, PROBE22_WIDTH=1, PROBE23_WIDTH=1,
    parameter PROBE24_WIDTH=1, PROBE25_WIDTH=1, PROBE26_WIDTH=1, PROBE27_WIDTH=1,
    parameter PROBE28_WIDTH=1, PROBE29_WIDTH=1, PROBE30_WIDTH=1, PROBE31_WIDTH=1
) (
    input  wire                  sample_clk,
    input  wire                  rst_in,
    input  wire                  jtag_clk,

    input  wire [PROBE0_WIDTH -1:0] probe0,
    input  wire [PROBE1_WIDTH -1:0] probe1,
    input  wire [PROBE2_WIDTH -1:0] probe2,
    input  wire [PROBE3_WIDTH -1:0] probe3,
    input  wire [PROBE4_WIDTH -1:0] probe4,
    input  wire [PROBE5_WIDTH -1:0] probe5,
    input  wire [PROBE6_WIDTH -1:0] probe6,
    input  wire [PROBE7_WIDTH -1:0] probe7,
    input  wire [PROBE8_WIDTH -1:0] probe8,
    input  wire [PROBE9_WIDTH -1:0] probe9,
    input  wire [PROBE10_WIDTH-1:0] probe10,
    input  wire [PROBE11_WIDTH-1:0] probe11,
    input  wire [PROBE12_WIDTH-1:0] probe12,
    input  wire [PROBE13_WIDTH-1:0] probe13,
    input  wire [PROBE14_WIDTH-1:0] probe14,
    input  wire [PROBE15_WIDTH-1:0] probe15,
    input  wire [PROBE16_WIDTH-1:0] probe16,
    input  wire [PROBE17_WIDTH-1:0] probe17,
    input  wire [PROBE18_WIDTH-1:0] probe18,
    input  wire [PROBE19_WIDTH-1:0] probe19,
    input  wire [PROBE20_WIDTH-1:0] probe20,
    input  wire [PROBE21_WIDTH-1:0] probe21,
    input  wire [PROBE22_WIDTH-1:0] probe22,
    input  wire [PROBE23_WIDTH-1:0] probe23,
    input  wire [PROBE24_WIDTH-1:0] probe24,
    input  wire [PROBE25_WIDTH-1:0] probe25,
    input  wire [PROBE26_WIDTH-1:0] probe26,
    input  wire [PROBE27_WIDTH-1:0] probe27,
    input  wire [PROBE28_WIDTH-1:0] probe28,
    input  wire [PROBE29_WIDTH-1:0] probe29,
    input  wire [PROBE30_WIDTH-1:0] probe30,
    input  wire [PROBE31_WIDTH-1:0] probe31,

    input  wire                  trigger_in,
    output wire                  trigger_out,
    output wire                  armed_out,

    input  wire                  reg_we,
    input  wire                  reg_re,
    input  wire [15:0]           reg_addr,
    input  wire [31:0]           reg_wdata,
    output wire [31:0]           reg_rdata
);
    assign trigger_out = 1'b0;
    assign armed_out   = 1'b0;
    assign reg_rdata   = 32'h0;
endmodule


module ila_hub_top #(
    parameter TRANSPORT      = 0,
    parameter [2:0] TRANSPORT_EN = 3'b000,
    parameter NUM_CORES      = 1,
    parameter ILA_CLK_HZ     = 125_000_000,
    parameter ILA_BAUD       = 115200,
    parameter REG_HOLD       = 4,
    parameter [47:0] ETH_MAC  = 48'h0,
    parameter [31:0] ETH_IP   = 32'h0,
    parameter [15:0] ETH_PORT = 16'h0
) (
    input  wire                  clk,
    input  wire                  rst,

    input  wire                  uart_rxd,
    output wire                  uart_txd,

    input  wire                  gmii_rx_clk,
    input  wire [7:0]            gmii_rxd,
    input  wire                  gmii_rx_dv,
    output wire [7:0]            gmii_txd,
    output wire                  gmii_tx_en,

    output wire [NUM_CORES-1:0]     core_reg_we,
    output wire [NUM_CORES-1:0]     core_reg_re,
    output wire [15:0]              core_reg_addr,
    output wire [31:0]              core_reg_wdata,
    input  wire [NUM_CORES*32-1:0]  core_reg_rdata,

    output wire                  core_jtag_clk,
    output wire                  core_jtag_rst
);
    // 仿真 stub：UART 不回显，寄存器总线静止，ETH 不驱动
    assign uart_txd       = 1'b1;
    assign gmii_txd       = 8'h0;
    assign gmii_tx_en     = 1'b0;
    assign core_reg_we    = {NUM_CORES{1'b0}};
    assign core_reg_re    = {NUM_CORES{1'b0}};
    assign core_reg_addr  = 16'h0;
    assign core_reg_wdata = 32'h0;
    assign core_jtag_clk  = 1'b0;
    assign core_jtag_rst  = 1'b0;
endmodule
