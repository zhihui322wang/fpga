//-----------------------------------------------------------------
// tb_mdio_ctrl.v — MDIO Controller Testbench
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module tb_mdio_ctrl;

  reg clk, reset_l;
  wire mdc, mdio;

  reg        reg_req, reg_rhwl;
  reg  [4:0] reg_addr;
  reg  [31:0] reg_wdata;
  wire [31:0] reg_rdata;
  wire        reg_ack;

  mdio_ctrl u_dut (
      .clk(clk), .reset_l(reset_l),
      .mdc(mdc), .mdio(mdio),
      .reg_req(reg_req), .reg_rhwl(reg_rhwl),
      .reg_addr(reg_addr), .reg_wdata(reg_wdata),
      .reg_rdata(reg_rdata), .reg_ack(reg_ack)
  );

  // Mock PHY
  reg [15:0] phy_reg [0:31];
  reg mdio_out_r, mdio_drive;
  assign mdio = mdio_drive ? mdio_out_r : 1'bz;

  // MDIO monitor: capture 64 bits on rising MDC, MSB first
  reg capturing;
  reg [63:0] mdio_frame;
  reg [5:0] bit_pos;  // 0..63
  reg prev_mdc;

  initial begin
    for (int i = 0; i < 32; i++) phy_reg[i] = 16'h0000;
    phy_reg[0] = 16'h1000; phy_reg[1] = 16'h796D;
    phy_reg[2] = 16'h001C; phy_reg[3] = 16'hC915;
    mdio_drive = 0; capturing = 0; prev_mdc = 1;
  end

  always @(posedge clk) begin
    prev_mdc <= mdc;
    if (capturing) begin
      if (mdc && !prev_mdc) begin  // rising MDC
        // Store MSB first: bit 63 first, then 62, ..., down to 0
        mdio_frame[63 - bit_pos] <= mdio;
        bit_pos <= bit_pos + 1;
        if (bit_pos == 63) begin
          capturing <= 0;
          // Parse: ST=mdio_frame[63:62], OP=[61:60], PHYAD=[59:55], REGAD=[54:50], TA=[49:48], DATA=[47:32]
          $display("[%0t] PHY CAPTURE: ST=%b OP=%b PHY=%0d REG=%0d DATA=0x%04X",
                   $time, mdio_frame[63:62], mdio_frame[61:60],
                   mdio_frame[59:55], mdio_frame[54:50], mdio_frame[47:32]);
          if (mdio_frame[61:60] == 2'b10) begin  // READ
            $display("[%0t]   → READ phy=%0d reg=%0d = 0x%04X",
                     $time, mdio_frame[59:55], mdio_frame[54:50], phy_reg[mdio_frame[54:50]]);
          end else if (mdio_frame[61:60] == 2'b01) begin  // WRITE
            phy_reg[mdio_frame[54:50]] = mdio_frame[47:32];
            $display("[%0t]   → WRITE phy=%0d reg=%0d ← 0x%04X",
                     $time, mdio_frame[59:55], mdio_frame[54:50], mdio_frame[47:32]);
          end
        end
      end
    end else begin
      if (mdc && !prev_mdc && !mdio) begin  // rising MDC + mdio=0 = start
        capturing <= 1;
        bit_pos   <= 0;
        // First captured bit = ST[1]=0, store at MSB position 63
        mdio_frame[63] <= 1'b0;
      end
    end
  end

  initial clk = 0;
  always #10 clk = ~clk;

  initial begin
    reg_req = 0; reg_rhwl = 0; reg_addr = 0; reg_wdata = 0;
    reset_l = 0; #100; reset_l = 1; #200;

    // Test 1: Set PHYAD=1 (use negedge to drive)
    $display("=== Test 1: Set PHYAD=1 ===");
    @(negedge clk); reg_addr = 0; reg_wdata = 1; reg_rhwl = 0; reg_req = 1;
    @(negedge clk); reg_req = 0; #100;

    // Test 2: MDIO Write reg0=0x1300
    $display("=== Test 2: Write reg0=0x1300 ===");
    @(negedge clk); reg_addr = 1; reg_wdata = 0; reg_req = 1;
    @(negedge clk); reg_req = 0; #100;
    @(negedge clk); reg_addr = 2; reg_wdata = 16'h1300; reg_req = 1;
    @(negedge clk); reg_req = 0; #100;
    #200000;
    $display("  PHY reg[0] = 0x%04X (expect 0x1300)", phy_reg[0]);

    // Test 3: MDIO Read reg2 (PHY ID1)
    $display("=== Test 3: Read reg2 ===");
    @(negedge clk); reg_addr = 1; reg_wdata = 2; reg_req = 1;
    @(negedge clk); reg_req = 0; #100;
    @(negedge clk); reg_addr = 3; reg_wdata = 1; reg_req = 1;  // trigger read
    @(negedge clk); reg_req = 0; #100;
    #200000;
    @(negedge clk); reg_addr = 2; reg_rhwl = 1; reg_req = 1;  // read result
    @(negedge clk); reg_req = 0; #100;
    $display("  RDATA = 0x%04X (expect 0x001C)", reg_rdata[15:0]);

    $display("=== All tests done ===");
    $finish;
  end

  initial #5000000 $finish;
  initial begin $dumpfile("tb_mdio_ctrl.vcd"); $dumpvars(0, tb_mdio_ctrl); end

endmodule
