//-----------------------------------------------------------------
// webserver_cpu_top.v — RiscV WebSoC 顶层模块
// 集成: PLL + RGMII Bridge + gmii2mac + cpu_channel + RISC-V + 寄存器
// 目标: XC7A35T-FGG484-2
//-----------------------------------------------------------------
`include "define.sv"

module webserver_cpu_top #(
    parameter sim_mod = 0           // 0=真实硬件, 1=仿真 (PLL bypass + LCPU BFM)
) (
    // 系统
    input  wire       clk_50m_in,
    input  wire       reset_l,

    // RGMII
    output wire       rgmii_txc,
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    input  wire       rgmii_rxc,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,

    // MDIO
    output wire       Eth0_MDC,
    inout  wire       Eth0_MDIO,

    // PHY 控制
    output wire       rgmii_reset_l,

    // UART
    input  wire       uart_rx,
    output wire       uart_tx,

    // 调试模式选择 (拨码开关 SW0): 上传固件 / ILA 抓波形 二选一
    input  wire       debug_sel,

    // LED
    output wire [3:0] led_o
);

  //============================================================================
  // 参数
  //============================================================================
  localparam lcpu_type       = "uart";
  localparam uart_baud_rate  = 115200;
  localparam riscv_inst_en   = 1;
  localparam instr_databits  = 32;
  localparam init_addr_width = 13;
  localparam init_addr_depth = 1024 * 4;  // 4096 words (16KB), was 2048
  localparam device_vendor   = `DEVICE_VENDOR;
  localparam instr_ram_type  = `LARGER_RAM;
  localparam init_blockram_size = 8;

  // cpu_channel 参数
  localparam CPU_BUF_ADDR_WIDTH = 12;
  localparam CPU_BUF_DATA_WIDTH = 8;
  localparam CPU_BUF_PARA_WIDTH = 1;

  //============================================================================
  // fpga_ila 调试系统参数 (UART, 921600 baud)
  //============================================================================
  localparam ILA_NUM_CORES     = 1;
  localparam [2:0] ILA_TRANSPORT_EN = 3'b001;   // UART only
  localparam ILA_BAUD          = 921600;
  localparam ILA_CLK_HZ        = 50_000_000;     // Hub clk = 50MHz

  //============================================================================
  // 时钟 & 复位
  //============================================================================
  wire clk_50m;        // CPU 域
  wire clk_125m;       // MAC 域
  wire clk_200m;       // IDELAYCTRL
  wire clk_125m_tx;    // RGMII TX
  wire pll_locked;
  wire sys_rst_n;      // reset_l & pll_locked

  // 统一时钟: 仿真用 vendor_stubs MMCM stub, 上板用真实 MMCM
  mmcm_50_125 u_pll (
      .clk_50m      (clk_50m_in),
      .clk_125m     (clk_125m),
      .clk_200m     (clk_200m),
      .clk_125m_tx  (clk_125m_tx),
      .clk_50m_cpu  (clk_50m),
      .locked       (pll_locked),
      .rst_n        (reset_l)
  );

  assign sys_rst_n = reset_l & pll_locked;

  //============================================================================
  // PHY 复位 (~16ms 延时释放)
  //============================================================================
  reg  [20:0] phy_rst_cnt;
  reg         phy_rst_n_r;

  always @(posedge clk_125m or negedge sys_rst_n)
    if (!sys_rst_n) {phy_rst_cnt, phy_rst_n_r} <= 0;
    else if (!phy_rst_n_r) begin
      phy_rst_cnt <= phy_rst_cnt + 1;
      if (phy_rst_cnt == 21'h1F_FFFF) phy_rst_n_r <= 1'b1;
    end

  assign rgmii_reset_l = phy_rst_n_r;

  //============================================================================
  // RGMII ↔ GMII 信号
  //============================================================================
  wire        gmii_rx_clk, gmii_rx_dv, gmii_rx_er;
  wire [7:0]  gmii_rxd;
  wire [7:0]  gmii_txd;
  wire        gmii_tx_en, gmii_tx_er;

  //============================================================================
  // gmii2mac ↔ cpu_channel 信号 (MAC 包流)
  //============================================================================
  wire        mac_rx_sop, mac_rx_en, mac_rx_eop, mac_rx_err;
  wire [7:0]  mac_rx_data;
  wire        mac_tx_sop, mac_tx_en, mac_tx_eop, mac_tx_err;
  wire [7:0]  mac_tx_data;

  //============================================================================
  // MAC/CDC 调试计数器 — 丢包根因定位用 (gmii2mac 统计输出 + cpu_channel 调试)
  //============================================================================
  wire [31:0] rx_afifo_full_cnt;    // gmii2mac 内部异步 FIFO (Eth_RXC→125m) 满计数
  wire [31:0] rx_afifo_empty_cnt;
  wire [31:0] rx_data_err_line;
  wire [31:0] rx_correct_pkt_cnt;   // 好 FCS 帧计数 (物理层正常则 >0)
  wire [31:0] rx_crc_err_pkt_cnt;   // 坏 FCS 帧计数 (物理层损坏则 >0)
  wire [31:0] tx_correct_pkt_cnt;
  wire [31:0] tx_error_pkt_cnt;
  wire [7:0]  recv_pkt_drop_cnt;    // cpu_channel 125m→50m FIFO 满丢包计数
  wire        mac_in_full;          // package_fifo_v2 RX full 标志 (卡高=CDC 问题)

  //============================================================================
  // cpu_channel ↔ lcpu_fpga_test 信号 (CPU FIFO)
  //============================================================================
  wire        cpu_rd_empty;
  wire        cpu_rd_rpkt_pop;
  wire        cpu_rd_rpkt_pop_ind;
  wire [CPU_BUF_ADDR_WIDTH:0] cpu_rd_rpkt_len;
  wire [CPU_BUF_PARA_WIDTH-1:0] cpu_rd_rpkt_para;
  wire        cpu_rd_ren;
  wire [CPU_BUF_ADDR_WIDTH-1:0] cpu_rd_raddr;
  wire [CPU_BUF_DATA_WIDTH-1:0] cpu_rd_rdata;
  wire        cpu_rd_reop_pre;

  wire        cpu_wr_full;
  wire        cpu_wr_wen;
  wire        cpu_wr_wen_ind;
  wire [CPU_BUF_ADDR_WIDTH-1:0] cpu_wr_waddr;
  wire [CPU_BUF_DATA_WIDTH-1:0] cpu_wr_wdata;
  wire [CPU_BUF_ADDR_WIDTH:0] cpu_wr_wpkt_len;
  wire        cpu_wr_wpkt_push;
  wire        cpu_wr_wpkt_push_ind;

  // lcpu_fpga_test 输出的 32-bit 信号截断到 cpu_channel 位宽
  wire [31:0] fpga_cpu_rd_raddr, fpga_cpu_wr_waddr, fpga_cpu_wr_wdata, fpga_cpu_wr_wpkt_len;
  wire [31:0] fpga_cpu_rd_rpkt_len, fpga_cpu_rd_rdata;
  wire [0:0]  fpga_cpu_rd_empty,   fpga_cpu_rd_reop_pre, fpga_cpu_wr_full;
  wire [0:0]  fpga_cpu_rd_rpkt_pop, fpga_cpu_rd_ren;
  wire [0:0]  fpga_cpu_wr_wen,     fpga_cpu_wr_wpkt_push;

  // cpu_channel OUTPUT → lcpu_fpga_test INPUT (CPU读)
  assign fpga_cpu_rd_empty   = cpu_rd_empty;
  assign fpga_cpu_rd_reop_pre = cpu_rd_reop_pre;
  assign fpga_cpu_rd_rpkt_len = { {(32-(CPU_BUF_ADDR_WIDTH+1)){1'b0}}, cpu_rd_rpkt_len };
  assign fpga_cpu_rd_rdata    = { {(32-CPU_BUF_DATA_WIDTH){1'b0}}, cpu_rd_rdata };
  // lcpu_fpga_test OUTPUT → cpu_channel INPUT (CPU写)
  assign cpu_rd_raddr    = fpga_cpu_rd_raddr[CPU_BUF_ADDR_WIDTH-1:0];
  assign cpu_rd_ren      = fpga_cpu_rd_ren[0];
  // cpu_channel OUTPUT → lcpu_fpga_test INPUT (CPU写)
  assign fpga_cpu_wr_full = cpu_wr_full;
  // lcpu_fpga_test OUTPUT → cpu_channel INPUT (CPU写)
  assign cpu_wr_waddr    = fpga_cpu_wr_waddr[CPU_BUF_ADDR_WIDTH-1:0];
  assign cpu_wr_wdata    = fpga_cpu_wr_wdata[CPU_BUF_DATA_WIDTH-1:0];
  assign cpu_wr_wpkt_len = fpga_cpu_wr_wpkt_len[CPU_BUF_ADDR_WIDTH:0];

  //============================================================================
  // LCPU 总线 (lcpu_riscv_wrapper → lcpu_fpga_test)
  //============================================================================
  wire        bus_req, bus_rhwl;
  wire [31:0] bus_wdata, bus_address;
  wire        bus_ack;
  wire [31:0] bus_rdata;

  // 指令 RAM 接口 (共享: lcpu_fpga_test ↔ lcpu_riscv_wrapper)
  wire        pram_wr;
  wire [15:0] pram_addr;
  wire [31:0] pram_wdata;
  wire [31:0] pram_rdata;

  // RISC-V 复位
  wire [0:0]  riscv_reset_l;

  // LED / FPGA 版本
  wire [31:0] fpga_build_date, fpga_build_time;
  wire [3:0]  led_val;
  assign led_o = led_val;

  //============================================================================
  // fpga_ila 调试总线
  //============================================================================
  wire [ILA_NUM_CORES-1:0]     ila_we;
  wire [ILA_NUM_CORES-1:0]     ila_re;
  wire [15:0]                  ila_addr;
  wire [31:0]                  ila_wdata;
  wire [ILA_NUM_CORES*32-1:0]  ila_rdata;
  wire                         ila_jtag_clk;
  wire                         cpu_uart_tx;   // CPU UART TX 输出 (上传模式回显读命令)
  wire                         ila_uart_tx;   // ILA UART TX 输出 (调试模式发波形)

  //--------------------------------------------------------------------------
  // UART RX/TX 互斥复用 — 固件上传(115200) 与 ILA 抓波形(921600) 共用板载串口 L21/M21,
  //   用拨码开关 SW0 手工切换, 二者永不冲突:
  //     debug_sel=0 (SW0 拨到 ON,  接地) → 调试模式: uart_rx/tx 给 ILA,  CPU 侧置空闲
  //     debug_sel=1 (SW0 拨回 OFF, 上拉) → 上传模式: uart_rx/tx 给 CPU, ILA 侧置空闲
  //   物理开关是持续状态, GUI 打开串口触发的 DTR 复位 / 按键复位都无法改变它,
  //   从根上杜绝了启发式门控被复位重新打开的问题。
  //--------------------------------------------------------------------------
  wire ila_uart_rx = ~debug_sel ? uart_rx : 1'b1;   // ILA 侧 RX (调试时独享)
  wire cpu_uart_rx =  debug_sel ? uart_rx : 1'b1;   // CPU 侧 RX (上传时独享)
  assign uart_tx = debug_sel ? cpu_uart_tx : ila_uart_tx;  // TX 方向同样按模式复用

  //============================================================================
  // 1. fpga_build_time — 版本时间戳
  //============================================================================
  fpga_build_time u_build_time (
      .build_date (fpga_build_date),
      .build_time (fpga_build_time)
  );

  //============================================================================
  // 2. rgmii_gmii_bridge — RGMII ↔ GMII
  //============================================================================
  rgmii_gmii_bridge u_bridge (
      .gmii_tx_clk   (clk_125m_tx),
      .gmii_txd      (gmii_txd),
      .gmii_tx_en    (gmii_tx_en),
      .gmii_tx_er    (gmii_tx_er),
      .gmii_rx_clk   (gmii_rx_clk),
      .gmii_rxd      (gmii_rxd),
      .gmii_rx_dv    (gmii_rx_dv),
      .gmii_rx_er    (gmii_rx_er),
      .rgmii_txc     (rgmii_txc),
      .rgmii_txd     (rgmii_txd),
      .rgmii_tx_ctl  (rgmii_tx_ctl),
      .rgmii_rxc     (rgmii_rxc),
      .rgmii_rxd     (rgmii_rxd),
      .rgmii_rx_ctl  (rgmii_rx_ctl),
      .idelay_refclk (clk_200m),
      .rst_n         (sys_rst_n)
  );

  //============================================================================
  // 3. gmii2mac — MAC 层
  //============================================================================
  gmii2mac u_gmii2mac (
      .clk        (clk_125m),
      .reset_l    (sys_rst_n),
      .Eth_RXC    (gmii_rx_clk),
      .Eth_RXDV   (gmii_rx_dv),
      .Eth_RXER   (gmii_rx_er),
      .Eth_RXD    (gmii_rxd),
      .Eth_TXD    (gmii_txd),
      .Eth_TXEN   (gmii_tx_en),
      .Eth_TXER   (gmii_tx_er),
      .mac_rx_sop (mac_rx_sop),
      .mac_rx_en  (mac_rx_en),
      .mac_rx_data(mac_rx_data),
      .mac_rx_eop (mac_rx_eop),
      .mac_rx_err (mac_rx_err),
      .mac_tx_sop (mac_tx_sop),
      .mac_tx_en  (mac_tx_en),
      .mac_tx_data(mac_tx_data),
      .mac_tx_eop (mac_tx_eop),
      .mac_tx_err (mac_tx_err),
      .rx_afifo_full_cnt (rx_afifo_full_cnt),
      .rx_afifo_empty_cnt(rx_afifo_empty_cnt),
      .rx_data_err_line  (rx_data_err_line),
      .rx_correct_pkt_cnt(rx_correct_pkt_cnt),
      .rx_crc_err_pkt_cnt(rx_crc_err_pkt_cnt),
      .tx_correct_pkt_cnt(tx_correct_pkt_cnt),
      .tx_error_pkt_cnt  (tx_error_pkt_cnt)
  );

  //============================================================================
  // 4. cpu_channel — CPU-FIFO 通道
  //============================================================================
  cpu_channel #(
      .cpu_buf_addr_width      (CPU_BUF_ADDR_WIDTH),
      .cpu_buf_data_width      (CPU_BUF_DATA_WIDTH),
      .cpu_buf_para_width      (CPU_BUF_PARA_WIDTH),
      .cpu_buf_block_mode      ("false"),
      .cpu_buf_block_addr_width(3)
  ) u_cpu_channel (
      .clk             (clk_125m),
      .reset_l         (sys_rst_n),
      .cpu_clk         (clk_50m),
      // MAC RX
      .mac_rx_sop      (mac_rx_sop),
      .mac_rx_en       (mac_rx_en),
      .mac_rx_data     (mac_rx_data),
      .mac_rx_eop      (mac_rx_eop),
      // MAC TX
      .mac_tx_sop      (mac_tx_sop),
      .mac_tx_en       (mac_tx_en),
      .mac_tx_data     (mac_tx_data),
      .mac_tx_eop      (mac_tx_eop),
      .mac_tx_err      (mac_tx_err),
      // CPU 读 (50MHz)
      .cpu_rd_empty    (cpu_rd_empty),
      .cpu_rd_rpkt_pop (cpu_rd_rpkt_pop_ind),
      .cpu_rd_rpkt_len (cpu_rd_rpkt_len),
      .cpu_rd_rpkt_para(cpu_rd_rpkt_para),
      .cpu_rd_ren      (cpu_rd_ren),
      .cpu_rd_raddr    (cpu_rd_raddr),
      .cpu_rd_rdata    (cpu_rd_rdata),
      .cpu_rd_reop_pre (cpu_rd_reop_pre),
      // CPU 写 (50MHz)
      .cpu_wr_full     (cpu_wr_full),
      .cpu_wr_wen      (cpu_wr_wen_ind),
      .cpu_wr_waddr    (cpu_wr_waddr),
      .cpu_wr_wdata    (cpu_wr_wdata),
      .cpu_wr_wpkt_push(cpu_wr_wpkt_push_ind),
      .cpu_wr_wpkt_len (cpu_wr_wpkt_len),
      .cpu_wr_wpkt_para(),
      // 调试
      .recv_pkt_drop_cnt(recv_pkt_drop_cnt),
      .mac_in_full      (mac_in_full),
      .dbg_fifo_wdata  (),
      .dbg_fifo_wen    (),
      .dbg_fifo_push   ()
  );

  //============================================================================
  // 5. lcpu_riscv_wrapper — RISC-V 子系统
  //============================================================================
  lcpu_riscv_wrapper #(
      .sim_mod           (sim_mod),
      .lcpu_type         (lcpu_type),
      .uart_baud_rate    (uart_baud_rate),
      .riscv_inst_en     (riscv_inst_en),
      .instr_databits    (instr_databits),
      .init_addr_width   (init_addr_width),
      .init_addr_depth   (init_addr_depth),
      .device_vendor     (device_vendor),
      .instr_ram_type    (instr_ram_type),
      .init_blockram_size(init_blockram_size),
      .enable_irq        (0),
      .enable_irq_qregs  (1),
      .progaddr_irq      (16)
  ) u_riscv (
      .clk            (clk_50m),
      .reset_l        (reset_l),
      .uart_rx        (cpu_uart_rx),   // 复用后: 上传模式(debug_sel=1)独享
      .uart_tx        (cpu_uart_tx),    // CPU UART TX (ILA 占用板载 uart_tx)
      .riscv_reset_l  (riscv_reset_l),
      // 指令 RAM 接口
      .pram_wr        (pram_wr),
      .pram_addr      (pram_addr),
      .pram_wdata     (pram_wdata),
      .pram_rdata     (pram_rdata),
      // 合并总线
      .req            (bus_req),
      .rhwl           (bus_rhwl),
      .wdata          (bus_wdata),
      .address        (bus_address),
      .ack            (bus_ack),
      .rdata          (bus_rdata)
  );

  //============================================================================
  // 6. lcpu_fpga_test — 寄存器 + 指令 RAM 接口
  //============================================================================
  lcpu_fpga_test u_reg (
      .clk                          (clk_50m),
      .rst_n                        (reset_l),
      // LCPU 总线
      .req                          (bus_req),
      .rhwl                         (bus_rhwl),
      .wdata                        (bus_wdata),
      .address                      (bus_address),
      .rdata                        (bus_rdata),
      .ack                          (bus_ack),
      // 指令 RAM
      .RAMIF_program_ram_Ram_RlWh   (pram_wr),
      .RAMIF_program_ram_Ram_Addr   (pram_addr),
      .RAMIF_program_ram_Ram_WrData (pram_wdata),
      .RAMIF_program_ram_Ram_RdData (pram_rdata),
      // FPGA 版本
      .fpga_build_date              (fpga_build_date),
      .fpga_build_time              (fpga_build_time),
      // LED & PLL
      .led                          (led_val),
      .pll_locked                   (pll_locked),
      .riscv_reset_l                (riscv_reset_l),
      // CPU FIFO (RX)
      .cpu_rd_empty                 (fpga_cpu_rd_empty),
      .cpu_rd_rpkt_pop              (fpga_cpu_rd_rpkt_pop),
      .cpu_rd_rpkt_pop_ind          (cpu_rd_rpkt_pop_ind),
      .cpu_rd_rpkt_len              (fpga_cpu_rd_rpkt_len),
      .cpu_rd_ren                   (fpga_cpu_rd_ren),
      .cpu_rd_raddr                 (fpga_cpu_rd_raddr),
      .cpu_rd_rdata                 (fpga_cpu_rd_rdata),
      .cpu_rd_reop_pre              (fpga_cpu_rd_reop_pre),
      // CPU FIFO (TX)
      .cpu_wr_full                  (fpga_cpu_wr_full),
      .cpu_wr_wen                   (fpga_cpu_wr_wen),
      .cpu_wr_wen_ind               (cpu_wr_wen_ind),
      .cpu_wr_waddr                 (fpga_cpu_wr_waddr),
      .cpu_wr_wdata                 (fpga_cpu_wr_wdata),
      .cpu_wr_wpkt_len              (fpga_cpu_wr_wpkt_len),
      .cpu_wr_wpkt_push             (fpga_cpu_wr_wpkt_push),
      .cpu_wr_wpkt_push_ind         (cpu_wr_wpkt_push_ind)
  );

  //============================================================================
  // 7. fpga_ila 核 #0 — 32 探针, 184bit 总线观测
  //    sample_clk = clk_50m (20ns 粒度, 时序可靠)
  //============================================================================
  soft_ila_top #(
      .CORE_EN       (1),
      .DATA_DEPTH    (2048),
      .MAX_WINDOWS   (1),
      .SAMPLE_HZ     (50_000_000),
      .RST_ACTIVE_LOW(1),
      .NUM_PROBES    (32),
      .PROBE0_WIDTH  (1),    // gmii_rx_dv
      .PROBE1_WIDTH  (8),    // gmii_rxd
      .PROBE2_WIDTH  (1),    // gmii_tx_en
      .PROBE3_WIDTH  (8),    // gmii_txd
      .PROBE4_WIDTH  (1),    // mac_rx_sop
      .PROBE5_WIDTH  (1),    // mac_rx_en
      .PROBE6_WIDTH  (8),    // mac_rx_data
      .PROBE7_WIDTH  (1),    // mac_rx_eop
      .PROBE8_WIDTH  (1),    // mac_tx_sop
      .PROBE9_WIDTH  (1),    // mac_tx_en
      .PROBE10_WIDTH (8),    // mac_tx_data
      .PROBE11_WIDTH (1),    // mac_tx_eop
      .PROBE12_WIDTH (1),    // mac_tx_err
      .PROBE13_WIDTH (1),    // bus_req
      .PROBE14_WIDTH (1),    // bus_rhwl
      .PROBE15_WIDTH (32),   // bus_address
      .PROBE16_WIDTH (32),   // bus_rdata
      .PROBE17_WIDTH (1),    // bus_ack
      .PROBE18_WIDTH (32),   // bus_wdata
      .PROBE19_WIDTH (1),    // cpu_rd_empty
      .PROBE20_WIDTH (1),    // cpu_wr_full
      .PROBE21_WIDTH (1),    // cpu_rd_rpkt_pop_ind
      .PROBE22_WIDTH (1),    // cpu_wr_wpkt_push_ind
      .PROBE23_WIDTH (1),    // cpu_wr_wen_ind
      .PROBE24_WIDTH (1),    // cpu_rd_ren
      .PROBE25_WIDTH (4),    // led_o (led_val)
      .PROBE26_WIDTH (8),    // rx_afifo_full_cnt[7:0]
      .PROBE27_WIDTH (8),    // rx_correct_pkt_cnt[7:0]
      .PROBE28_WIDTH (8),    // rx_crc_err_pkt_cnt[7:0]
      .PROBE29_WIDTH (8),    // recv_pkt_drop_cnt[7:0]
      .PROBE30_WIDTH (1),    // mac_in_full
      .PROBE31_WIDTH (1)     // gmii_rx_er
  ) u_ila_core0 (
      .sample_clk   (clk_50m),
      .rst_in       (sys_rst_n),
      .jtag_clk     (ila_jtag_clk),
      .probe0       (gmii_rx_dv),
      .probe1       (gmii_rxd),
      .probe2       (gmii_tx_en),
      .probe3       (gmii_txd),
      .probe4       (mac_rx_sop),
      .probe5       (mac_rx_en),
      .probe6       (mac_rx_data),
      .probe7       (mac_rx_eop),
      .probe8       (mac_tx_sop),
      .probe9       (mac_tx_en),
      .probe10      (mac_tx_data),
      .probe11      (mac_tx_eop),
      .probe12      (mac_tx_err),
      .probe13      (bus_req),
      .probe14      (bus_rhwl),
      .probe15      (bus_address),
      .probe16      (bus_rdata),
      .probe17      (bus_ack),
      .probe18      (bus_wdata),
      .probe19      (cpu_rd_empty),
      .probe20      (cpu_wr_full),
      .probe21      (cpu_rd_rpkt_pop_ind),
      .probe22      (cpu_wr_wpkt_push_ind),
      .probe23      (cpu_wr_wen_ind),
      .probe24      (cpu_rd_ren),
      .probe25      (led_val),
      .probe26      (rx_afifo_full_cnt[7:0]),
      .probe27      (rx_correct_pkt_cnt[7:0]),
      .probe28      (rx_crc_err_pkt_cnt[7:0]),
      .probe29      (recv_pkt_drop_cnt),
      .probe30      (mac_in_full),
      .probe31      (gmii_rx_er),
      .trigger_in   (1'b0),
      .trigger_out  (),
      .armed_out    (),
      .reg_we       (ila_we[0]),
      .reg_re       (ila_re[0]),
      .reg_addr     (ila_addr),
      .reg_wdata    (ila_wdata),
      .reg_rdata    (ila_rdata[31:0])
  );

  //============================================================================
  // 8. fpga_ila Hub — UART 传输, 板载串口 L21/M21
  //============================================================================
  ila_hub_top #(
      .TRANSPORT_EN (ILA_TRANSPORT_EN),
      .NUM_CORES    (ILA_NUM_CORES),
      .ILA_CLK_HZ   (ILA_CLK_HZ),
      .ILA_BAUD     (ILA_BAUD)
  ) u_ila_debug (
      .clk           (clk_50m),
      .rst           (~sys_rst_n),
      // UART (板载串口)
      .uart_rxd      (ila_uart_rx),    // 调试模式(debug_sel=0)独享
      .uart_txd      (ila_uart_tx),    // 调试模式(debug_sel=0)独享 (顶层 uart_tx 由 mux 驱动)
      // ETH — 不用
      .gmii_rx_clk   (1'b0),
      .gmii_rxd      (8'b0),
      .gmii_rx_dv    (1'b0),
      .gmii_txd      (),
      .gmii_tx_en    (),
      // 核总线
      .core_reg_we   (ila_we),
      .core_reg_re   (ila_re),
      .core_reg_addr (ila_addr),
      .core_reg_wdata(ila_wdata),
      .core_reg_rdata(ila_rdata),
      // JTAG — 不需要 (无 BSCANE2)
      .core_jtag_clk (ila_jtag_clk),
      .core_jtag_rst ()
  );

  //============================================================================
  // MDIO — 暂不连接 (后续扩展)
  //============================================================================
  assign Eth0_MDC  = 1'b0;
  assign Eth0_MDIO = 1'bz;

endmodule
