//===================================================================
// tb_uart_mux.v — 定向验证 UART RX 复用 mux 的两种极性
//
//   验证目标 (webserver_cpu_top.v:219-220):
//     ila_uart_rx = ~debug_sel ? uart_rx : 1'b1   // 调试模式(0) → ILA 独享
//     cpu_uart_rx =  debug_sel ? uart_rx : 1'b1   // 上传模式(1) → CPU 独享
//
//   通过层次路径读取 mux 输出，检查 4 种 (debug_sel, uart_rx) 组合。
//===================================================================
`timescale 1ns / 1ps

module tb_uart_mux;

  reg        clk_50m_in;
  reg        reset_l;
  reg        debug_sel;
  reg        uart_rx;

  wire       uart_tx;
  wire [3:0] led_o;

  wire       rgmii_txc;
  wire [3:0] rgmii_txd;
  wire       rgmii_tx_ctl;
  reg        rgmii_rxc;
  reg  [3:0] rgmii_rxd;
  reg        rgmii_rx_ctl;
  wire       Eth0_MDC;
  wire       Eth0_MDIO;
  wire       rgmii_reset_l;

  webserver_cpu_top #(.sim_mod(1)) u_dut (
      .clk_50m_in    (clk_50m_in),
      .reset_l       (reset_l),
      .rgmii_txc     (rgmii_txc),
      .rgmii_txd     (rgmii_txd),
      .rgmii_tx_ctl  (rgmii_tx_ctl),
      .rgmii_rxc     (rgmii_rxc),
      .rgmii_rxd     (rgmii_rxd),
      .rgmii_rx_ctl  (rgmii_rx_ctl),
      .Eth0_MDC      (Eth0_MDC),
      .Eth0_MDIO     (Eth0_MDIO),
      .rgmii_reset_l (rgmii_reset_l),
      .uart_rx       (uart_rx),
      .uart_tx       (uart_tx),
      .debug_sel     (debug_sel),
      .led_o         (led_o)
  );

  // 层次引用 mux 输出 (引用本身保证信号在仿真中不被优化)
  wire ila_rx = u_dut.ila_uart_rx;
  wire cpu_rx = u_dut.cpu_uart_rx;

  initial clk_50m_in = 1'b0;
  always #10 clk_50m_in = ~clk_50m_in;

  initial begin rgmii_rxc=0; rgmii_rxd=0; rgmii_rx_ctl=0; uart_rx=1'b1; end
  always #10 rgmii_rxc = ~rgmii_rxc;

  initial begin
    reset_l   = 1'b0;
    debug_sel = 1'b1;   // 初始 = 上传模式
    #200 reset_l = 1'b1;
  end

  integer errs;
  initial errs = 0;

  task check;
    input       exp_ila, exp_cpu;   // 期望: 1'b1 空闲 / 跟随 uart_rx
    input [7:0] tag;
    begin
      #5;  // 让组合逻辑稳定
      if (ila_rx !== exp_ila || cpu_rx !== exp_cpu) begin
        $display("FAIL [%0s]: ila_rx=%b(期望 %b)  cpu_rx=%b(期望 %b)",
                 tag, ila_rx, exp_ila, cpu_rx, exp_cpu);
        errs = errs + 1;
      end else begin
        $display("PASS [%0s]: ila_rx=%b  cpu_rx=%b", tag, ila_rx, cpu_rx);
      end
    end
  endtask

  initial begin
    #500;  // 等复位释放 + 逻辑稳定

    $display("============================================");
    $display(" UART RX 复用 mux 验证");
    $display("============================================");

    // ---- 上传模式 debug_sel=1: CPU 独享 ----
    uart_rx = 1'b0;  check(1'b1, 1'b0, "sel=1 rx=0");
    uart_rx = 1'b1;  check(1'b1, 1'b1, "sel=1 rx=1");

    // ---- 调试模式 debug_sel=0: ILA 独享 ----
    debug_sel = 1'b0;
    uart_rx = 1'b0;  check(1'b0, 1'b1, "sel=0 rx=0");
    uart_rx = 1'b1;  check(1'b1, 1'b1, "sel=0 rx=1");

    // ---- 切回上传模式再确认 ----
    debug_sel = 1'b1;
    uart_rx = 1'b0;  check(1'b1, 1'b0, "sel=1 rx=0 (切回)");

    $display("============================================");
    if (errs == 0)
      $display(" 全部 mux 检查通过 (5/5)");
    else
      $display(" %0d 项检查失败", errs);
    $display("============================================");
    $finish;
  end

  // 兜底超时
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end

endmodule
