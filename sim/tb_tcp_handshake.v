//-----------------------------------------------------------------
// tb_tcp_handshake.v — TCP 三次握手完整仿真 (Icarus)
// Phase 1: 注入 SYN → 等待 SYN+ACK → 捕获 FPGA 序列号
// Phase 2: 注入 ACK → 验证 ESTABLISHED (LED=0x0F)
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module tb_tcp_handshake;

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
      .uart_rx(uart_rx), .uart_tx(uart_tx), .led_o(led_o)
  );

  initial clk_50m_in = 1'b0;
  always #10 clk_50m_in = ~clk_50m_in;
  initial begin rgmii_rxc=0; rgmii_rxd=0; rgmii_rx_ctl=0; uart_rx=1; end
  always #10 rgmii_rxc = ~rgmii_rxc;
  initial begin reset_l=0; #200; reset_l=1; end

  initial begin
    $dumpfile("tb_tcp_handshake.vcd");
    $dumpvars(0, led_o);
    $dumpvars(0, u_dut.mac_tx_sop);
    $dumpvars(0, u_dut.mac_tx_data);
    $dumpvars(0, u_dut.bus_req);
  end

  // ============== TCP SYN 包 ==============
  reg [7:0] syn_pkt [0:53];
  integer i;
  initial begin
    syn_pkt[0]=8'h00; syn_pkt[1]=8'h00; syn_pkt[2]=8'h01; syn_pkt[3]=8'h02; syn_pkt[4]=8'h04; syn_pkt[5]=8'h05; // FPGA MAC
    syn_pkt[6]=8'h9c; syn_pkt[7]=8'h2d; syn_pkt[8]=8'hcd; syn_pkt[9]=8'hac; syn_pkt[10]=8'h8f; syn_pkt[11]=8'ha4; // PC MAC
    syn_pkt[12]=8'h08; syn_pkt[13]=8'h00;
    syn_pkt[14]=8'h45; syn_pkt[15]=8'h00; syn_pkt[16]=8'h00; syn_pkt[17]=8'h28;
    syn_pkt[18]=8'h00; syn_pkt[19]=8'h01; syn_pkt[20]=8'h40; syn_pkt[21]=8'h00;
    syn_pkt[22]=8'h40; syn_pkt[23]=8'h06; syn_pkt[24]=8'h00; syn_pkt[25]=8'h00;
    syn_pkt[26]=8'ha9; syn_pkt[27]=8'hfe; syn_pkt[28]=8'h5c; syn_pkt[29]=8'h15; // PC IP
    syn_pkt[30]=8'ha9; syn_pkt[31]=8'hfe; syn_pkt[32]=8'h01; syn_pkt[33]=8'h01; // FPGA IP
    syn_pkt[34]=8'h30; syn_pkt[35]=8'h39; syn_pkt[36]=8'h00; syn_pkt[37]=8'h07;
    syn_pkt[38]=8'h05; syn_pkt[39]=8'h85; syn_pkt[40]=8'h2e; syn_pkt[41]=8'ha5;
    syn_pkt[42]=8'h00; syn_pkt[43]=8'h00; syn_pkt[44]=8'h00; syn_pkt[45]=8'h00;
    syn_pkt[46]=8'h50; syn_pkt[47]=8'h02; syn_pkt[48]=8'hfa; syn_pkt[49]=8'hf0;
    syn_pkt[50]=8'h00; syn_pkt[51]=8'h00; syn_pkt[52]=8'h00; syn_pkt[53]=8'h00;
  end

  // ============== RX FIFO 注入引擎 ==============
  reg [7:0] pkt_buf [0:53];    // 当前注入的包数据
  reg [5:0] pkt_len;            // 当前包长度
  reg       inject_active;
  reg [3:0] pop_count;
  reg [7:0] force_data;
  integer   raddr_idx;

  // 从 bus 写捕捉 RX FIFO 读地址 (CPU 写 0x6005 REG_RX_RADDR)
  reg [7:0] captured_raddr;
  always @(posedge clk_50m_in)
    if (u_dut.bus_address == 32'h6005 && u_dut.bus_req)
      captured_raddr <= u_dut.bus_wdata[7:0];
  wire [5:0] r_addr_w = captured_raddr[5:0];
  wire cpu_rd_access = (u_dut.bus_address == 32'h6006) && u_dut.bus_req;
  wire cpu_pop = (u_dut.bus_address == 32'h6001) && u_dut.bus_req;

  // POP 计数器
  always @(posedge clk_50m_in)
    if (!inject_active) pop_count <= 0;
    else if (cpu_pop) pop_count <= pop_count + 1;

  // CPU 读数据时返回当前包的对应字节
  always @(posedge clk_50m_in) begin
    if (inject_active && cpu_rd_access) begin
      #1; raddr_idx = r_addr_w;
      if (raddr_idx < pkt_len) begin
        force_data = pkt_buf[raddr_idx];
        force u_dut.fpga_cpu_rd_rdata = {24'h0, force_data};
        $display("[%0t] FORCE raddr=%0d data=0x%02x", $time, raddr_idx, force_data);
      end else
        force u_dut.fpga_cpu_rd_rdata = 32'h0;
    end
  end

  // 注入一个包并等待 CPU 处理完成
  // 使用全局 pkt_buf 和 pkt_len 传递参数 (Icarus 不支持 unpacked array task 端口)
  task inject_and_wait;
    integer j;
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

  // ============== TX 监控: 捕获 SYN+ACK 包 ==============
  event tx_packet_ready;
  reg [7:0]  tx_buf [0:199];
  reg [15:0] tx_len;
  reg        tx_done;

  initial begin
    tx_done = 0;
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
        tx_done = 1;
        -> tx_packet_ready;
      end
    end
  end

  // ============== 主测试 ==============
  reg [31:0] fpga_isn;       // FPGA 初始序列号
  reg [7:0]  ack_pkt [0:53];  // ACK 包数据
  reg [31:0] pc_seq, pc_ack;  // PC 的 seq/ack

  // 调试: 打印所有 bus 写 (地址 < 0x100)
  always @(posedge clk_50m_in) begin
    if (u_dut.bus_req && u_dut.bus_address < 32'h100) begin
      $display("[%0t] BUS: addr=0x%02x data=0x%08x rhwl=%b", $time, u_dut.bus_address, u_dut.bus_wdata, u_dut.bus_rhwl);
      if (u_dut.bus_address == 32'h04)
        fpga_isn <= u_dut.bus_wdata;
    end
  end

  initial begin
    // 等 BFM 加载固件
    #250000;
    $display("============================================");
    $display(" Phase 1: 注入 TCP SYN");
    $display("============================================");

    // 将 SYN 包拷入全局 pkt_buf，设置 pkt_len
    for (i=0; i<54; i=i+1) pkt_buf[i] = syn_pkt[i];
    pkt_len = 54;
    inject_and_wait;

    // SIM_FAST 下 ISN 固定为 0x12345678
    fpga_isn = 32'h12345678;
    $display("[%0t] FPGA ISN = 0x%08x (SIM_FAST 固定值)", $time, fpga_isn);

    // ============== Phase 2: 构造 ACK 包 ==============
    $display("");
    $display("============================================");
    $display(" Phase 2: 注入 TCP ACK (第三次握手)");
    $display("============================================");

    // ACK 包 = 与 SYN 相同，但:
    //   TCP seq = 0x05852ea5 + 1 = 0x05852ea6
    //   TCP ack = fpga_isn + 1
    //   TCP flags = ACK (0x10)
    pc_seq = 32'h05852ea5 + 1;
    pc_ack = fpga_isn + 1;
    $display("  PC seq=0x%08x  PC ack=0x%08x", pc_seq, pc_ack);

    // 拷贝 SYN 包，修改 TCP 字段
    for (i=0; i<54; i=i+1) ack_pkt[i] = syn_pkt[i];
    // TCP seq (bytes 38-41)
    ack_pkt[38] = (pc_seq >> 24) & 8'hFF;
    ack_pkt[39] = (pc_seq >> 16) & 8'hFF;
    ack_pkt[40] = (pc_seq >> 8)  & 8'hFF;
    ack_pkt[41] = pc_seq & 8'hFF;
    // TCP ack (bytes 42-45)
    ack_pkt[42] = (pc_ack >> 24) & 8'hFF;
    ack_pkt[43] = (pc_ack >> 16) & 8'hFF;
    ack_pkt[44] = (pc_ack >> 8)  & 8'hFF;
    ack_pkt[45] = pc_ack & 8'hFF;
    // TCP flags = ACK only (no SYN)
    ack_pkt[47] = 8'h10;

    for (i=0; i<54; i=i+1) pkt_buf[i] = ack_pkt[i];
    pkt_len = 54;
    inject_and_wait;

    // 验证
    #500000; // 等 LED 稳定
    $display("");
    $display("============================================");
    $display(" 最终 LED = %b", led_o);
    if (led_o == 4'b1111)
      $display(" PASS: 三次握手完成！ESTABLISHED");
    else if (led_o == 4'b0001)
      $display(" FAIL: 仍在 SYN_RECEIVED (ACK 未被正确处理)");
    else
      $display(" FAIL: LED=%b 异常", led_o);
    $display("============================================");
    $finish;
  end

  // 全局超时
  initial begin #200_000_000; $display("TIMEOUT LED=%b",led_o); $finish; end

endmodule
