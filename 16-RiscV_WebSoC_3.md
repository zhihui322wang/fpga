# RiscV_WebSoC_3 — RISC-V Web 服务器 (v3, 当前主力)

**位置:** `Prj/RiscV_WebSoC_3/`

**复杂度:** 最高

**RTL 文件数:** 42 个 + fpga_ila IP

**C 固件:** 912 行 (完整 TCP/IP 协议栈)

**目标:** Xilinx XC7A35T-FGG484-2

## 功能

目前最完整的 RISC-V Web 服务器 SoC。在 v2 基础上大幅升级：集成硬件逻辑分析仪 (ILA)、TCP/IP 协议栈增强、指令 RAM 翻倍。

## 相对 v2 的升级

### 1. 集成 fpga_ila 硬件逻辑分析仪
- 96 路信号实时抓取 (gmii_rx, mac_rx, bus 等)
- 4096 采样深度 @ 125MHz
- UART 上位机控制 (武装/触发/回读)
- 仿真中直接 BRAM Dump → VCD 波形转换
- `signals.json` 信号配置 + `fpga_ila_files.f` 文件列表

### 2. TCP/IP 协议栈增强
- **ARP:** 地址解析 (请求+应答)
- **IP:** IPv4 包处理
- **ICMP:** Ping 回复
- **TCP:** 三次握手 + 状态机 (CLOSED/LISTEN/SYN_RCVD/ESTABLISHED) + 超时重传
- 预留 HTTP 处理接口

### 3. 构建流程升级
- **Updatemem 流程:** 固件直接嵌入比特流 (`RiscV_WebSoC_fw.bit`)
- `.mmi` 文件 (BRAM 内存映射信息)
- 指令 RAM: 2048字(8KB) → 4096字(16KB)

### 4. 开发文档
- 开发日报 (HTML)
- TCP 协议学习笔记
- C 代码编写技巧

## 架构

```
webserver_cpu_top
├── PLL (50/125/200/125_90 MHz)
├── RGMII Bridge → GMII2MAC → CPU Channel
├── RISC-V Subsystem (PicoRV32 + 16KB IRAM)
├── LCPU Debug (JTAG/UART)
├── Peripherals (LED, MDIO)
└── fpga_ila (13路信号, 96bit宽, 4096深度) ← 新增
    ├── soft_ila_top_fcapz (捕获引擎)
    ├── ila_hub_top (多传输仲裁)
    └── UART backend (上位机控制)
```

## 仿真

- iverilog Makefile + 自动编译流程
- LCPU BFM + 前导码/CRC 仿真模型
- ILA BRAM dump → VCD 自动转换
- `tb.v` (完整) / `tb_fast.v` (快速)

## 用途

当前主力开发平台 / TCP/IP 硬件软件协同调试 / ILA 集成参考。
