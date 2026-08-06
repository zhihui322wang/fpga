// tb_fast.v — 精简仿真: 验证 ARP Reply + fpga_ila 自动采集
`timescale 1ns / 100ps

module tb_fast;
    reg clk_50m, reset_l;
    reg rgmii_rxc;
    reg [3:0] rgmii_rxd;
    reg rgmii_rx_ctl;

    // ── ILA 仿真控制信号 ──
    // ILA 寄存器访问 — 通过层次化 force 操作标准总线
    wire [31:0] ila_rdata_bus;

    webserver_cpu_top #(.sim_mod(1)) dut (
        .clk_50m_in(clk_50m), .reset_l(reset_l),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_txc(), .rgmii_txd(), .rgmii_tx_ctl(),
        .Eth0_MDC(), .Eth0_MDIO(), .rgmii_reset_l(),
        .uart_rx(1'b1), .uart_tx(), .led_o(),
        // ILA 接口
        .ila_uart_rxd(1'b1), .ila_uart_txd()
    );

    // ILA 寄存器总线时钟 = clk_125m (仿真中 = clk_50m, vendor_stubs bypass)
    wire ila_clk = dut.clk_125m;

    wire cpu_rd_empty  = dut.cpu_rd_empty;
    wire tx_push       = dut.u_reg.cpu_wr_wpkt_push_ind;  // 用 IND 脉冲, 非电平信号
    wire [12:0] tx_len = dut.cpu_wr_wpkt_len[12:0];

    // RISC-V 关键信号监控
    wire       riscv_reset_l = dut.riscv_reset_l;
    wire       riscv_bus_req = dut.bus_req;
    wire [31:0] riscv_bus_addr = dut.bus_address;
    wire [3:0] led = dut.led_o;

    // ── ILA 精准触发: 后台监控 mac_rx_eop, 标记最佳 force trigger 时机 ──
    wire mac_rx_eop_sig = dut.mac_rx_eop;
    reg  ila_eop_seen = 0;
    initial begin
        #50000;  // 等 50µs (ILA 在 ~11µs 已 armed)
        @(posedge mac_rx_eop_sig);
        ila_eop_seen = 1'b1;
        $display("[%0t] TB_MON: mac_rx_eop detected!", $time);
    end

    initial clk_50m = 0;   always #10 clk_50m = ~clk_50m;
    initial rgmii_rxc = 0; always #10 rgmii_rxc = ~rgmii_rxc;

    // ── Ethernet 帧 (含前导码, 共 50 字节) ──
    // 前导码: 7×0x55 + 1×0xD5 (SFD)
    // ── TCP SYN 帧: 向 FPGA (169.254.1.1:80) 发起连接 ──
    // PC: MAC=11:22:33:44:55:66, IP=169.254.1.100, Port=4660
    // FPGA: MAC=00:00:01:02:04:05, IP=169.254.1.1, Port=80
    reg [7:0] frame [0:127];
    integer   frame_len, byte_idx;
    reg       sending;

    initial begin : build_frame
        integer j;
        // ── 前导码 8B ──
        frame[0]=8'h55; frame[1]=8'h55; frame[2]=8'h55; frame[3]=8'h55;
        frame[4]=8'h55; frame[5]=8'h55; frame[6]=8'h55; frame[7]=8'hD5;
        // ── Ethernet: Dst=FPGA MAC (00:00:01:02:04:05) ──
        frame[ 8]=8'h00; frame[ 9]=8'h00; frame[10]=8'h01; frame[11]=8'h02; frame[12]=8'h04; frame[13]=8'h05;
        // ── Ethernet: Src=PC MAC (11:22:33:44:55:66) ──
        frame[14]=8'h11; frame[15]=8'h22; frame[16]=8'h33; frame[17]=8'h44; frame[18]=8'h55; frame[19]=8'h66;
        // ── EtherType: 0x0800 (IPv4) ──
        frame[20]=8'h08; frame[21]=8'h00;
        // ── IP Header (20B): Ver=4,IHL=5 ; DSCP+ECN=0 ──
        frame[22]=8'h45; frame[23]=8'h00;
        // ── IP Total Length = 40 (0x0028) ──
        frame[24]=8'h00; frame[25]=8'h28;
        // ── IP Identification = 0x0001 ──
        frame[26]=8'h00; frame[27]=8'h01;
        // ── IP Flags+Fragment = 0x0000 ──
        frame[28]=8'h00; frame[29]=8'h00;
        // ── IP TTL=64, Protocol=6 (TCP) ──
        frame[30]=8'h40; frame[31]=8'h06;
        // ── IP Header Checksum = 0x246E ──
        frame[32]=8'h24; frame[33]=8'h6E;
        // ── IP Src: 169.254.1.100 ──
        frame[34]=8'hA9; frame[35]=8'hFE; frame[36]=8'h01; frame[37]=8'h64;
        // ── IP Dst: 169.254.1.1 ──
        frame[38]=8'hA9; frame[39]=8'hFE; frame[40]=8'h01; frame[41]=8'h01;
        // ── TCP Src Port = 4660 (0x1234) ──
        frame[42]=8'h12; frame[43]=8'h34;
        // ── TCP Dst Port = 80 (0x0050) ──
        frame[44]=8'h00; frame[45]=8'h50;
        // ── TCP Seq = 0x20000000 (PC ISN) ──
        frame[46]=8'h20; frame[47]=8'h00; frame[48]=8'h00; frame[49]=8'h00;
        // ── TCP Ack = 0 ──
        frame[50]=8'h00; frame[51]=8'h00; frame[52]=8'h00; frame[53]=8'h00;
        // ── TCP DataOffset=5(20B), Flags=SYN(0x02) ──
        frame[54]=8'h50; frame[55]=8'h02;
        // ── TCP Window = 1460 (0x05B4) ──
        frame[56]=8'h05; frame[57]=8'hB4;
        // ── TCP Checksum = 0x2149 ──
        frame[58]=8'h21; frame[59]=8'h49;
        // ── TCP Urgent = 0 ──
        frame[60]=8'h00; frame[61]=8'h00;
        // ── 前导码 8B + Eth 14B + IP 20B + TCP 20B = 62B ──
        frame_len = 62;
    end

    // RGMII DDR 驱动 — 数据在采样沿的对侧驱动, 保证IDDR采样时数据稳定
    //   negedge 驱动 lower nibble → IDDR posedge 采样为 Q1 (gmii_rxd[3:0])
    //   posedge 驱动 upper nibble → IDDR negedge 采样为 Q2 (gmii_rxd[7:4])
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

    // ── PicoRV32 内部信号 (通过 hierarchy 访问) ──
    wire picorv32_trap;
    wire picorv32_mem_valid;
    wire [31:0] picorv32_mem_addr;
    assign picorv32_trap      = dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_RiscV32_LocalBus.u_picorv32.trap;
    assign picorv32_mem_valid = dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_RiscV32_LocalBus.u_picorv32.mem_valid;
    assign picorv32_mem_addr  = dut.u_riscv.riscv_cpu_generation.u_riscv_cpu.u_RiscV32_LocalBus.u_picorv32.mem_addr;

    // 监控 PicoRV32 mem_valid
    always @(posedge picorv32_mem_valid) begin
        $display("[%0t] >>> PicoRV32 mem_valid=1 addr=0x%08h — CPU FETCHING!", $time, picorv32_mem_addr);
    end

    // 监控 PicoRV32 trap
    always @(posedge picorv32_trap) begin
        $display("[%0t] >>> PicoRV32 TRAP=1 — ILLEGAL INSN OR FAULT!", $time);
    end

    // ── 事件监控 ──
    reg tx_seen;
    initial tx_seen = 0;
    always @(posedge tx_push) begin
        $display("[%0t] >>> TX PUSH len=%0d — FIRMWARE SENT REPLY!", $time, tx_len);
        tx_seen = 1;
    end

    // ── GMII / MAC RX 路径调试 (通过 hierarchy) ──
    wire       gmii_rx_dv   = dut.u_bridge.u_rx.gmii_rx_dv;
    wire [7:0] gmii_rxd     = dut.u_bridge.u_rx.gmii_rxd;
    wire       gmii_rx_clk  = dut.u_bridge.u_rx.gmii_rx_clk;
    // gmii2mac 内部 (通过 eth_presemble 后)
    wire       rx_data_en_mac_in  = dut.u_gmii2mac.rx_data_en_mac_in;
    wire [7:0] rx_data_mac_in     = dut.u_gmii2mac.rx_data_mac_in;
    // mac_rx 输出
    wire       mac_rx_sop  = dut.u_gmii2mac.mac_rx_sop;
    wire       mac_rx_en   = dut.u_gmii2mac.mac_rx_en;
    wire       mac_rx_eop  = dut.u_gmii2mac.mac_rx_eop;
    wire [7:0] mac_rx_data = dut.u_gmii2mac.mac_rx_data;
    // dual_clock_fifo 状态
    wire       rx_afifo_empty = dut.u_gmii2mac.rx_afifo_empty;
    wire [9:0] rx_afifo_data  = dut.u_gmii2mac.rx_afifo_data;

    // GMII RX 字节计数器 (监控帧数据)
    reg [31:0] gmii_byte_cnt;
    reg        gmii_rx_active;
    initial gmii_byte_cnt = 0;
    initial gmii_rx_active = 0;
    always @(posedge gmii_rx_clk) begin
        if (gmii_rx_dv && !gmii_rx_active) begin
            gmii_rx_active <= 1;
            gmii_byte_cnt  <= 1;
            $display("[%0t] GMII: RX start, byte[0]=0x%02h", $time, gmii_rxd);
        end else if (gmii_rx_dv && gmii_rx_active) begin
            gmii_byte_cnt <= gmii_byte_cnt + 1;
            if (gmii_byte_cnt < 16) $display("[%0t] GMII: byte[%0d]=0x%02h", $time, gmii_byte_cnt, gmii_rxd);
        end else if (!gmii_rx_dv && gmii_rx_active) begin
            gmii_rx_active <= 0;
            $display("[%0t] GMII: RX end, total=%0d bytes", $time, gmii_byte_cnt);
        end
    end

    // mac_rx 包监控
    reg [31:0] mac_byte_cnt;
    reg        mac_rx_active;
    initial mac_byte_cnt = 0;
    initial mac_rx_active = 0;
    always @(posedge dut.clk_125m) begin  // clk_125m not directly accessible, use clk_50m
        if (mac_rx_sop && !mac_rx_active) begin
            mac_rx_active <= 1;
            mac_byte_cnt  <= 1;
            $display("[%0t] MAC_RX: SOP, byte[0]=0x%02h", $time, mac_rx_data);
        end else if (mac_rx_en && mac_rx_active) begin
            mac_byte_cnt <= mac_byte_cnt + 1;
            if (mac_byte_cnt < 50) $display("[%0t] MAC_RX: byte[%0d]=0x%02h", $time, mac_byte_cnt, mac_rx_data);
        end
        if (mac_rx_eop) begin
            $display("[%0t] MAC_RX: EOP, total=%0d bytes", $time, mac_byte_cnt);
            mac_rx_active <= 0;
        end
        if (rx_data_en_mac_in && !mac_rx_active) begin
            $display("[%0t] eth_presemble OUT: first byte=0x%02h (GMII→MAC path active)", $time, rx_data_mac_in);
        end
    end

    // cpu_channel 内部信号 (FIFO push)
    wire fifo_full  = dut.u_cpu_channel.u_ram2pktfifo_int.full;
    wire fifo_push  = dut.u_cpu_channel.u_ram2pktfifo_int.wpkt_push;
    wire [12:0] fifo_len = dut.u_cpu_channel.u_ram2pktfifo_int.wpkt_len;
    always @(posedge fifo_push) begin
        $display("[%0t] >>> FIFO PUSH len=%0d full=%b — PACKET CAPTURED!", $time, fifo_len, fifo_full);
    end

    // ── 调试: cpu_rd_empty 信号链 ──
    // package_fifo_v2 内部 empty 信号
    wire pkg_fifo_empty = dut.u_cpu_channel.u_package_fifo_cpu_rd.empty;

    // 监控 cpu_rd_empty 的任何跳变
    reg last_cpu_rd_empty;
    initial last_cpu_rd_empty = 1'bx;
    always @(posedge dut.clk_50m) begin
        if (last_cpu_rd_empty !== 1'bx && cpu_rd_empty !== last_cpu_rd_empty) begin
            $display("[%0t] >>> cpu_rd_empty CHANGED: %b → %b", $time, last_cpu_rd_empty, cpu_rd_empty);
        end
        last_cpu_rd_empty <= cpu_rd_empty;
    end

    // 监控 firmware 的 pop 脉冲 (cpu_rd_rpkt_pop_ind)
    wire cpu_rd_pop_ind = dut.u_reg.cpu_rd_rpkt_pop_ind;
    always @(posedge cpu_rd_pop_ind) begin
        $display("[%0t] >>> FIRMWARE POP (rpkt_pop_ind=1) — firmware started reading pkt!", $time);
    end

    // 监控 firmware 的 TX push 脉冲
    wire cpu_tx_push_ind = dut.u_reg.cpu_wr_wpkt_push_ind;
    always @(posedge cpu_tx_push_ind) begin
        $display("[%0t] >>> FIRMWARE TX PUSH IND — firmware sent packet!", $time);
    end

    // ── GMII TX 路径验证 ──
    wire       gmii_tx_en = dut.gmii_tx_en;
    wire [7:0] gmii_txd   = dut.gmii_txd;
    reg [31:0] gmii_tx_byte_cnt;
    reg        gmii_tx_active;
    reg        tcp_synack_seen;      // 检测到 TCP SYN+ACK 回复
    initial gmii_tx_byte_cnt = 0;
    initial gmii_tx_active = 0;
    initial tcp_synack_seen = 0;
    always @(posedge dut.clk_125m) begin
        if (gmii_tx_en && !gmii_tx_active) begin
            gmii_tx_active <= 1;
            gmii_tx_byte_cnt <= 1;
            $display("[%0t] GMII_TX: SOP, byte[0]=0x%02h", $time, gmii_txd);
        end else if (gmii_tx_en && gmii_tx_active) begin
            gmii_tx_byte_cnt <= gmii_tx_byte_cnt + 1;
            if (gmii_tx_byte_cnt < 60) $display("[%0t] GMII_TX: byte[%0d]=0x%02h", $time, gmii_tx_byte_cnt, gmii_txd);
            // TCP Flags 在 byte[47] (Eth 14 + IP 20 + TCP[13]), +8B preamble = byte[55]
            // gmii_tx_byte_cnt 在 NBA 递增前为当前字节索引, byte[55] → count=55
            if (gmii_tx_byte_cnt == 55 && gmii_txd == 8'h12) begin
                tcp_synack_seen <= 1;
                $display("[%0t] GMII_TX: ★★★ TCP SYN+ACK DETECTED! (flags=0x12 at byte[35])", $time);
            end
        end else if (!gmii_tx_en && gmii_tx_active) begin
            gmii_tx_active <= 0;
            $display("[%0t] GMII_TX: EOP, total=%0d bytes", $time, gmii_tx_byte_cnt);
        end
    end

    // 监控 CPU 总线读地址 0x6000 (cpu_rd_empty 寄存器)
    always @(posedge dut.clk_50m) begin
        if (dut.bus_req && dut.bus_rhwl && dut.bus_address == 32'h6000) begin
            $display("[%0t] >>> CPU READ RD_EMPTY reg (addr=0x6000), rdata[0]=%b", $time, dut.bus_rdata[0]);
        end
    end

    // 监控 CPU 总线读地址 0x6002 (pkt_len 寄存器) — firmware checks len
    always @(posedge dut.clk_50m) begin
        if (dut.bus_req && dut.bus_rhwl && dut.bus_address == 32'h6002) begin
            $display("[%0t] >>> CPU READ PKT_LEN reg (addr=0x6002), rdata=0x%08h", $time, dut.bus_rdata);
        end
    end

    // 监控 RISC-V 总线活动
    reg riscv_bus_active;
    initial riscv_bus_active = 0;
    always @(posedge riscv_bus_req) begin
        if (!riscv_bus_active) begin
            $display("[%0t] >>> RISC-V first bus req: addr=0x%08h — CPU IS ALIVE!", $time, riscv_bus_addr);
            riscv_bus_active = 1;
        end
    end

    // 监控 RISC-V 复位释放
    reg riscv_reset_seen;
    initial riscv_reset_seen = 0;
    always @(posedge riscv_reset_l) begin
        $display("[%0t] >>> riscv_reset_l released (0→1)", $time);
        riscv_reset_seen = 1;
    end

    // 每隔 500us 报告一次状态
    initial begin
        #500000;  // 500us
        $display("[%0t] STATUS: riscv_reset_l=%b, led=%b, bus_req=%b, cpu_rd_empty=%b",
                 $time, riscv_reset_l, led, riscv_bus_req, cpu_rd_empty);
        #500000;  // 1ms
        $display("[%0t] STATUS: riscv_reset_l=%b, led=%b, bus_req=%b, cpu_rd_empty=%b",
                 $time, riscv_reset_l, led, riscv_bus_req, cpu_rd_empty);
        #500000;  // 1.5ms
        $display("[%0t] STATUS: riscv_reset_l=%b, led=%b, bus_req=%b, cpu_rd_empty=%b",
                 $time, riscv_reset_l, led, riscv_bus_req, cpu_rd_empty);
        #500000;  // 2ms
        $display("[%0t] STATUS: riscv_reset_l=%b, led=%b, bus_req=%b, cpu_rd_empty=%b",
                 $time, riscv_reset_l, led, riscv_bus_req, cpu_rd_empty);
    end

    // ── ILA 寄存器访问任务 ──
    // fcapz_ela 寄存器地址
    localparam FCAPZ_CTRL       = 16'h0004;
    localparam FCAPZ_STATUS     = 16'h0008;
    localparam FCAPZ_PRETRIG    = 16'h0014;
    localparam FCAPZ_CAPTURE_LEN= 16'h001C;
    localparam FCAPZ_TRIG_MODE  = 16'h0020;
    localparam FCAPZ_TRIG_VALUE = 16'h0024;
    localparam FCAPZ_TRIG_MASK  = 16'h0028;  // words 0-3 (128bit legacy)
    localparam FCAPZ_TRIG_MASK_EXT = 16'h00E0;  // words 4+ (扩展地址)
    localparam FCAPZ_TRIG_VALUE_EXT = 16'h00D0;
    localparam FCAPZ_BURST_PTR  = 16'h002C;
    localparam FCAPZ_SEG_START  = 16'h00C8;
    localparam FCAPZ_DATA_BASE  = 16'h0100;

    // CTRL/STATUS 位定义
    localparam CTRL_ARM_BIT   = 0;
    localparam CTRL_FORCE_BIT = 2;
    localparam ST_ARMED_BIT   = 0;
    localparam ST_TRIG_BIT    = 1;
    localparam ST_DONE_BIT    = 2;

    integer   ila_file;
    reg [31:0] ila_rd_val;
    reg [31:0] ila_seg_start, ila_cap_len, ila_total_words;

    // ── ILA 寄存器写 (层次化 force 标准总线) ──
    task ila_write(input [15:0] addr, input [31:0] data);
        begin
            @(posedge ila_clk);
            force dut.ila_we   = 1'b1;
            force dut.ila_re   = 1'b0;
            force dut.ila_addr = addr;
            force dut.ila_wdata = data;
            @(posedge ila_clk);
            force dut.ila_we   = 1'b0;
            @(posedge ila_clk);
            #100;  // 等待 CDC + 寄存器生效
        end
    endtask

    // ── ILA 寄存器读 (层次化 force 标准总线) ──
    task ila_read(input [15:0] addr);
        begin
            @(posedge ila_clk);
            force dut.ila_we   = 1'b0;
            force dut.ila_re   = 1'b1;
            force dut.ila_addr = addr;
            @(posedge ila_clk);
            @(posedge ila_clk);
            ila_rd_val  = dut.ila_rdata;
            #50;
        end
    endtask

    // ── ILA 轮询 STATUS 直到 bit 置位 ──
    task ila_wait_status_bit(input integer bit_idx, input integer timeout_ns);
        integer elapsed;
        reg found;
        begin
            elapsed = 0;
            found = 0;
            while (elapsed < timeout_ns && !found) begin
                ila_read(FCAPZ_STATUS);
                if (ila_rd_val[bit_idx]) begin
                    $display("[%0t] ILA: STATUS bit%0d = 1 (val=0x%08h)", $time, bit_idx, ila_rd_val);
                    found = 1;
                end else begin
                    #1000;
                    elapsed = elapsed + 1000;
                end
            end
            if (!found)
                $display("[%0t] ILA: WARNING — STATUS bit%0d timeout after %0d ns", $time, bit_idx, timeout_ns);
        end
    endtask

    // ── ILA 回读全部采样数据 → ila_dump.txt ──
    task ila_readback_and_dump;
        integer i, w;
        reg [31:0] word_val;
        reg [159:0] sample;  // 151bit = 5 words (160bit padded)
        begin
            $display("[%0t] ILA: Reading back capture data...", $time);

            // 读 SEG_START (物理起始地址)
            ila_read(FCAPZ_SEG_START);
            ila_seg_start = ila_rd_val;
            $display("[%0t] ILA: SEG_START = %0d (0x%08h)", $time, ila_seg_start, ila_seg_start);

            // 读 CAPTURE_LEN (实际采集样本数, 含 pre+post)
            ila_read(FCAPZ_CAPTURE_LEN);
            ila_cap_len = ila_rd_val;
            if (ila_cap_len == 0 || ila_cap_len > 2048) ila_cap_len = 2048;
            $display("[%0t] ILA: CAPTURE_LEN = %0d samples", $time, ila_cap_len);

            // 每样本 151bit = 5 个 32bit word
            ila_total_words = ila_cap_len * 5;

            // 打开 dump 文件
            ila_file = $fopen("ila_dump.txt", "w");
            if (ila_file == 0) begin
                $display("[%0t] ILA: ERROR — cannot open ila_dump.txt", $time);
            end else begin
                $fwrite(ila_file, "# ILA Capture Dump — RiscV WebSoC\n");
                $fwrite(ila_file, "# CAPTURE_LEN=%0d WORDS_PER_SAMPLE=5 TOTAL_BITS=151\n", ila_cap_len);
                $fwrite(ila_file, "# PROBES(27): gmii_rx_dv(1) gmii_rxd(8) gmii_tx_en(1) gmii_txd(8) mac_rx_sop(1) mac_rx_en(1) mac_rx_data(8) mac_rx_eop(1) bus_req(1) bus_rhwl(1) bus_address(32) bus_rdata(32) bus_ack(1) gmii_tx_er(1) mac_tx_sop(1) mac_tx_en(1) mac_tx_data(8) mac_tx_eop(1) mac_tx_err(1) cpu_rd_empty(1) cpu_wr_full(1) cpu_rd_rpkt_pop_ind(1) cpu_wr_wpkt_push_ind(1) cpu_wr_wen_ind(1) cpu_rd_ren(1) bus_wdata(32) led_val(4)\n");
                $fwrite(ila_file, "# format: SAMPLE_INDEX PROBE_HEX(40chars)\n");

                // 设置 BURST_PTR 到起始地址 (基址)
                ila_write(FCAPZ_BURST_PTR, ila_seg_start);

                // 逐样本读取 — 使用扁平偏移编址
                // wrapper: bram_rd_addr = bram_base + (data_byte_off / (WORDS*4))
                //          WORDS=5 → stride=20B, data_byte_off=i*20+0/4/8/12/16
                //          → data_sample = i → bram_rd_addr = bram_base + i (12-bit auto-wrap)
                // fcapz:  word_index = ((addr - DATA_BASE)>>2) % 5 → 0/1/2/3/4
                for (i = 0; i < ila_cap_len; i = i + 1) begin
                    // 读 5 个 word, 每个 word 通过地址编码样本偏移
                    ila_read(FCAPZ_DATA_BASE + i * 20 + 0);
                    sample[31:0]   = ila_rd_val;
                    ila_read(FCAPZ_DATA_BASE + i * 20 + 4);
                    sample[63:32]  = ila_rd_val;
                    ila_read(FCAPZ_DATA_BASE + i * 20 + 8);
                    sample[95:64]  = ila_rd_val;
                    ila_read(FCAPZ_DATA_BASE + i * 20 + 12);
                    sample[127:96] = ila_rd_val;
                    ila_read(FCAPZ_DATA_BASE + i * 20 + 16);
                    sample[159:128] = ila_rd_val;

                    $fwrite(ila_file, "%0d %040h\n", i, sample);
                end

                $fclose(ila_file);
                $display("[%0t] ILA: Dump complete — %0d samples → ila_dump.txt", $time, ila_cap_len);
            end
        end
    endtask

    // ── ILA 采集流程: 配置 → ARM → 等待 DONE → 回读 ──
    task ila_capture_sequence;
        begin
            $display("[%0t] === ILA Capture Sequence Start ===", $time);

            // 等复位释放后再配置
            @(posedge reset_l);
            #10000;  // 等 10us 让 ILA 内部复位完成
            $display("[%0t] ILA: Configuring trigger (mac_rx_sop=1)", $time);

            // 配置触发: mac_rx_sop=1 (probe4, bit_lo=18)
            // TRIG_MODE: bit0=value_match (启用值匹配触发)
            ila_write(FCAPZ_TRIG_MODE, 32'd1);

            // TRIG_MASK word0 = bit[18]=1 (只关心 mac_rx_sop)
            ila_write(FCAPZ_TRIG_MASK, 32'h0004_0000);
            // TRIG_MASK word1/2/3/4 清零 — 上电默认全1, 必须显式清零
            ila_write(FCAPZ_TRIG_MASK + 1, 32'h0);      // word1: bits 63:32
            ila_write(FCAPZ_TRIG_MASK + 2, 32'h0);      // word2: bits 95:64
            ila_write(FCAPZ_TRIG_MASK + 3, 32'h0);      // word3: bits 127:96
            ila_write(FCAPZ_TRIG_MASK_EXT,  32'h0);      // word4: bits 159:128 (EXT地址)

            // TRIG_VALUE word0 = bit[18]=1 (期望 mac_rx_sop=1)
            ila_write(FCAPZ_TRIG_VALUE, 32'h0004_0000);
            // TRIG_VALUE word1/2/3/4 保持 0 (上电默认=0, 不需改, 但保险起见可写)

            // PRETRIG = 2047 (最大预触发，抓捕全过程)
            ila_write(FCAPZ_PRETRIG, 32'd2047);
            // 读回验证
            ila_read(FCAPZ_PRETRIG);
            $display("[%0t] ILA: PRETRIG readback = %0d (expect 2047)", $time, ila_rd_val);
            ila_read(FCAPZ_TRIG_MODE);
            $display("[%0t] ILA: TRIG_MODE readback = %0d (expect 1)", $time, ila_rd_val);
            ila_read(FCAPZ_TRIG_MASK);
            $display("[%0t] ILA: TRIG_MASK readback = 0x%08h (expect 0x00040000)", $time, ila_rd_val);

            // ARM (CTRL bit0 toggle)
            ila_write(FCAPZ_CTRL, 32'd1);
            $display("[%0t] ILA: ARMED — waiting for mac_rx_sop trigger...", $time);

            // 验证 ARMED 状态
            ila_read(FCAPZ_STATUS);
            $display("[%0t] ILA: STATUS after ARM = 0x%08h (armed=%b)", $time, ila_rd_val, ila_rd_val[ST_ARMED_BIT]);

            // 如果没 arm 成功, 再试一次
            if (!ila_rd_val[ST_ARMED_BIT]) begin
                ila_write(FCAPZ_CTRL, 32'd1);
                $display("[%0t] ILA: Re-ARM sent", $time);
            end
        end
    endtask

    // ── 主流程 ──
    initial begin
        $display("=== RiscV WebSoC + ILA Simulation ===");
        $dumpfile("tb_fast.vcd");
        $dumpvars(0, tb_fast);
        reset_l = 0; sending = 0;

        // 启动 ILA 采集 (配置触发 → ARM, 等 mac_rx_sop=1)
        fork
            ila_capture_sequence;
        join_none

        #300; reset_l = 1;
        $display("[%0t] Reset released (top-level)", $time);

        // 等 BFM 加载固件 (1129字 × ~52周期 = ~60k周期 ≈ 1.2ms @50MHz)
        #2000000;
        $display("[%0t] Sending TCP SYN frame (→ 169.254.1.1:80)", $time);
        byte_idx = 0; sending = 1;
        wait(byte_idx >= frame_len);
        #1000; sending = 0;
        $display("[%0t] TCP SYN sent, cpu_rd_empty=%b", $time, cpu_rd_empty);

        // ── ILA 回读: 立即 force trigger 捕获 (PRETRIG=2047 → 16µs 预触发) ──
        // MAC_RX EOP 在 Frame sent 后约 0.2µs, force trigger 后预触发窗口能覆盖 ARP SOP(2.0007ms)
        $display("[%0t] === ILA Readback Phase ===", $time);
        ila_read(FCAPZ_STATUS);
        $display("[%0t] ILA: STATUS=0x%08h (done=%b trig=%b armed=%b)",
                 $time, ila_rd_val, ila_rd_val[ST_DONE_BIT], ila_rd_val[ST_TRIG_BIT], ila_rd_val[ST_ARMED_BIT]);

        if (!ila_rd_val[ST_DONE_BIT]) begin
            // 等待 MAC RX EOP (后台监控已检测, 或在 ARP 发送期间到来)
            if (!ila_eop_seen) begin
                $display("[%0t] ILA: Waiting for mac_rx_eop...", $time);
                wait(ila_eop_seen);
            end
            // EOP 刚发生, 立即 force trigger → 预触发窗口完美覆盖整个 ARP 帧
            $display("[%0t] ILA: Force triggering immediately after EOP...", $time);
            ila_write(FCAPZ_CTRL, 32'h4);  // CTRL bit2 = FORCE
            // 等 DONE
            ila_wait_status_bit(ST_DONE_BIT, 500000);
        end

        // 回读采集数据
        ila_readback_and_dump;

        // 仿真状态检查
        $display("[%0t] Final: riscv_reset_l=%b, led=%b, bus_active=%b, rx_empty=%b",
                 $time, riscv_reset_l, led, riscv_bus_active, cpu_rd_empty);
        if (tcp_synack_seen)
            $display("=== PASS: Firmware sent TCP SYN+ACK! ===");
        else if (tx_seen)
            $display("=== PASS: Firmware sent reply (not SYN+ACK) ===");
        else if (riscv_bus_active)
            $display("=== FAIL: CPU alive but no reply (firmware bug?) ===");
        else
            $display("=== FAIL: CPU never started ===");

        $display("[%0t] === Simulation Complete ===", $time);
        $display("  Waveform: gtkwave tb_fast.vcd");
        $display("  ILA data: python3 sim/ila_dump_to_vcd.py ila_dump.txt ila_wave.vcd");
        $display("  Then:     gtkwave ila_wave.vcd");
        $finish;
    end
endmodule
