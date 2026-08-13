//-----------------------------------------------------------------
// tb_sram_debug.v — TCP DstPort=80 bug SRAM 写入追踪仿真
// 监控 SRAM Port B 每次写入，特别是 word 0x5D6 (tcp_src/dst_port)
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module tb_sram_debug;

  reg clk_50m_in, reset_l;
  wire [3:0] rgmii_txd, led_o;
  wire rgmii_txc, rgmii_tx_ctl, Eth0_MDC, Eth0_MDIO, rgmii_reset_l, uart_tx;
  reg rgmii_rxc, rgmii_rx_ctl, uart_rx;
  reg [3:0] rgmii_rxd;

  webserver_cpu_top #(.sim_mod(1)) u_dut (
      .clk_50m_in(clk_50m_in), .reset_l(reset_l),
      .rgmii_txc(rgmii_txc), .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl),
      .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
      .Eth0_MDC(Eth0_MDC), .Eth0_MDIO(Eth0_MDIO), .rgmii_reset_l(rgmii_reset_l),
      .uart_rx(uart_rx), .uart_tx(uart_tx), .debug_sel(1'b1), .led_o(led_o)
  );

  initial clk_50m_in = 1'b0;
  always #10 clk_50m_in = ~clk_50m_in;
  initial begin rgmii_rxc=0; rgmii_rxd=0; rgmii_rx_ctl=0; uart_rx=1; end
  always #10 rgmii_rxc = ~rgmii_rxc;
  initial begin reset_l=0; #200; reset_l=1; end

  initial begin
    $dumpfile("tb_sram_debug.vcd");
    $dumpvars(0, led_o);
  end

  // ================================================================
  // SRAM Port B 写入监控
  // 信号路径: webserver_cpu_top → lcpu_riscv_wrapper → riscv32_top → u_instru_ram
  // ================================================================
  wire        sram_wren_b;
  wire [ 3:0] sram_wren_byte_b;
  wire [12:0] sram_addr_b;
  wire [31:0] sram_data_b;
  wire [31:0] sram_q_b;

  // 层次路径经过 generate block: riscv_cpu_generation
  assign sram_wren_b      = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_instru_ram.wren_b;
  assign sram_wren_byte_b = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_instru_ram.wren_byte_b;
  assign sram_addr_b      = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_instru_ram.address_b;
  assign sram_data_b      = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_instru_ram.data_b;
  assign sram_q_b         = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_instru_ram.q_b;

  wire [3:0] byte_en_d = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.wr_byte_en_d;
  wire [3:0] byte_en_m = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.wr_byte_en_m;
  wire       req_m     = u_dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.req_m;

  localparam TARGET_WORD = 13'h5D6;  // 0x1758/4

  // 只追踪目标 region (变量区: 0x500-0x7FF) 的 Port B 写
  always @(posedge clk_50m_in) begin
    if (sram_wren_b && sram_addr_b >= 13'h500 && sram_addr_b <= 13'h7FF) begin
      $display("[%0t] SRAM_WR: addr=0x%04x data=0x%08x byte_en=%b",
               $time, sram_addr_b, sram_data_b, sram_wren_byte_b);
      if (sram_addr_b == TARGET_WORD) begin
        $display("  >>> TARGET WORD 0x5D6 WRITTEN: byte_en=%b data=0x%08x <<<",
                 sram_wren_byte_b, sram_data_b);
      end
    end
  end

  // 追踪 bus 对 tcp port 地址的读写
  always @(posedge clk_50m_in) begin
    if (u_dut.bus_req && !u_dut.bus_rhwl) begin
      if (u_dut.bus_address >= 32'h1758 && u_dut.bus_address <= 32'h175b) begin
        $display("[%0t] BUS_WR: addr=0x%05x data=0x%08x byte_en_m=%b",
                 $time, u_dut.bus_address, u_dut.bus_wdata, byte_en_m);
      end
    end
    if (u_dut.bus_req && u_dut.bus_rhwl) begin
      if (u_dut.bus_address >= 32'h1758 && u_dut.bus_address <= 32'h175b) begin
        $display("[%0t] BUS_RD: addr=0x%05x rdata=0x%08x",
                 $time, u_dut.bus_address, u_dut.bus_rdata);
      end
    end
    // 监控 conn_table[0].remote_port (0x16d0)
    if (u_dut.bus_req && !u_dut.bus_rhwl) begin
      if (u_dut.bus_address == 32'h16d0 || u_dut.bus_address == 32'h16d1) begin
        $display("[%0t] BUS_WR conn_table: addr=0x%05x data=0x%08x byte_en_m=%b",
                 $time, u_dut.bus_address, u_dut.bus_wdata, byte_en_m);
      end
    end
  end

  // ============== TCP SYN 包 (SrcPort=4660=0x1234, DstPort=80=0x0050) ==============
  reg [7:0] syn_pkt [0:53];
  integer i;
  initial begin
    syn_pkt[0]=8'h00; syn_pkt[1]=8'h00; syn_pkt[2]=8'h01; syn_pkt[3]=8'h02; syn_pkt[4]=8'h04; syn_pkt[5]=8'h05;
    syn_pkt[6]=8'h9c; syn_pkt[7]=8'h2d; syn_pkt[8]=8'hcd; syn_pkt[9]=8'hac; syn_pkt[10]=8'h8f; syn_pkt[11]=8'ha4;
    syn_pkt[12]=8'h08; syn_pkt[13]=8'h00;
    syn_pkt[14]=8'h45; syn_pkt[15]=8'h00; syn_pkt[16]=8'h00; syn_pkt[17]=8'h28;
    syn_pkt[18]=8'h00; syn_pkt[19]=8'h01; syn_pkt[20]=8'h40; syn_pkt[21]=8'h00;
    syn_pkt[22]=8'h40; syn_pkt[23]=8'h06; syn_pkt[24]=8'h00; syn_pkt[25]=8'h00;
    syn_pkt[26]=8'ha9; syn_pkt[27]=8'hfe; syn_pkt[28]=8'h5c; syn_pkt[29]=8'h15;
    syn_pkt[30]=8'ha9; syn_pkt[31]=8'hfe; syn_pkt[32]=8'h01; syn_pkt[33]=8'h01;
    syn_pkt[34]=8'h12; syn_pkt[35]=8'h34; syn_pkt[36]=8'h00; syn_pkt[37]=8'h50;  // SrcPort=4660 DstPort=80
    syn_pkt[38]=8'h05; syn_pkt[39]=8'h85; syn_pkt[40]=8'h2e; syn_pkt[41]=8'ha5;
    syn_pkt[42]=8'h00; syn_pkt[43]=8'h00; syn_pkt[44]=8'h00; syn_pkt[45]=8'h00;
    syn_pkt[46]=8'h50; syn_pkt[47]=8'h02; syn_pkt[48]=8'hfa; syn_pkt[49]=8'hf0;
    syn_pkt[50]=8'h00; syn_pkt[51]=8'h00; syn_pkt[52]=8'h00; syn_pkt[53]=8'h00;
  end

  // ============== RX FIFO 注入引擎 ==============
  reg [7:0] pkt_buf [0:53];
  reg [5:0] pkt_len;
  reg       inject_active;
  reg [3:0] pop_count;
  reg [7:0] captured_raddr;

  always @(posedge clk_50m_in)
    if (u_dut.bus_address == 32'h6005 && u_dut.bus_req)
      captured_raddr <= u_dut.bus_wdata[7:0];
  wire [5:0] r_addr_w = captured_raddr[5:0];
  wire cpu_rd_access = (u_dut.bus_address == 32'h6006) && u_dut.bus_req;
  wire cpu_pop = (u_dut.bus_address == 32'h6001) && u_dut.bus_req;

  always @(posedge clk_50m_in)
    if (!inject_active) pop_count <= 0;
    else if (cpu_pop) pop_count <= pop_count + 1;

  always @(posedge clk_50m_in) begin
    if (inject_active && cpu_rd_access) begin
      #1;
      if (r_addr_w < pkt_len)
        force u_dut.fpga_cpu_rd_rdata = {24'h0, pkt_buf[r_addr_w]};
      else
        force u_dut.fpga_cpu_rd_rdata = 32'h0;
    end
  end

  task inject_and_wait;
    begin
      pop_count  = 0;
      inject_active = 1;
      force u_dut.cpu_rd_empty = 1'b0;
      force u_dut.cpu_rd_rpkt_len = {26'd0, pkt_len};
      force u_dut.cpu_rd_reop_pre = 1'b0;
      $display("[%0t] 注入包 (%0d字节)", $time, pkt_len);
      wait(pop_count >= 2);
      #1000;
      release u_dut.cpu_rd_empty;
      release u_dut.cpu_rd_rpkt_len;
      release u_dut.cpu_rd_reop_pre;
      inject_active = 0;
      $display("[%0t] 包处理完成 pop=%0d LED=%b", $time, pop_count, led_o);
    end
  endtask

  // ============== TX 监控: 解析 DstPort ==============
  reg [7:0]  tx_buf [0:199];
  reg [15:0] tx_len;

  initial begin
    forever begin
      @(posedge clk_50m_in);
      if (u_dut.mac_tx_sop === 1'b1 && u_dut.mac_tx_en === 1'b1) begin
        tx_len = 0; tx_buf[0] = u_dut.mac_tx_data; tx_len = 1;
        @(posedge clk_50m_in);
        while (u_dut.mac_tx_eop !== 1'b1 && tx_len < 200) begin
          if (u_dut.mac_tx_en === 1'b1) begin
            tx_buf[tx_len] = u_dut.mac_tx_data; tx_len = tx_len + 1;
          end
          @(posedge clk_50m_in);
        end
        if (u_dut.mac_tx_en === 1'b1 && tx_len < 200) begin
          tx_buf[tx_len] = u_dut.mac_tx_data; tx_len = tx_len + 1;
        end
        $display("[%0t] TX PKT len=%0d", $time, tx_len);
        if (tx_len > 38) begin
          $display("[%0t]   TCP: SrcPort=%02x%02x DstPort=%02x%02x Flags=0x%02x",
                   $time,
                   tx_buf[34], tx_buf[35], tx_buf[36], tx_buf[37], tx_buf[47]);
          if (tx_buf[36] == 8'h00 && tx_buf[37] == 8'h50)
            $display("  *** BUG CONFIRMED: DstPort=80 (expected 4660=0x1234) ***");
          else if (tx_buf[36] == 8'h12 && tx_buf[37] == 8'h34)
            $display("  *** OK: DstPort=4660 correct ***");
        end
      end
    end
  end

  // ============== 主测试 ==============
  initial begin
    #250000;
    $display("============================================");
    $display(" SRAM Debug: 注入 TCP SYN (SrcPort=4660 DstPort=80)");
    $display("============================================");

    for (i=0; i<54; i=i+1) pkt_buf[i] = syn_pkt[i];
    pkt_len = 54;
    inject_and_wait;

    $display("");
    $display("============================================");
    $display(" 等待 TX SYN+ACK...");
    $display("============================================");

    #500000;

    $display("");
    $display("============================================");
    $display(" 最终 LED = %b", led_o);
    $display("============================================");
    $finish;
  end

  initial begin #200_000_000; $display("TIMEOUT"); $finish; end

endmodule
