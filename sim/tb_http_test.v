//-----------------------------------------------------------------
// tb_http_test.v — HTTP 响应端到端仿真 (Icarus)
// Phase 1: SYN → SYN+ACK
// Phase 2: ACK  → ESTABLISHED
// Phase 3: GET  → 捕获 ACK + data + FIN 三个 TX 包并 dump 字节
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module tb_http_test;

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
    $dumpfile("tb_http_test.vcd");
    $dumpvars(0, u_dut.mac_tx_sop);
    $dumpvars(0, u_dut.mac_tx_en);
    $dumpvars(0, u_dut.mac_tx_data);
    $dumpvars(0, u_dut.mac_tx_eop);
  end

  // ============== 基础包结构 ==============
  reg [7:0] pkt_buf [0:4095];   // 注入包缓冲 (支持带 payload)
  reg [11:0] pkt_len;
  reg [7:0] get_data [0:36];    // GET 请求 payload
  integer i;

  // ============== RX FIFO 注入引擎 ==============
  reg       inject_active;
  reg [3:0] pop_count;
  reg [7:0] force_data;
  integer   raddr_idx;

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
      #1; raddr_idx = r_addr_w;
      if (raddr_idx < pkt_len) begin
        force_data = pkt_buf[raddr_idx];
        force u_dut.fpga_cpu_rd_rdata = {24'h0, force_data};
      end else
        force u_dut.fpga_cpu_rd_rdata = 32'h0;
    end
  end

  task inject_and_wait;
    integer j;
    begin
      pop_count  = 0;
      inject_active = 1;
      force u_dut.cpu_rd_empty = 1'b0;
      force u_dut.cpu_rd_rpkt_len = {32'd0} | {20'd0, pkt_len};
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

  // ============== TX 监控: 捕获并 dump 每个包 ==============
  reg [7:0]  tx_buf [0:1023];
  reg [15:0] tx_len;
  integer    pkt_cnt;
  integer    k;
  initial pkt_cnt = 0;

  initial begin
    forever begin
      @(posedge clk_50m_in);
      // sop_eop_gen 协议: o_sop = i_en & ~i_en_d0 (SOP 提前于首数据 1 拍, 此时 EN=0)
      //                    o_en  = i_en_d0 (数据从 SOP 后 1 拍开始)
      //                    o_eop = ~i_en & i_en_d0 (EOP 与最后一字节同拍)
      if (u_dut.mac_tx_sop === 1'b1) begin
        tx_len = 0;
        // 数据从 SOP 后 1 拍开始 (EN 有效), EOP 与最后一字节同拍
        @(posedge clk_50m_in);
        while (u_dut.mac_tx_eop !== 1'b1 && tx_len < 1024) begin
          if (u_dut.mac_tx_en === 1'b1) begin
            tx_buf[tx_len] = u_dut.mac_tx_data; tx_len = tx_len + 1;
          end
          @(posedge clk_50m_in);
        end
        // 捕获 EOP 拍 (最后一字节)
        if (u_dut.mac_tx_en === 1'b1 && tx_len < 1024) begin
          tx_buf[tx_len] = u_dut.mac_tx_data; tx_len = tx_len + 1;
        end
        pkt_cnt = pkt_cnt + 1;
        $display("===== TX 包 #%0d (len=%0d) =====", pkt_cnt, tx_len);
        for (k = 0; k < tx_len; k = k + 16) begin
          $write("  %04x:", k);
          for (i = 0; i < 16; i = i + 1) begin
            if (k + i < tx_len) $write(" %02x", tx_buf[k+i]);
            else $write("   ");
          end
          $write("  ");
          for (i = 0; i < 16; i = i + 1) begin
            if (k + i < tx_len) begin
              if (tx_buf[k+i] >= 32 && tx_buf[k+i] < 127) $write("%c", tx_buf[k+i]);
              else $write(".");
            end
          end
          $write("\n");
        end
      end
    end
  end

  // ============== TX 推送诊断 (debug) ==============
  integer tx_push_cnt, tx_wen_cnt, sop_cnt;
  initial begin tx_push_cnt = 0; tx_wen_cnt = 0; sop_cnt = 0; end
  always @(posedge clk_50m_in) begin
    if (u_dut.mac_tx_sop === 1'b1) begin
      sop_cnt = sop_cnt + 1;
      $display("[%0t] mac_tx_sop #%0d", $time, sop_cnt);
    end
    if (u_dut.cpu_wr_wpkt_push_ind === 1'b1) begin
      tx_push_cnt = tx_push_cnt + 1;
      $display("[%0t] TX PUSH #%0d len=%0d full=%b", $time, tx_push_cnt,
               u_dut.cpu_wr_wpkt_len, u_dut.cpu_wr_full);
    end
    if (u_dut.cpu_wr_wen_ind === 1'b1) begin
      tx_wen_cnt = tx_wen_cnt + 1;
      if (tx_wen_cnt <= 60)
        $display("[%0t] TX WEN #%0d addr=%0d data=%02x", $time, tx_wen_cnt,
                 u_dut.cpu_wr_waddr, u_dut.cpu_wr_wdata);
    end
  end

  // ============== 主测试 ==============
  reg [31:0] fpga_isn;
  reg [31:0] pc_seq, pc_ack;

  // 构造包: 填充以太网头 + IP 头 + TCP 头
  task build_base_pkt;
    begin
      // 以太网头
      pkt_buf[0]=8'h00; pkt_buf[1]=8'h00; pkt_buf[2]=8'h01; pkt_buf[3]=8'h02; pkt_buf[4]=8'h04; pkt_buf[5]=8'h05; // FPGA MAC
      pkt_buf[6]=8'h9c; pkt_buf[7]=8'h2d; pkt_buf[8]=8'hcd; pkt_buf[9]=8'hac; pkt_buf[10]=8'h8f; pkt_buf[11]=8'ha4; // PC MAC
      pkt_buf[12]=8'h08; pkt_buf[13]=8'h00;
      // IP 头
      pkt_buf[14]=8'h45; pkt_buf[15]=8'h00;
      pkt_buf[18]=8'h00; pkt_buf[19]=8'h01; pkt_buf[20]=8'h40; pkt_buf[21]=8'h00;
      pkt_buf[22]=8'h40; pkt_buf[23]=8'h06; pkt_buf[24]=8'h00; pkt_buf[25]=8'h00;
      pkt_buf[26]=8'ha9; pkt_buf[27]=8'hfe; pkt_buf[28]=8'h5c; pkt_buf[29]=8'h15; // PC IP
      pkt_buf[30]=8'ha9; pkt_buf[31]=8'hfe; pkt_buf[32]=8'h01; pkt_buf[33]=8'h01; // FPGA IP
      // TCP 头 (端口/序号/flags 由调用者填充)
      pkt_buf[36]=8'h00; pkt_buf[37]=8'h50; // dst port 80
      pkt_buf[46]=8'h50; // data_ofs 5
      pkt_buf[48]=8'hfa; pkt_buf[49]=8'hf0; // window
      pkt_buf[50]=8'h00; pkt_buf[51]=8'h00; pkt_buf[52]=8'h00; pkt_buf[53]=8'h00;
    end
  endtask

  initial begin
    #250000;
    $display("============================================");
    $display(" Phase 1: SYN");
    $display("============================================");

    // SYN
    build_base_pkt;
    pkt_buf[16]=8'h00; pkt_buf[17]=8'h28; // IP total_len 40
    pkt_buf[34]=8'h30; pkt_buf[35]=8'h39; // src port 12345
    pkt_buf[38]=8'h05; pkt_buf[39]=8'h85; pkt_buf[40]=8'h2e; pkt_buf[41]=8'ha5; // seq
    pkt_buf[42]=8'h00; pkt_buf[43]=8'h00; pkt_buf[44]=8'h00; pkt_buf[45]=8'h00; // ack
    pkt_buf[47]=8'h02; // SYN
    pkt_len = 54;
    inject_and_wait;

    fpga_isn = 32'h12345678;
    $display("[%0t] FPGA ISN = 0x%08x", $time, fpga_isn);

    $display("");
    $display("============================================");
    $display(" Phase 2: ACK (第三次握手)");
    $display("============================================");

    pc_seq = 32'h05852ea5 + 1;
    pc_ack = fpga_isn + 1;
    build_base_pkt;
    pkt_buf[16]=8'h00; pkt_buf[17]=8'h28;
    pkt_buf[34]=8'h30; pkt_buf[35]=8'h39;
    pkt_buf[38]=(pc_seq>>24)&8'hFF; pkt_buf[39]=(pc_seq>>16)&8'hFF; pkt_buf[40]=(pc_seq>>8)&8'hFF; pkt_buf[41]=pc_seq&8'hFF;
    pkt_buf[42]=(pc_ack>>24)&8'hFF; pkt_buf[43]=(pc_ack>>16)&8'hFF; pkt_buf[44]=(pc_ack>>8)&8'hFF; pkt_buf[45]=pc_ack&8'hFF;
    pkt_buf[47]=8'h10; // ACK
    pkt_len = 54;
    inject_and_wait;

    $display("");
    $display("============================================");
    $display(" Phase 3: GET (HTTP 请求)");
    $display("============================================");

    // GET payload
    get_data[ 0]="G"; get_data[ 1]="E"; get_data[ 2]="T"; get_data[ 3]=" ";
    get_data[ 4]="/"; get_data[ 5]=" "; get_data[ 6]="H"; get_data[ 7]="T";
    get_data[ 8]="T"; get_data[ 9]="P"; get_data[10]="/"; get_data[11]="1";
    get_data[12]="."; get_data[13]="1"; get_data[14]=8'h0d; get_data[15]=8'h0a;
    get_data[16]="H"; get_data[17]="o"; get_data[18]="s"; get_data[19]="t";
    get_data[20]=":"; get_data[21]=" "; get_data[22]="1"; get_data[23]="6";
    get_data[24]="9"; get_data[25]="."; get_data[26]="2"; get_data[27]="5";
    get_data[28]="4"; get_data[29]="."; get_data[30]="1"; get_data[31]=".";
    get_data[32]="1"; get_data[33]=8'h0d; get_data[34]=8'h0a;
    get_data[35]=8'h0d; get_data[36]=8'h0a;

    build_base_pkt;
    pkt_buf[16]=8'h00; pkt_buf[17]=8'h00 + 8'd77; // IP total_len 20+20+37=77
    pkt_buf[34]=8'h30; pkt_buf[35]=8'h39;
    pkt_buf[38]=(pc_seq>>24)&8'hFF; pkt_buf[39]=(pc_seq>>16)&8'hFF; pkt_buf[40]=(pc_seq>>8)&8'hFF; pkt_buf[41]=pc_seq&8'hFF;
    pkt_buf[42]=(pc_ack>>24)&8'hFF; pkt_buf[43]=(pc_ack>>16)&8'hFF; pkt_buf[44]=(pc_ack>>8)&8'hFF; pkt_buf[45]=pc_ack&8'hFF;
    pkt_buf[47]=8'h18; // PSH|ACK
    for (i = 0; i < 37; i = i + 1) pkt_buf[54 + i] = get_data[i];
    pkt_len = 54 + 37;
    inject_and_wait;

    #200000;
    $display("");
    $display("============================================");
    $display(" 共捕获 %0d 个 TX 包", pkt_cnt);
    $display(" 最终 LED = %b", led_o);
    $display("============================================");
    $finish;
  end

  initial begin #400_000_000; $display("TIMEOUT"); $finish; end

endmodule
