//-----------------------------------------------------------------
// tb_cpu_channel_pkt.v — cpu_channel 包注入测试
// 验证 rx_byte_cnt 修复: 注入已知以太网包, 通过 CPU FIFO 读回并比对
//-----------------------------------------------------------------
`timescale 1ns / 1ps
`include "define.sv"

module tb_cpu_channel_pkt;

  // 参数 (与 webserver_cpu_top 保持一致)
  localparam CPU_BUF_ADDR_WIDTH = 12;
  localparam CPU_BUF_DATA_WIDTH = 8;
  localparam CPU_BUF_PARA_WIDTH = 1;

  // 时钟 / 复位
  reg clk;       // 125MHz MAC 域
  reg cpu_clk;   // 50MHz  CPU 域
  reg reset_l;

  // ---- mac_rx 激励信号 ----
  reg        mac_rx_sop;
  reg        mac_rx_en;
  reg  [7:0] mac_rx_data;
  reg        mac_rx_eop;

  // ---- mac_tx (不接) ----
  wire       mac_tx_sop;
  wire       mac_tx_en;
  wire [7:0] mac_tx_data;
  wire       mac_tx_eop;
  wire       mac_tx_err;

  wire [7:0] recv_pkt_drop_cnt;

  // ---- CPU 读 FIFO ----
  wire       cpu_rd_empty;
  reg        cpu_rd_rpkt_pop;
  wire [CPU_BUF_ADDR_WIDTH:0] cpu_rd_rpkt_len;
  wire [CPU_BUF_PARA_WIDTH-1:0] cpu_rd_rpkt_para;
  reg        cpu_rd_ren;
  reg  [CPU_BUF_ADDR_WIDTH-1:0] cpu_rd_raddr;
  wire [CPU_BUF_DATA_WIDTH-1:0] cpu_rd_rdata;
  wire       cpu_rd_reop_pre;

  // ---- CPU 写 FIFO (不用) ----
  wire       cpu_wr_full;
  reg        cpu_wr_wen;
  reg  [CPU_BUF_ADDR_WIDTH-1:0] cpu_wr_waddr;
  reg  [CPU_BUF_DATA_WIDTH-1:0] cpu_wr_wdata;
  reg        cpu_wr_wpkt_push;
  reg  [CPU_BUF_ADDR_WIDTH:0] cpu_wr_wpkt_len;
  reg  [CPU_BUF_PARA_WIDTH-1:0] cpu_wr_wpkt_para;

  // DUT
  cpu_channel #(
      .cpu_buf_addr_width      (CPU_BUF_ADDR_WIDTH),
      .cpu_buf_block_mode      ("false"),
      .cpu_buf_block_addr_width(3),
      .cpu_buf_data_width      (CPU_BUF_DATA_WIDTH),
      .cpu_buf_para_width      (CPU_BUF_PARA_WIDTH),
      .cpu_buf_data_ram_type   ("M9K"),
      .cpu_buf_para_ram_type   ("registers")
  ) u_dut (
      .clk             (clk),
      .reset_l         (reset_l),
      .cpu_clk         (cpu_clk),

      .mac_rx_sop      (mac_rx_sop),
      .mac_rx_en       (mac_rx_en),
      .mac_rx_data     (mac_rx_data),
      .mac_rx_eop      (mac_rx_eop),

      .mac_tx_sop      (mac_tx_sop),
      .mac_tx_en       (mac_tx_en),
      .mac_tx_data     (mac_tx_data),
      .mac_tx_eop      (mac_tx_eop),
      .mac_tx_err      (mac_tx_err),

      .recv_pkt_drop_cnt(recv_pkt_drop_cnt),
      .dbg_fifo_wdata  (),
      .dbg_fifo_wen    (),
      .dbg_fifo_push   (),

      .cpu_rd_empty    (cpu_rd_empty),
      .cpu_rd_rpkt_pop (cpu_rd_rpkt_pop),
      .cpu_rd_rpkt_len (cpu_rd_rpkt_len),
      .cpu_rd_rpkt_para(cpu_rd_rpkt_para),
      .cpu_rd_ren      (cpu_rd_ren),
      .cpu_rd_raddr    (cpu_rd_raddr),
      .cpu_rd_rdata    (cpu_rd_rdata),
      .cpu_rd_reop_pre (cpu_rd_reop_pre),

      .cpu_wr_full     (cpu_wr_full),
      .cpu_wr_wen      (cpu_wr_wen),
      .cpu_wr_waddr    (cpu_wr_waddr),
      .cpu_wr_wdata    (cpu_wr_wdata),
      .cpu_wr_wpkt_push(cpu_wr_wpkt_push),
      .cpu_wr_wpkt_len (cpu_wr_wpkt_len),
      .cpu_wr_wpkt_para(cpu_wr_wpkt_para)
  );

  //============================================================================
  // 时钟生成: clk=125MHz(8ns), cpu_clk=50MHz(20ns)
  //============================================================================
  initial clk = 1'b0;
  always #4 clk = ~clk;     // 125MHz

  initial cpu_clk = 1'b0;
  always #10 cpu_clk = ~cpu_clk;  // 50MHz

  //============================================================================
  // 复位
  //============================================================================
  initial begin
    reset_l = 1'b0;
    #200;
    reset_l = 1'b1;
    #100;
  end

  //============================================================================
  // 默认值
  //============================================================================
  initial begin
    mac_rx_sop  = 1'b0;
    mac_rx_en   = 1'b0;
    mac_rx_data = 8'h00;
    mac_rx_eop  = 1'b0;

    cpu_rd_rpkt_pop = 1'b0;
    cpu_rd_ren      = 1'b0;
    cpu_rd_raddr    = 12'd0;

    cpu_wr_wen       = 1'b0;
    cpu_wr_waddr     = 12'd0;
    cpu_wr_wdata     = 8'd0;
    cpu_wr_wpkt_push = 1'b0;
    cpu_wr_wpkt_len  = 13'd0;
    cpu_wr_wpkt_para = 1'b0;
  end

  //============================================================================
  // 参考包数据 (用户提供的 64 字节以太网帧)
  //============================================================================
  reg [7:0] ref_pkt [0:63];
  integer   pkt_len;
  initial begin
    pkt_len = 64;
    // DMAC: 30:22:cd:76:63:1a
    ref_pkt[0]  = 8'h30; ref_pkt[1]  = 8'h22; ref_pkt[2]  = 8'hCD;
    ref_pkt[3]  = 8'h76; ref_pkt[4]  = 8'h63; ref_pkt[5]  = 8'h1A;
    // SMAC: 00:21:85:c5:2b:8f
    ref_pkt[6]  = 8'h00; ref_pkt[7]  = 8'h21; ref_pkt[8]  = 8'h85;
    ref_pkt[9]  = 8'hC5; ref_pkt[10] = 8'h2B; ref_pkt[11] = 8'h8F;
    // EtherType: 0x0800 (IPv4)
    ref_pkt[12] = 8'h08; ref_pkt[13] = 8'h00;
    // IPv4 + UDP payload (50 bytes)
    ref_pkt[14] = 8'h45; ref_pkt[15] = 8'h00;
    ref_pkt[16] = 8'h00; ref_pkt[17] = 8'h32;
    ref_pkt[18] = 8'h21; ref_pkt[19] = 8'hB3;
    ref_pkt[20] = 8'h00; ref_pkt[21] = 8'h00;
    ref_pkt[22] = 8'h40; ref_pkt[23] = 8'h11;
    ref_pkt[24] = 8'h9D; ref_pkt[25] = 8'h6D;
    ref_pkt[26] = 8'hC0; ref_pkt[27] = 8'hA8;
    ref_pkt[28] = 8'h01; ref_pkt[29] = 8'h64;
    ref_pkt[30] = 8'hDE; ref_pkt[31] = 8'h49;
    ref_pkt[32] = 8'h1B; ref_pkt[33] = 8'h45;
    ref_pkt[34] = 8'h05; ref_pkt[35] = 8'h21;
    ref_pkt[36] = 8'h27; ref_pkt[37] = 8'h15;
    ref_pkt[38] = 8'h00; ref_pkt[39] = 8'h1E;
    ref_pkt[40] = 8'hB1; ref_pkt[41] = 8'h7A;
    ref_pkt[42] = 8'h00; ref_pkt[43] = 8'h00;
    ref_pkt[44] = 8'h00; ref_pkt[45] = 8'h00;
    ref_pkt[46] = 8'h00; ref_pkt[47] = 8'h00;
    ref_pkt[48] = 8'h00; ref_pkt[49] = 8'h00;
    ref_pkt[50] = 8'h00; ref_pkt[51] = 8'h00;
    ref_pkt[52] = 8'h00; ref_pkt[53] = 8'h00;
    ref_pkt[54] = 8'h00; ref_pkt[55] = 8'h00;
    ref_pkt[56] = 8'h00; ref_pkt[57] = 8'h00;
    ref_pkt[58] = 8'h77; ref_pkt[59] = 8'h77;
    ref_pkt[60] = 8'h77; ref_pkt[61] = 8'h77;
    ref_pkt[62] = 8'h77; ref_pkt[63] = 8'h77;
  end

  //============================================================================
  // 发包任务: 通过 mac_rx 接口发送
  // 在 negedge 驱动信号, 确保 posedge 时 DUT 稳定采样
  // 时序: SOP 与首字节同拍, EN 覆盖所有数据, EOP 与末字节同拍
  //============================================================================
  task send_pkt;
    input integer len;
    integer i;
    begin
      // 首字节: 在 negedge 预设, 下一个 posedge 被 DUT 采样
      @(negedge clk);
      mac_rx_sop  = 1'b1;
      mac_rx_en   = 1'b1;
      mac_rx_data = ref_pkt[0];
      mac_rx_eop  = 1'b0;

      // 中间字节
      for (i = 1; i < len; i = i + 1) begin
        @(negedge clk);
        mac_rx_sop  = 1'b0;
        mac_rx_en   = 1'b1;
        mac_rx_data = ref_pkt[i];
        mac_rx_eop  = (i == len - 1) ? 1'b1 : 1'b0;
      end

      // 结束: 撤除所有信号
      @(negedge clk);
      mac_rx_sop  = 1'b0;
      mac_rx_en   = 1'b0;
      mac_rx_data = 8'h00;
      mac_rx_eop  = 1'b0;
    end
  endtask

  // 全局接收缓冲区 (避免 iverilog task 端口不支持 unpacked array)
  reg [7:0] rcv_buf [0:2047];
  integer   rcv_len;

  //============================================================================
  // CPU 读包任务: 模拟固件的读包流程
  // 注意: dual_clock 模式下 FIFO CDC 需要足够同步时间
  //============================================================================
  task cpu_read_pkt;
    integer i, wait_cnt;
    begin
      // 等包到达 (cpu_rd_empty == 0)
      wait_cnt = 0;
      while (cpu_rd_empty !== 1'b0 && wait_cnt < 10000) begin
        @(posedge cpu_clk);
        wait_cnt = wait_cnt + 1;
      end

      if (wait_cnt >= 10000) begin
        $display("[%0t] CPU: 超时等待包", $time);
        rcv_len = 0;
      end else begin
        $display("[%0t] CPU: 检测到包, empty=%b", $time, cpu_rd_empty);

        // 等待 CDC 同步 + FIFO 指针稳定 (50个 cpu_clk 周期)
        repeat (50) @(posedge cpu_clk);

        // pop: 单周期脉冲
        @(negedge cpu_clk);
        cpu_rd_rpkt_pop = 1'b1;
        @(negedge cpu_clk);
        cpu_rd_rpkt_pop = 1'b0;
        cpu_rd_ren      = 1'b1;

        // 等 pop 脉冲跨时钟域生效
        repeat (50) @(posedge cpu_clk);

        rcv_len = cpu_rd_rpkt_len;
        $display("[%0t] CPU: 包长度=%0d bytes (raw=%0d)", $time, rcv_len, cpu_rd_rpkt_len);

        // 逐字节读
        for (i = 0; i < rcv_len && i < 2048; i = i + 1) begin
          @(negedge cpu_clk);
          cpu_rd_raddr = i[CPU_BUF_ADDR_WIDTH-1:0];
          @(posedge cpu_clk);
          @(posedge cpu_clk);  // 数据 RAM 读延迟 1 拍
          rcv_buf[i] = cpu_rd_rdata;
        end

        @(negedge cpu_clk);
        cpu_rd_ren = 1'b0;
      end
    end
  endtask

  //============================================================================
  // 主测试
  //============================================================================
  integer i, err_cnt;

  initial begin
    $display("============================================================");
    $display(" tb_cpu_channel_pkt — 包注入 + CPU读回验证");
    $display("============================================================");

    // 等复位释放
    @(posedge reset_l);
    #500;
    $display("[%0t] 复位释放, 开始测试", $time);

    // ------ Test 1: 发送已知包, CPU 读回验证 ------
    $display("--- Test 1: 注入 64 字节以太网包 ---");

    // 发包
    send_pkt(pkt_len);

    // 读回 (在 CPU 时钟域)
    cpu_read_pkt();
    $display("[%0t] CPU: 读回 %0d 字节", $time, rcv_len);

    // 对比
    err_cnt = 0;
    if (rcv_len != pkt_len) begin
      $display("FAIL: 长度不匹配! 期望=%0d, 实际=%0d", pkt_len, rcv_len);
      err_cnt = err_cnt + 1;
    end

    for (i = 0; i < rcv_len && i < pkt_len; i = i + 1) begin
      if (rcv_buf[i] !== ref_pkt[i]) begin
        $display("  byte[%0d] MISMATCH: exp=0x%02h, got=0x%02h", i, ref_pkt[i], rcv_buf[i]);
        err_cnt = err_cnt + 1;
        if (err_cnt > 20) begin
          $display("  ... (too many errors, stopping compare)");
          i = rcv_len;
        end
      end
    end

    if (err_cnt == 0) begin
      $display("PASS: 所有 %0d 字节数据完全匹配!", rcv_len);
    end else begin
      $display("FAIL: %0d 个字节不匹配", err_cnt);
    end

    // 打印前16字节和后16字节
    $display("--- 数据采样 (前16字节) ---");
    for (i = 0; i < 16; i = i + 1) begin
      $display("  [%0d] exp=0x%02h (%c) rcv=0x%02h (%c)",
               i, ref_pkt[i],
               (ref_pkt[i] >= 8'h20 && ref_pkt[i] < 8'h7F) ? ref_pkt[i] : ".",
               rcv_buf[i],
               (rcv_buf[i] >= 8'h20 && rcv_buf[i] < 8'h7F) ? rcv_buf[i] : ".");
    end

    $display("--- 数据采样 (后16字节) ---");
    for (i = pkt_len - 16; i < pkt_len; i = i + 1) begin
      $display("  [%0d] exp=0x%02h (%c) rcv=0x%02h (%c)",
               i, ref_pkt[i],
               (ref_pkt[i] >= 8'h20 && ref_pkt[i] < 8'h7F) ? ref_pkt[i] : ".",
               rcv_buf[i],
               (rcv_buf[i] >= 8'h20 && rcv_buf[i] < 8'h7F) ? rcv_buf[i] : ".");
    end

    // ------ Test 2: 丢包计数 ------
    $display("--- Test 2: 丢包计数 = %0d ---", recv_pkt_drop_cnt);

    #5000;
    $display("============================================================");
    $display(" 测试完成");
    $display("============================================================");
    $finish;
  end

  //============================================================================
  // 内部信号监控: 层级引用追踪 RX 数据通路
  //============================================================================
  always @(posedge clk) begin
    if (u_dut.u_ram2pktfifo_int.wen)
      $display("[%0t] DBG: wen=1 waddr=%0d wdata=0x%02h", $time,
               u_dut.u_ram2pktfifo_int.waddr, u_dut.u_ram2pktfifo_int.wdata);
    if (u_dut.u_ram2pktfifo_int.wpkt_push)
      $display("[%0t] DBG: ==== wpkt_push=1 wpkt_len=%0d full=%b ====", $time,
               u_dut.u_ram2pktfifo_int.wpkt_len, u_dut.u_ram2pktfifo_int.full);
  end

  //============================================================================
  // 超时保护
  //============================================================================
  initial begin
    #5000000;  // 5ms
    $display("ERROR: 仿真超时!");
    $finish;
  end

  //============================================================================
  // 波形输出
  //============================================================================
  initial begin
    $dumpfile("tb_cpu_channel_pkt.vcd");
    $dumpvars(0, tb_cpu_channel_pkt);
  end

endmodule
