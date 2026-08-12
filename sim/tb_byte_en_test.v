//-----------------------------------------------------------------
// tb_byte_en_test.v — 精确测试 byte-enable pipeline
// 复现 firmware 一样的两个 sh 半字写操作，监控关键信号
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module tb_byte_en_test;

  localparam ADDR_W = 13;
  localparam DEPTH  = 8192;

  reg                        clk;
  reg                        reset_l;
  wire                       req;
  wire                       rhwl;
  wire [                3:0] wr_byte_en;
  wire [               31:0] wdata;
  wire [               31:0] address;
  reg  [               31:0] rdata;
  reg                        ack;
  reg                        program_wr;
  reg  [      ADDR_W-1:0] program_waddr;
  reg  [               31:0] program_wdata;
  wire [               31:0] program_rdata;
  reg  [               31:0] irq;

  riscv32_top #(
      .instr_databits    (32),
      .init_addr_width   (ADDR_W),
      .init_addr_depth   (DEPTH),
      .vendor            (""),
      .instr_ram_type    ("registers"),
      .init_blockram_size(32),
      .enable_irq        (0),
      .enable_irq_qregs  (1),
      .progaddr_irq      (16)
  ) dut (
      .clk          (clk),
      .reset_l      (reset_l),
      .req          (req),
      .rhwl         (rhwl),
      .wr_byte_en   (wr_byte_en),
      .wdata        (wdata),
      .address      (address),
      .rdata        (rdata),
      .ack          (ack),
      .program_wr   (program_wr),
      .program_waddr(program_waddr),
      .program_wdata(program_wdata),
      .program_rdata(program_rdata),
      .irq          (irq)
  );

  // ── 内部信号监控 ──────────────────────────────
  wire [3:0] wr_byte_en_d = dut.wr_byte_en_d;
  wire [3:0] wr_byte_en_m_sig = dut.wr_byte_en_m;

  // riscv_reg → ramintf → SRAM 路径
  wire        req_m        = dut.req_m;
  wire [ 3:0] byte_en_m    = dut.wr_byte_en_m;

  // SRAM Port B 信号
  wire        sram_wren_b      = dut.u_instru_ram.wren_b;
  wire [ 3:0] sram_wren_byte_b = dut.u_instru_ram.wren_byte_b;
  wire [12:0] sram_addr_b      = dut.u_instru_ram.address_b;
  wire [31:0] sram_data_b      = dut.u_instru_ram.data_b;
  wire [31:0] sram_q_b         = dut.u_instru_ram.q_b;

  // ── 关键 word 地址 ────────────────────────────
  localparam TARGET_WORD = 13'h5D6;  // 0x1758 / 4

  // ── 时钟 50MHz ──────────────────────────────────
  initial clk = 0;
  always #10 clk = ~clk;

  // ── VCD ─────────────────────────────────────────
  initial begin
    $dumpfile("tb_byte_en_test.vcd");
    $dumpvars(0, tb_byte_en_test);
  end

  // ── SRAM Port B 写入监控 ───────────────────────
  always @(posedge clk) begin
    if (sram_wren_b) begin
      $display("[%0t] SRAM_B_WR: addr=0x%04x data=0x%08x byte_en=%b wstrb_m=%b wstrb_d=%b",
               $time, sram_addr_b, sram_data_b, sram_wren_byte_b, byte_en_m, wr_byte_en_d);
      if (sram_addr_b == TARGET_WORD) begin
        $display("  *** TARGET 0x5D6 WRITTEN! byte_en=%b data=0x%08x ***",
                 sram_wren_byte_b, sram_data_b);
      end
    end
  end

  // ── Bus 请求监控 ────────────────────────────────
  always @(posedge clk) begin
    if (req && address == 32'h1758) begin
      $display("[%0t] BUS to 0x1758: rhwl=%b wr_byte_en=%b", $time, rhwl, wr_byte_en);
    end
    if (req && address == 32'h175a) begin
      $display("[%0t] BUS to 0x175a: rhwl=%b wr_byte_en=%b", $time, rhwl, wr_byte_en);
    end
  end

  // ── 简单总线应答 ────────────────────────────────
  always @(posedge clk) begin
    if (req) begin
      ack   <= 1'b1;
      rdata <= 32'h0;
    end else begin
      ack <= 1'b0;
    end
  end

  // ── jwrite task ─────────────────────────────────
  task jwrite;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge clk);
      program_wr    = 1'b1;
      program_waddr = addr[ADDR_W-1:0];
      program_wdata = data;
      @(posedge clk);
      program_wr = 1'b0;
      $display("[%0t] LOAD: word[%0d] = 0x%08x", $time, addr, data);
    end
  endtask

  // ── 读 SRAM Port A（program_rdata） ─────────────
  task read_sram;
    input [ADDR_W-1:0] waddr;
    output [31:0] val;
    begin
      @(posedge clk);
      program_waddr = waddr;
      @(posedge clk);
      #1;
      val = program_rdata;
    end
  endtask

  // ── 主测试 ──────────────────────────────────────
  reg [31:0] readback;
  reg [31:0] word_val;

  initial begin
    // 初始化
    reset_l       = 1'b0;
    program_wr    = 1'b0;
    program_waddr = {ADDR_W{1'b0}};
    program_wdata = 32'h0;
    irq           = 32'h0;
    ack           = 1'b0;
    rdata         = 32'h0;

    $display("========================================");
    $display(" Byte-Enable Pipeline Test");
    $display("========================================");

    // 复位
    #100;
    $display("[%0t] Phase 1: Reset", $time);

    // 加载测试程序
    $display("[%0t] Phase 2: Loading test program", $time);

    // test_sh.hex 内容（10 words, little-endian 32-bit）
    jwrite(13'd0, 32'h68056605);
    jwrite(13'd1, 32'h23480813);
    jwrite(13'd2, 32'h75061d23);
    jwrite(13'd3, 32'h07936585);
    jwrite(13'd4, 32'h9c230500);
    jwrite(13'd5, 32'h000174f5);
    jwrite(13'd6, 32'h00010001);
    jwrite(13'd7, 32'h00010001);
    jwrite(13'd8, 32'h00010001);
    jwrite(13'd9, 32'ha0010001);

    // 验证加载：读回前几个 word
    $display("[%0t] Phase 3: Verify load", $time);
    read_sram(13'd0, word_val);
    $display("  word[0] = 0x%08x", word_val);
    read_sram(13'd1, word_val);
    $display("  word[1] = 0x%08x", word_val);

    // 读目标 word 初始值
    read_sram(TARGET_WORD, word_val);
    $display("  word[0x5D6] initial = 0x%08x", word_val);

    // 释放复位，CPU 开始执行
    $display("[%0t] Phase 4: Release reset (CPU starts)", $time);
    #100;
    reset_l = 1'b1;

    // 等待 CPU 执行完两个 sh 指令
    // 每个 store 需要 ~6 个周期（stmem + mem 状态），外加 nop 间隙
    // 总共约 30-40 个周期足够
    #2000;  // 1000ns = 50 cycles @ 20ns/cycle
    $display("[%0t] Phase 5: After CPU execution", $time);

    // 再拉低 reset，读 SRAM
    reset_l = 1'b0;
    #100;

    // 读目标 word
    read_sram(TARGET_WORD, readback);
    $display("");
    $display("========================================");
    $display(" RESULT: word[0x5D6] = 0x%08x", readback);
    $display("========================================");

    if (readback == 32'h12340050) begin
      $display(" PASS: byte-enable pipeline is CORRECT");
      $display("   upper half (tcp_src_port area) = 0x1234 ✓");
      $display("   lower half (tcp_dst_port area) = 0x0050 ✓");
    end else if (readback == 32'h00500050) begin
      $display(" FAIL: Bug reproduced — both halves = 0x0050");
      $display("   This means byte-enable = 1111 for the 2nd write");
    end else if (readback[15:0] == 16'h0050 && readback[31:16] == 16'h0000) begin
      $display(" PARTIAL: lower = 0x0050 ✓, upper = 0x0000 ✗");
      $display("   Expected upper = 0x1234");
    end else begin
      $display(" UNEXPECTED: word = 0x%08x", readback);
      $display("   upper = 0x%04x, lower = 0x%04x", readback[31:16], readback[15:0]);
    end

    $display("");
    $display("========================================");
    $display(" Test complete @ %0t", $time);
    $display("========================================");
    $finish;
  end

  // 超时
  initial begin #500_000; $display("TIMEOUT"); $finish; end

endmodule
