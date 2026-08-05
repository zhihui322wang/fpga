// tb.v — RISC-V WebSoC 仿真顶层
// 使用: iverilog -o sim.vvp ... && vvp sim.vvp
// 波形: gtkwave tb.vcd

`timescale 1ns / 100ps

module tb;
    reg clk_50m;
    reg reset_l;
    reg rgmii_rxc;
    reg [3:0] rgmii_rxd;
    reg rgmii_rx_ctl;

    webserver_cpu_top #(.sim_mod(1)) dut (
        .clk_50m_in   (clk_50m),
        .reset_l      (reset_l),
        .rgmii_rxc    (rgmii_rxc),
        .rgmii_rxd    (rgmii_rxd),
        .rgmii_rx_ctl (rgmii_rx_ctl),
        .rgmii_txc    (),
        .rgmii_txd    (),
        .rgmii_tx_ctl (),
        .Eth0_MDC     (),
        .Eth0_MDIO    (),
        .rgmii_reset_l(),
        .uart_rx      (1'b1),
        .uart_tx      (),
        .led_o        ()
    );

    // ── 调试探针: 拉到顶层方便 GTKWave 查看 ──
    // 这些信号都是 webserver_cpu_top 的顶层 wire, 直接用 dut.xxx 访问
    wire        dbg_cpu_rd_empty = dut.cpu_rd_empty;
    wire [7:0]  dbg_gmii_rxd     = dut.gmii_rxd;
    wire        dbg_gmii_rx_dv   = dut.gmii_rx_dv;
    wire        dbg_mac_rx_sop   = dut.mac_rx_sop;
    wire        dbg_mac_rx_en    = dut.mac_rx_en;
    wire [7:0]  dbg_mac_rx_data  = dut.mac_rx_data;
    wire        dbg_mac_rx_eop   = dut.mac_rx_eop;

    // ── TX 路径探针: 监控固件是否发出回复 ──
    wire        dbg_cpu_wr_full   = dut.cpu_wr_full;
    wire        dbg_cpu_wr_wen    = dut.cpu_wr_wen;
    wire        dbg_cpu_wr_push   = dut.cpu_wr_wpkt_push;
    wire [7:0]  dbg_cpu_wr_wdata  = dut.cpu_wr_wdata[7:0];
    wire [11:0] dbg_cpu_wr_waddr  = dut.cpu_wr_waddr[11:0];
    wire [12:0] dbg_cpu_wr_len    = dut.cpu_wr_wpkt_len[12:0];

    // ── 固件活动探针: RX FIFO 读操作 ──
    wire        dbg_cpu_rd_ren    = dut.cpu_rd_ren;
    wire [11:0] dbg_cpu_rd_raddr  = dut.cpu_rd_raddr[11:0];
    wire        dbg_cpu_rd_pop    = dut.fpga_cpu_rd_rpkt_pop;

    // ── 50MHz 时钟 ──
    initial clk_50m = 0;
    always #10 clk_50m = ~clk_50m;

    // ── RGMII RXC (仿真用 50MHz, 与内部时钟同频) ──
    initial rgmii_rxc = 0;
    always #10 rgmii_rxc = ~rgmii_rxc;

    // ── ARP Request 帧 (问 169.254.1.1) ──
    // 格式: preamble(7×55)+SFD(D5) + MAC(14B) + ARP(28B) + pad → 合计 72B
    reg [7:0] frame [0:127];
    integer   frame_len;

    initial begin
        // preamble(7) + SFD(1)
        frame[0]=8'h55; frame[1]=8'h55; frame[2]=8'h55; frame[3]=8'h55;
        frame[4]=8'h55; frame[5]=8'h55; frame[6]=8'h55; frame[7]=8'hD5;
        // DstMAC: ff:ff:ff:ff:ff:ff
        frame[8]=8'hFF;  frame[9]=8'hFF;  frame[10]=8'hFF;
        frame[11]=8'hFF; frame[12]=8'hFF; frame[13]=8'hFF;
        // SrcMAC: 11:22:33:44:55:66
        frame[14]=8'h11; frame[15]=8'h22; frame[16]=8'h33;
        frame[17]=8'h44; frame[18]=8'h55; frame[19]=8'h66;
        // EtherType: 0x0806
        frame[20]=8'h08; frame[21]=8'h06;
        // ARP body: HW=1, Proto=0x0800, HLen=6, PLen=4, Op=1
        frame[22]=8'h00; frame[23]=8'h01;
        frame[24]=8'h08; frame[25]=8'h00;
        frame[26]=8'h06; frame[27]=8'h04;
        frame[28]=8'h00; frame[29]=8'h01;
        // SenderMAC: 11:22:33:44:55:66
        frame[30]=8'h11; frame[31]=8'h22; frame[32]=8'h33;
        frame[33]=8'h44; frame[34]=8'h55; frame[35]=8'h66;
        // SenderIP: 169.254.1.100
        frame[36]=8'hA9; frame[37]=8'hFE; frame[38]=8'h01; frame[39]=8'h64;
        // TargetMAC: 00:00:00:00:00:00
        frame[40]=8'h00; frame[41]=8'h00; frame[42]=8'h00;
        frame[43]=8'h00; frame[44]=8'h00; frame[45]=8'h00;
        // TargetIP: 169.254.1.1
        frame[46]=8'hA9; frame[47]=8'hFE; frame[48]=8'h01; frame[49]=8'h01;
        // pad to minimum
        for (integer j = 50; j < 72; j++) frame[j] = 8'h00;
        frame_len = 72;
    end

    // ── RGMII DDR 驱动器 ──
    // IDDR 在 posedge 采样低 nibble, negedge 采样高 nibble
    // 在 OPPOSITE 边沿驱动数据, 保证半周期 setup time
    //   驱动在 negedge → 数据稳定 → posedge 采样 ✓
    //   驱动在 posedge → 数据稳定 → negedge 采样 ✓
    reg      sending;
    integer  byte_idx;

    initial begin
        rgmii_rxd    = 4'h0;
        rgmii_rx_ctl = 1'b0;
        sending      = 0;
        byte_idx     = 0;
    end

    // negedge RXC: 驱动低 nibble (给下一个 posedge 采样)
    always @(negedge rgmii_rxc) begin
        if (sending && byte_idx < frame_len) begin
            rgmii_rxd    <= frame[byte_idx][3:0];
            rgmii_rx_ctl <= 1'b1;
        end else if (!sending) begin
            rgmii_rxd    <= 4'h0;
            rgmii_rx_ctl <= 1'b0;
        end
    end

    // posedge RXC: 驱动高 nibble (给下一个 negedge 采样), 字节+1
    always @(posedge rgmii_rxc) begin
        if (sending && byte_idx < frame_len) begin
            rgmii_rxd    <= frame[byte_idx][7:4];
            rgmii_rx_ctl <= 1'b1;
            byte_idx     <= byte_idx + 1;
        end else if (!sending) begin
            rgmii_rxd    <= 4'h0;
            rgmii_rx_ctl <= 1'b0;
        end
    end

    // ── LED 监控: LED 值变化 = 固件在跑 ──
    reg [3:0] last_led;
    initial last_led = 4'bxxxx;
    always @(dut.led_o) begin
        $display("[%0t] >>> LED changed: %b → %b (firmware is running!)",
            $time, last_led, dut.led_o);
        last_led = dut.led_o;
    end

    // ── RISC-V 复位 & 总线请求探针 ──
    wire [0:0] riscv_reset_l = dut.riscv_reset_l;
    wire riscv_bus_req = dut.u_riscv.riscv_req;

    always @(posedge riscv_bus_req)
        $display("[%0t] >>> RISC-V bus_req addr=0x%08x %s",
            $time, dut.bus_address, dut.bus_rhwl ? "RD" : "WR");
    always @(posedge riscv_reset_l)
        $display("[%0t] >>> riscv_reset_l HIGH — CPU released", $time);
    always @(negedge riscv_reset_l)
        $display("[%0t] >>> riscv_reset_l LOW", $time);

    // 周期性采样: 每 1ms 打印 CPU 状态
    integer sample_timer;
    initial sample_timer = 0;
    always @(posedge clk_50m) begin
        if (sample_timer >= 50000) begin
            sample_timer <= 0;
            if (riscv_reset_l)
                $display("[%0t] SAMPLE: riscv_req=%b bus_addr=0x%08x",
                    $time, riscv_bus_req, dut.bus_address);
        end else begin
            sample_timer <= sample_timer + 1;
        end
    end

    // ── 总线活动监控: 显示 BFM 之后的所有 RISC-V 请求 ──
    reg [31:0] bus_rd_count;
    reg        bfm_done;
    initial begin bus_rd_count = 0; bfm_done = 0; end
    always @(posedge dut.bus_req) begin
        bus_rd_count <= bus_rd_count + 1;
        if (!bfm_done && bus_rd_count > 660) begin
            $display("[%0t] === BFM finished, monitoring RISC-V ===", $time);
            bfm_done = 1;
        end
        if (bfm_done)
            $display("[%0t] BUS #%0d addr=0x%08x %s",
                $time, bus_rd_count, dut.bus_address,
                dut.bus_rhwl ? "RD" : "WR");
    end

    // ── 信号监控: 自动打印关键事件 ──
    reg tx_push_seen;
    initial tx_push_seen = 0;

    always @(negedge dbg_cpu_rd_empty) $display("[%0t] >>> cpu_rd_empty LOW — frame arrived at RX FIFO!", $time);
    always @(posedge dbg_gmii_rx_dv)  $display("[%0t] >>> gmii_rx_dv HIGH — GMII data valid", $time);
    always @(posedge dbg_mac_rx_sop)  $display("[%0t] >>> mac_rx_sop pulsed — MAC frame start", $time);
    always @(posedge dbg_mac_rx_eop)  $display("[%0t] >>> mac_rx_eop pulsed — MAC frame end", $time);
    always @(posedge dbg_cpu_rd_pop)  $display("[%0t] >>> cpu_rd_pop=1 — firmware popped RX packet", $time);
    always @(posedge dbg_cpu_rd_ren)  $display("[%0t] >>> cpu_rd_ren=1 — firmware reading RX byte addr=%0d", $time, dbg_cpu_rd_raddr);
    always @(posedge dbg_cpu_wr_push) begin
        $display("[%0t] >>> TX PUSH! len=%0d — firmware sent reply!", $time, dbg_cpu_wr_len);
        tx_push_seen = 1;
    end

    // ── 强制释放 RISC-V 复位 (BFM 有时卡住) ──
    // 写 lcpu_fpga_test 的 riscv_reset_l 寄存器 = 1
    // 寄存器在地址 0x100, 通过 lcpu_merge 端口1 (JTAG) 写入
    reg force_rst_done;
    initial force_rst_done = 0;

    // ── 测试流程 ──
    initial begin
        $display("=== RISC-V WebSoC Simulation ===");
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);
        $dumpvars(0, dut.u_gmii2mac.mac_rx_sop);
        $dumpvars(0, dut.u_gmii2mac.mac_rx_en);
        $dumpvars(0, dut.u_gmii2mac.mac_rx_data);
        $dumpvars(0, dut.u_gmii2mac.mac_rx_eop);

        reset_l = 0;
        sending = 0;

        // 复位
        #300;
        reset_l = 1;
        $display("[%0t] Reset released", $time);

        // 等 BFM 加载固件 (BFM 大概在 30ms 完成固件写入)
        #100000;  // 等到 100ms, BFM 早该完成了
        $display("[%0t] Force-releasing RISC-V reset...", $time);

        // 强制释放 RISC-V: 模拟 BFM 写 0x100=1
        force dut.u_reg.riscv_reset_l = 1'b1;
        #100;
        release dut.u_reg.riscv_reset_l;
        $display("[%0t] RISC-V reset force-released, waiting for firmware...", $time);

        // 给固件 50ms 跑到主循环 (足够了, SIM_FAST 跳过延时)
        #50000000;
        $display("[%0t] Injecting frame...", $time);

        // 发 ARP Request
        byte_idx = 0;
        sending  = 1;
        // 等帧发完
        wait(byte_idx >= frame_len);
        #1000;
        sending  = 0;
        $display("[%0t] Frame injection done", $time);

        // 等 CPU 处理
        #500000;
        $display("====================================");
        if (tx_push_seen)
          $display("  RESULT: Firmware sent a reply (TX PUSH detected)");
        else
          $display("  RESULT: NO reply sent — firmware didn't process frame");
        $display("====================================");
        $display("[%0t] Simulation done. Open gtkwave tb.vcd", $time);
        $display("  Key signals to check:");
        $display("  1. dut.rgmii_rxd / rgmii_rx_ctl  -- RGMII input");
        $display("  2. dut.u_gmii2mac.mac_rx_sop/en/data/eop -- MAC output");
        $display("  3. dut.cpu_rd_empty -- should go LOW when frame arrives");
        $finish;
    end

endmodule
