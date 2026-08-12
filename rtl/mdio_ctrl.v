//-----------------------------------------------------------------
// mdio_ctrl.v — MDIO Master (IEEE 802.3 Clause 22)
// clk=50MHz, MDC=clk/20=2.5MHz
//
// Register map (LCPU bus, 32-bit word addressing):
//   0x2000: PHYAD[4:0]       (write)
//   0x2001: REGAD[4:0]       (write)
//   0x2002: WDATA[15:0]      (write → triggers MDIO write)
//   0x2002: RDATA[15:0]      (read  → returns read data after MDIO read)
//   0x2003: CTRL              (write → bit[0]=1 triggers MDIO read)
//   0x2004: STATUS[1:0]       (read → bit[0]=busy, bit[1]=done)
//-----------------------------------------------------------------
module mdio_ctrl (
    input  clk, reset_l,
    output mdc,
    inout  mdio,
    input        reg_req, reg_rhwl,
    input  [4:0] reg_addr,
    input  [31:0] reg_wdata,
    output [31:0] reg_rdata,
    output        reg_ack
);

  // MDC gen: clk/20=2.5MHz
  reg [4:0] cnt;
  wire mdc_tick = (cnt == 5'd19);
  reg mdc_r;
  assign mdc = mdc_r;

  always @(posedge clk or negedge reset_l)
    if (!reset_l) cnt <= 0;
    else if (mdc_tick) cnt <= 0;
    else cnt <= cnt + 1;

  always @(posedge clk or negedge reset_l)
    if (!reset_l) mdc_r <= 1;
    else if (mdc_tick) mdc_r <= ~mdc_r;

  // MDIO tri-state
  reg mdio_oe, mdio_out;
  assign mdio = mdio_oe ? mdio_out : 1'bz;

  // Registers
  reg [4:0] phyad, regad;
  reg [15:0] wdata_reg, rdata_reg;
  reg busy, mdio_read_op;
  reg [31:0] ack_data;
  reg ack;

  // MDIO state machine
  reg [7:0] bit_cnt;   // 0..63 (preamble) + 0..63 (data)
  reg [31:0] shifter;  // 32-bit frame shifter
  reg [3:0] fsm;       // 0=IDLE, 1=PREAMBLE, 2=SEND, 3=TURNAROUND, 4=END

  assign reg_rdata = ack_data;
  assign reg_ack  = ack;

  always @(posedge clk or negedge reset_l)
    if (!reset_l) begin
      phyad <= 5'd1;  regad <= 0;  wdata_reg <= 0;  rdata_reg <= 0;
      busy <= 0;  mdio_read_op <= 0;  ack <= 0;  ack_data <= 0;
      bit_cnt <= 0;  shifter <= 0;  fsm <= 0;
      mdio_oe <= 0;  mdio_out <= 0;
    end else begin
      ack <= 0;

      // Register handling
      if (reg_req && !busy) begin
        ack <= 1;
        if (!reg_rhwl) begin  // WRITE
          case (reg_addr)
            5'd0: phyad <= reg_wdata[4:0];
            5'd1: regad <= reg_wdata[4:0];
            5'd2: begin
              wdata_reg <= reg_wdata[15:0];
              mdio_read_op <= 0;
              busy  <= 1;
              fsm   <= 1;
              $display("[%0t] MDIO WRITE START: phy=%0d reg=%0d data=0x%04X", $time, phyad, regad, reg_wdata[15:0]);
            end
            5'd3: begin  // trigger read
              mdio_read_op <= 1;
              busy  <= 1;
              fsm   <= 1;
              $display("[%0t] MDIO READ START: phy=%0d reg=%0d", $time, phyad, regad);
            end
          endcase
        end else begin  // READ
          case (reg_addr)
            5'd2: ack_data <= {16'd0, rdata_reg};
            default: ack_data <= 0;
          endcase
        end
      end

      // MDIO state machine
      if (fsm != 0 && mdc_tick) begin
        mdio_oe <= 1;  // drive the bus during active state
        if (mdc_r) begin  // falling edge
          bit_cnt <= bit_cnt + 1;

          case (fsm)
            1: begin  // PREAMBLE: 32 1's
              mdio_oe <= 0;  // tri-state (pull-up = 1)
              if (bit_cnt == 63) begin
                bit_cnt <= 0;
                fsm <= 2; // SEND
                // Build frame: ST(01) OP PHYAD REGAD TA DATA
                if (mdio_read_op)
                  shifter <= {2'b01, 2'b10, phyad, regad, 2'b00, 16'd0};
                else
                  shifter <= {2'b01, 2'b01, phyad, regad, 2'b10, wdata_reg};
              end
            end

            2: begin  // SEND: 32 data bits
              if (bit_cnt == 0)
                $display("[%0t] MDIO SEND: shifter=0x%08X", $time, shifter);
              if (bit_cnt < 32) begin
                mdio_out <= shifter[31 - bit_cnt];
              end else if (bit_cnt == 32) begin
                mdio_oe <= 0;  // TA: turn around
              end
              if (bit_cnt == 63) begin
                bit_cnt <= 0;
                fsm <= 0;  // back to IDLE
                busy <= 0;
                mdio_read_op <= 0;
                mdio_oe <= 0;
                $display("[%0t] MDIO DONE: rdata=0x%04X", $time, rdata_reg);
              end
            end
          endcase

        end else begin  // rising edge
          if (fsm >= 2 && bit_cnt >= 32 && bit_cnt < 48) begin  // TA + read data
            if (bit_cnt >= 34) begin  // data bits (skip TA bits 32,33)
              rdata_reg <= {rdata_reg[14:0], mdio};
            end
          end
        end
      end
    end

endmodule
