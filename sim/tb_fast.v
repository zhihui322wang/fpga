// tb_fast.v — 精简仿真: 只验证 ARP Reply (不用前导码)
`timescale 1ns / 100ps

module tb_fast;
    reg clk_50m, reset_l;
    reg rgmii_rxc;
    reg [3:0] rgmii_rxd;
    reg rgmii_rx_ctl;

    webserver_cpu_top #(.sim_mod(1)) dut (
        .clk_50m_in(clk_50m), .reset_l(reset_l),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_txc(), .rgmii_txd(), .rgmii_tx_ctl(),
        .Eth0_MDC(), .Eth0_MDIO(), .rgmii_reset_l(),
        .uart_rx(1'b1), .uart_tx(), .led_o()
    );

    wire cpu_rd_empty  = dut.cpu_rd_empty;
    wire tx_push       = dut.cpu_wr_wpkt_push;
    wire [12:0] tx_len = dut.cpu_wr_wpkt_len[12:0];

    initial clk_50m = 0;   always #10 clk_50m = ~clk_50m;
    initial rgmii_rxc = 0; always #10 rgmii_rxc = ~rgmii_rxc;

    // ARP Request 帧, 不含前导码, 42 字节, 问 169.254.1.1
    reg [7:0] frame [0:63];
    integer   frame_len, byte_idx;
    reg       sending;

    initial begin
        // dst MAC: FF:FF:FF:FF:FF:FF
        frame[0]=8'hFF; frame[1]=8'hFF; frame[2]=8'hFF; frame[3]=8'hFF; frame[4]=8'hFF; frame[5]=8'hFF;
        // src MAC: 11:22:33:44:55:66
        frame[6]=8'h11; frame[7]=8'h22; frame[8]=8'h33; frame[9]=8'h44; frame[10]=8'h55; frame[11]=8'h66;
        // EtherType: 0x0806 (ARP)
        frame[12]=8'h08; frame[13]=8'h06;
        // HTYPE=1 (Ethernet)
        frame[14]=8'h00; frame[15]=8'h01;
        // PTYPE=0x0800 (IPv4)
        frame[16]=8'h08; frame[17]=8'h00;
        // HLEN=6, PLEN=4
        frame[18]=8'h06; frame[19]=8'h04;
        // Opcode=1 (Request)
        frame[20]=8'h00; frame[21]=8'h01;
        // Sender MAC: 11:22:33:44:55:66
        frame[22]=8'h11; frame[23]=8'h22; frame[24]=8'h33; frame[25]=8'h44; frame[26]=8'h55; frame[27]=8'h66;
        // Sender IP: 169.254.1.100
        frame[28]=8'hA9; frame[29]=8'hFE; frame[30]=8'h01; frame[31]=8'h64;
        // Target MAC: 00:00:00:00:00:00
        frame[32]=8'h00; frame[33]=8'h00; frame[34]=8'h00; frame[35]=8'h00; frame[36]=8'h00; frame[37]=8'h00;
        // Target IP: 169.254.1.1
        frame[38]=8'hA9; frame[39]=8'hFE; frame[40]=8'h01; frame[41]=8'h01;
        // padding to 64B
        for (integer j = 42; j < 64; j++) frame[j] = 8'h00;
        frame_len = 64;
    end

    // RGMII DDR 驱动
    initial begin rgmii_rxd = 0; rgmii_rx_ctl = 0; sending = 0; byte_idx = 0; end
    always @(negedge rgmii_rxc)
        if (sending && byte_idx < frame_len) begin
            rgmii_rxd    <= frame[byte_idx][3:0];
            rgmii_rx_ctl <= 1'b1;
        end else if (!sending) begin rgmii_rxd <= 0; rgmii_rx_ctl <= 0; end
    always @(posedge rgmii_rxc)
        if (sending && byte_idx < frame_len) begin
            rgmii_rxd    <= frame[byte_idx][7:4];
            rgmii_rx_ctl <= 1'b1;
            byte_idx     <= byte_idx + 1;
        end else if (!sending) begin rgmii_rxd <= 0; rgmii_rx_ctl <= 0; end

    // 事件监控
    reg tx_seen;
    initial tx_seen = 0;
    always @(posedge tx_push) begin
        $display("[%0t] >>> TX PUSH len=%0d — FIRMWARE SENT REPLY!", $time, tx_len);
        tx_seen = 1;
    end

    // 主流程
    initial begin
        $display("=== Fast Simulation ===");
        $dumpfile("tb_fast.vcd");
        $dumpvars(0, tb_fast);
        reset_l = 0; sending = 0;
        #300; reset_l = 1;
        $display("[%0t] Reset released", $time);

        // 等 BFM 加载 + 强制释放 RISC-V
        #200000;

        // 等固件进入主循环
        #100000;
        $display("[%0t] Sending ARP frame", $time);
        byte_idx = 0; sending = 1;
        wait(byte_idx >= frame_len);
        #1000; sending = 0;
        $display("[%0t] Frame sent", $time);

        // 等回复
        #1000000;
        if (tx_seen)
            $display("=== PASS: Firmware sent ARP Reply! ===");
        else
            $display("=== FAIL: No reply ===");
        $finish;
    end
endmodule
