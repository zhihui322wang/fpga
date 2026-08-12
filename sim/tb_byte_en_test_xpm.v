//-----------------------------------------------------------------
// tb_byte_en_test_xpm.v — variant with vendor="xilinx" to repro the bug
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module tb_byte_en_test_xpm;

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

  // Use vendor="xilinx" — same as full SoC simulation
  riscv32_top #(
      .instr_databits    (32),
      .init_addr_width   (ADDR_W),
      .init_addr_depth   (DEPTH),
      .vendor            ("xilinx"),
      .instr_ram_type    ("block"),
      .init_blockram_size(8),
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

  // Monitor
  wire [3:0] sram_wren_byte_b = dut.u_instru_ram.wren_byte_b;
  wire       sram_wren_b      = dut.u_instru_ram.wren_b;
  wire [31:0] sram_data_b     = dut.u_instru_ram.data_b;
  wire [12:0] sram_addr_b     = dut.u_instru_ram.address_b;
  localparam TARGET_WORD = 13'h5D6;

  initial clk = 0;
  always #10 clk = ~clk;

  initial begin
    $dumpfile("tb_byte_en_xpm.vcd");
    $dumpvars(0, tb_byte_en_test_xpm);
  end

  always @(posedge clk) begin
    if (sram_wren_b && sram_addr_b == TARGET_WORD) begin
      $display("[%0t] *** TARGET 0x5D6 WR: byte_en=%b data=0x%08x ***",
               $time, sram_wren_byte_b, sram_data_b);
    end
  end

  always @(posedge clk) begin
    if (req) begin ack <= 1'b1; rdata <= 32'h0; end
    else ack <= 1'b0;
  end

  task jwrite;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge clk);
      program_wr = 1'b1; program_waddr = addr[ADDR_W-1:0]; program_wdata = data;
      @(posedge clk);
      program_wr = 1'b0;
    end
  endtask

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

  reg [31:0] readback;
  initial begin
    reset_l = 1'b0; program_wr = 1'b0; program_waddr = 0; program_wdata = 0;
    irq = 0; ack = 0; rdata = 0;

    $display("=== XPM Vendor Test (vendor=xilinx) ===");
    #100;

    // Load same test program
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

    #100;
    reset_l = 1'b1;  // CPU starts

    #2000;
    reset_l = 1'b0;
    #100;

    read_sram(TARGET_WORD, readback);
    $display("RESULT: word[0x5D6] = 0x%08x", readback);
    if (readback == 32'h12340050)
      $display("PASS: byte-enable correct");
    else if (readback == 32'h00500050)
      $display("BUG REPRODUCED: both halves = 0x0050 — XPM model ignores byte-enable!");
    else
      $display("UNEXPECTED: 0x%08x", readback);
    $finish;
  end

  initial begin #500_000; $display("TIMEOUT"); $finish; end
endmodule
