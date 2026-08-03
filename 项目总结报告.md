# 基于 PicoRV32 RISC-V 软核的 FPGA 全栈网络协议 SoC 设计与实现

> **平台**: ACX750 开发板 (XC7A35T-FGG484-2) + PicoRV32 RV32IC 软核 + RTL8211F-CG 千兆 PHY
> **开发方式**: 纯 Verilog/SystemVerilog RTL 设计 + C 固件裸机编程 (picolibc)
> **验证方式**: Iverilog 仿真 + Vivado ILA 片上逻辑分析 + Wireshark 协议抓包验证
> **工具链**: Vivado 2024.1 + riscv64-unknown-elf-gcc + picolibc
> **日期**: 2026 年
> **架构**: 三步渐进式 (ARP/ICMP → TCP → HTTP)

---

## 目录

1. [总体概述](#1-总体概述)
2. [硬件架构设计](#2-硬件架构设计)
3. [时钟与跨时钟域方案](#3-时钟与跨时钟域方案)
4. [固件总览：硬件抽象层 (lcpu_general.h)](#4-固件总览硬件抽象层)
5. [固件设计：main.c — 主循环与帧分发](#5-固件设计mainc--主循环与帧分发)
6. [固件设计：eth.c — 以太网帧收发引擎](#6-固件设计ethc--以太网帧收发引擎)
7. [固件设计：arp.c — ARP 协议与硬件缓存](#7-固件设计arpc--arp-协议与硬件缓存)
8. [固件设计：ip.c — IPv4 校验与协议分派](#8-固件设计ipc--ipv4-校验与协议分派)
9. [固件设计：icmp.c — ICMP Echo Reply 零拷贝实现](#9-固件设计icmpc--icmp-echo-reply-零拷贝实现)
10. [资源占用与时序收敛分析](#10-资源占用与时序收敛分析)
11. [调试方法与验证策略](#11-调试方法与验证策略)
12. [遇到的问题及解决措施](#12-遇到的问题及解决措施)
13. [总体收获与总结](#13-总体收获与总结)

---

## 1. 总体概述

### 1.1 项目背景

在嵌入式网络应用场景中，传统方案依赖 MCU + 外部以太网 MAC/PHY 芯片（如 STM32 + W5500 或 STM32 + LAN8720），数据处理路径长、协议栈受限于厂商 SDK、灵活性低。**FPGA 软核 SoC** 方案将处理器与 MAC 控制器集成在同一片芯片内，可以根据需求精确定制每层协议的处理逻辑，在数据通路上实现硬件加速。

本项目在 Xilinx XC7A35T FPGA 上，以 **PicoRV32** 开源 RISC-V 32 位软核为核心，搭配自研的 **RGMII → GMII → MAC → 包 FIFO** 硬件数据通路，从零构建了一套**全栈硬件网络协议 SoC 系统**。固件采用裸机 C 编程（picolibc），以逐层分派的方式处理以太网帧，目前已实现 ARP 协议、IP 协议和 ICMP Echo Reply（Ping 回复），验证了从物理层到网络层的完整闭环。

### 1.2 硬件平台

| 项目 | 说明 |
|------|------|
| FPGA | XC7A35T-FGG484-2 (Artix-7, 20,800 LUT, 41,600 FF, 50 Block RAM, 90 DSP) |
| 开发板 | ACX750 — 基于 Artix-7 的 PCIE 开发板 |
| PHY 芯片 | RTL8211F-CG 千兆以太网 PHY (RGMII 接口, 支持 10/100/1000Mbps) |
| 外部晶振 | 50MHz 板载晶振 (引脚 W19) |
| RISC-V 核心 | PicoRV32 (开源, 配置为 RV32IC, 无硬件乘除单元) |
| 程序存储器 | 32KB Block RAM (4096 × 32-bit words), 起始地址 0x00000000 |
| 调试接口 | UART (115200bps) + Vivado ILA 片上逻辑分析仪 |

### 1.3 系统架构

```
┌──────────────────────────────────────────────────────────┐
│                       XC7A35T FPGA                       │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │            PicoRV32 RV32IC @ 50MHz                  │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  │          C 固件 (裸机, picolibc)              │  │  │
│  │  │                                              │  │  │
│  │  │  main.c         设计主循环 + LED 状态机      │  │  │
│  │  │    ├─ eth.c     以太网帧 RX/TX 引擎          │  │  │
│  │  │    ├─ arp.c     ARP Reply + MAC 缓存         │  │  │
│  │  │    ├─ ip.c      IPv4 校验和 + 协议分派       │  │  │
│  │  │    └─ icmp.c    ICMP Echo Reply (Ping)       │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  │                       ↕ 32-bit LCPU 总线             │  │
│  ├────────────────────────────────────────────────────┤  │
│  │    寄存器文件 (riscv_reg + lcpu_fpga_test)          │  │
│  │    RX/TX 包 FIFO 接口 · LED · 定时器 · UART        │  │
│  ├────────────────────────────────────────────────────┤  │
│  │             cpu_channel (包缓冲 + CDC)               │  │
│  │           125MHz MAC 域 ←→ 50MHz CPU 域             │  │
│  ├────────────────────────────────────────────────────┤  │
│  │               gmii2mac (MAC 层)                      │  │
│  │    mac_rx: 前导码/SFD 剥离 + CRC32 校验 + FCS 去除   │  │
│  │    mac_tx: CRC32 计算插入 + 前导码/SFD/IFG 生成       │  │
│  ├────────────────────────────────────────────────────┤  │
│  │        rgmii_gmii_bridge (RGMII ↔ GMII 桥)          │  │
│  │    IDELAYE2 延迟校准 · IDDR 双沿采样 · ODDR 双沿输出  │  │
│  └────────────────────────────────────────────────────┘  │
│                          ↕ RGMII (4-bit DDR)              │
│                ┌──────────────────────┐                   │
│                │  RTL8211F-CG PHY     │                   │
│                └──────────┬───────────┘                   │
│                           ↕ RJ45 + 网线                    │
│                         PC 主机                           │
└──────────────────────────────────────────────────────────┘
```

### 1.4 数据流概览

**收包路径**（7 级流水，硬件全自动）:

```
PHY (RTL8211F)
  → RGMII RX [4-bit DDR, 125MHz RXC]
  → IDDR 双沿→单沿 (gmii_to_rgmii)
  → IDELAYE2 延迟校准 (per-bit, 200MHz 参考时钟)
  → GMII 8-bit [125MHz]
  → mac_rx: 前导码(7B)+SFD(1B) 检测 → 帧数据提取 + CRC32 校验
  → cpu_channel: package_fifo (CDC, 125M → 50M)
  → RISC-V 通过寄存器接口逐字节读取 (rd_raddr / rd_ren / rd_rdata)
```

**发包路径**（对称反向）:

```
RISC-V 逐字节写入寄存器 (wr_waddr / wr_wdata / wr_wen)
  → cpu_channel: package_fifo (CDC, 50M → 125M)
  → mac_tx: CRC32 计算 + 前导码/SFD 插入 + IFG(12B)
  → GMII 8-bit [125MHz]
  → ODDR 单沿→双沿 (gmii_to_rgmii)
  → RGMII TX [4-bit DDR, 125MHz TXC, 90° 移相]
  → PHY (RTL8211F)
```

### 1.5 软件栈分层架构

| 层次 | 文件 | 代码量 | 核心职责 |
|------|------|--------|----------|
| 应用层 | `main.c` | ~140 行 | 上电启动 + 主循环帧分发 + LED 状态机 |
| 以太网层 | `eth.c` | ~55 行 | eth_rx_frame / eth_tx_frame，FIFO 读写封装 |
| ARP 层 | `arp.c` | ~90 行 | ARP Request 解析、Reply 原地构建、单条 MAC 缓存 |
| IP 层 | `ip.c` | ~85 行 | IPv4 头校验和验证、协议号分派、src/dst IP 交换 |
| ICMP 层 | `icmp.c` | ~70 行 | Echo Request 解析、Reply 零拷贝构建、ICMP 校验和重算 |
| 硬件抽象层 | `lcpu_general.h` | ~155 行 | 寄存器地址宏、FIFO 操作宏、rdcycle 定时器、协议常量 |

**合计约 595 行 C 代码**，无动态内存分配，所有缓冲区静态分配，栈空间安全可控。

**核心设计原则**:
- **零拷贝帧处理**: ICMP/ARP Reply 直接在接收缓冲区上原地修改 MAC + IP + 协议头后发送，无需额外的发送缓冲区
- **层层分派**: 每层只解析本层协议头，通过 EtherType → Protocol 字段逐层分发
- **防御式校验**: 每层都校验最小帧长、协议类型、校验和，任何不匹配直接丢弃

### 1.6 开发工具链

| 环节 | 工具 | 说明 |
|------|------|------|
| RTL 设计 | SystemVerilog/Verilog | 40 个模块文件 |
| RTL 仿真 | Iverilog (开源) | 模块级 + 系统级仿真 |
| 综合/布局布线 | Vivado 2024.1 | GUI + Tcl 脚本自动化 |
| 固件编译 | riscv64-unknown-elf-gcc | `-march=rv32ic -mabi=ilp32 -O2` |
| C 标准库 | picolibc | 轻量级嵌入式 C 库 (`-lc -lgcc`) |
| 固件烧录 | JTAG (LCPU 总线) | Python 脚本 + Tcl 指令 RAM 初始化 |
| 片上调试 | Vivado ILA | 抓取 RGMII RX/TX、GMII、MAC 内部信号 |
| 协议验证 | Wireshark | PC 端抓包，验证 ARP/ICMP 帧格式 |
| 版本管理 | Git | — |

### 1.7 开发路线

项目采用**三步渐进式**架构，由物理层逐步向上构建协议栈：

```
第一步: ARP + ICMP (Ping 通网络)          ← 当前阶段 ✓
  └─ 验证全链路: PHY → RGMII → GMII → MAC → FIFO → RISC-V → 发包
第二步: TCP 三次握手 (TCP 连接建立)
  └─ TCP 状态机 (11 状态) + 连接表管理 + SYN 重传定时器
第三步: HTTP 请求响应 (Web 服务器)
  └─ HTTP GET/POST 解析 + HTML 网页服务 + LED 远程控制
```

---

## 2. 硬件架构设计

### 2.1 顶层模块 (webserver_cpu_top)

**源文件**: `rtl/webserver_cpu_top.v`

顶层模块集成六大子系统：

| 子系统 | 实例名 | 核心模块 |
|--------|--------|----------|
| 时钟管理 | `u_pll` | `mmcm_50_125` — MMCME2_BASE 原语 |
| RGMII 桥接 | `u_rgmii_gmii_bridge` | `rgmii_gmii_bridge` + `rgmii_to_gmii` + `gmii_to_rgmii` |
| MAC 层 | `u_gmii2mac` | `gmii2mac` (内含 `mac_rx` + `mac_tx` + `eth_presemble`) |
| 包缓冲 CDC | `u_cpu_channel` | `cpu_channel` (内含 `package_fifo_v2` × 2) |
| RISC-V 系统 | `u_riscv` | `lcpu_riscv_wrapper` → `riscv32_top` → `picorv32` |
| 寄存器文件 | `u_lcpu_fpga_test` | `lcpu_fpga_test` — 总线地址解码 + 外设寄存器 |

### 2.2 PicoRV32 核心配置

**源文件**: `rtl/riscv32_localbus.v:29-50`

PicoRV32 是 Clifford Wolf 开发的开源 RISC-V 软核，本项目的关键配置：

```
参数                      值        含义
──────────────────────────────────────────────
ENABLE_COUNTERS            1        RDCYCLE/RDTIME 指令 (用于定时器)
ENABLE_COUNTERS64          1        64 位计数器 (RDCYCLEH)
ENABLE_REGS_16_31          1        完整 32 寄存器 (x0-x31)
ENABLE_REGS_DUALPORT       1        双端口寄存器堆 (减少资源)
COMPRESSED_ISA             1        支持 RV32C 压缩指令
ENABLE_MUL                 0        无硬件乘法器 (用软件库)
ENABLE_DIV                 0        无硬件除法器
TWO_STAGE_SHIFT            1        两级流水移位 (减少关键路径)
BARREL_SHIFTER             0        不用桶形移位器 (节省 LUT)
ENABLE_IRQ                 0        无外部中断 (只用定时器中断)
PROGADDR_RESET             0x00000000  上电复位入口
STACKADDR                  0x00008000  栈顶 = 32KB 程序 RAM 顶部
```

**指令集**: RV32IC (32 位基础整数指令 + 16 位压缩指令)。不包含 M 扩展（乘除法），以节省 LUT 资源。乘法/除法由 picolibc 提供的软件库函数实现。

**性能**: 50MHz 主频下，PicoRV32 的 CPI (每指令周期数) 典型值为 3-4 cycles/指令，等效约 12.5-16.7 MIPS。

### 2.3 RGMII 接口

**源文件**: `rtl/rgmii_gmii_bridge.v` + `rtl/gmii_to_rgmii.v` + `rtl/rgmii_to_gmii.v`

RGMII (Reduced Gigabit Media Independent Interface) 将 GMII 的 25 条信号线缩减为 12 条，通过 DDR (双沿) 方式在 125MHz 时钟下传输千兆数据：

```
RGMII 信号定义 (IEEE 802.3z):
┌──────────┬──────┬──────────────────────────────────┐
│ 信号      │ 位宽  │ 说明                              │
├──────────┼──────┼──────────────────────────────────┤
│ TXC       │ 1    │ 125MHz 发送时钟 (FPGA→PHY)        │
│ TXD[3:0]  │ 4    │ 双沿: 上升沿=bits[3:0], 下降沿=bits[7:4] │
│ TX_CTL    │ 1    │ 上升沿=TXEN, 下降沿=TXERR异或     │
│ RXC       │ 1    │ 125MHz 接收时钟 (PHY→FPGA)        │
│ RXD[3:0]  │ 4    │ 双沿: 上升沿=bits[3:0], 下降沿=bits[7:4] │
│ RX_CTL    │ 1    │ 上升沿=RXDV, 下降沿=RXERR异或      │
│ MDC/MDIO  │ 2    │ PHY 管理接口 (配置寄存器)           │
└──────────┴──────┴──────────────────────────────────┘

关键时序要求 (RGMII v2.0):
  TXC 相对 TXD/TX_CTL 需要 90° 移相 (时钟边沿对齐数据中心)
  RXD 需要在 FPGA 内部用 IDELAY 补偿 PCB 走线延时
```

**IDELAYE2 校准**：RGMII RX 通道 5 路信号 (RXC + RXD[3:0] + RX_CTL) 各经过一个 IDELAYE2 原语，由 IDELAYCTRL (200MHz 参考时钟) 提供精确的 tap 延迟校准（每 tap ≈ 78ps），补偿 PCB 布线不等长造成的时序偏差。

---

## 3. 时钟与跨时钟域方案

### 3.1 MMCM 时钟生成

**源文件**: `rtl/mmcm_50_125.v`

```
板载晶振 50MHz (引脚 W19)
    │
    ▼
MMCME2_BASE 原语
    │
    ├─→ CLKOUT0 (D=8)   → BUFG → clk_125m      MAC 域
    ├─→ CLKOUT1 (D=5)   → BUFG → clk_200m      IDELAYCTRL 参考
    ├─→ CLKOUT2 (D=8, 90°移相) → BUFG → clk_125m_tx  RGMII TXC
    └─→ CLKOUT3 (D=20)  → BUFG → clk_50m_cpu   CPU 域

VCO 频率计算:
  f_VCO = 50MHz × CLKFBOUT_MULT_F / DIVCLK_DIVIDE
        = 50MHz × 20.0 / 1
        = 1000MHz

输出频率验证:
  clk_125m     = 1000 / 8  = 125MHz ✓
  clk_200m     = 1000 / 5  = 200MHz ✓
  clk_125m_tx  = 1000 / 8  = 125MHz (90°移相) ✓
  clk_50m_cpu  = 1000 / 20 = 50MHz  ✓
```

### 3.2 时钟域划分

| 时钟域 | 频率 | 源 | 驱动模块 |
|--------|------|-----|----------|
| CPU 域 (clk_50m) | 50MHz | MMCM CLKOUT3 | PicoRV32, UART, LED, 寄存器文件 |
| MAC 域 (clk_125m) | 125MHz | MMCM CLKOUT0 | gmii2mac, cpu_channel (MAC 侧) |
| RGMII TXC | 125MHz (90°移相) | MMCM CLKOUT2 | ODDR → PHY TXC |
| RGMII RXC | 125MHz (来自 PHY) | PHY | IDDR → IDELAYE2 |
| IDELAYCTRL | 200MHz | MMCM CLKOUT1 | IDELAYCTRL 原语 (tap 校准) |

### 3.3 跨时钟域 (CDC) 设计

**RX CDC 链** (PHY → CPU):

```
RGMII RXC (125M, PHY 时钟)
  → IDELAYE2 + IDDR (RGMII→GMII, RXC 域)
  → gmii2mac / mac_rx (RXC 域, 125M)
  → dual_clock_fifo (异步 FIFO, RXC→clk_125m)
  → cpu_channel / package_fifo (异步 FIFO, clk_125m→clk_50m)
  → 寄存器接口 (clk_50m, CPU 域)
  → RISC-V C 代码读取
```

**TX CDC 链** (CPU → PHY):

```
RISC-V C 代码写入
  → 寄存器接口 (clk_50m, CPU 域)
  → cpu_channel / package_fifo (异步 FIFO, clk_50m→clk_125m)
  → mac_tx (clk_125m 域)
  → ODDR (GMII→RGMII, 125m_tx 域)
  → RGMII TXC 输出
```

**CDC 关键技术**:

| 技术 | 应用位置 | 说明 |
|------|----------|------|
| 异步 FIFO (dual_clock_fifo) | RXC→clk_125m MAC 内部 | 基于 Block RAM 的真双口 RAM + 格雷码指针 |
| 异步 FIFO (package_fifo_v2) | clk_125m→clk_50m cpu_channel | 整包缓冲，支持 back-to-back 接收 |
| set_false_path (XDC) | RXC ↔ 内部时钟 | 声明 RGMII RXC 为异步时钟组 |
| IDELAYE2 tap 校准 | RGMII RX 通道 | 补偿 PCB 走线延时，确保 IDDR 采样窗口 |

### 3.4 时序约束

**源文件**: `build_xilinx/timing.xdc`

```tcl
# 输入时钟 50MHz
create_clock -period 20.000 -name clk_50m_in [get_ports clk_50m_in]

# RGMII RXC (来自 PHY, 125MHz, 异步)
create_clock -period 8.000 -name rgmii_rxc [get_ports rgmii_rxc]

# RXC 与内部时钟异步隔离
set_false_path -from [get_clocks rgmii_rxc] -to [all_clocks]
set_false_path -to   [get_clocks rgmii_rxc] -from [all_clocks]

# MMCM 同源相移时钟组 (IDDR/ODDR 内部保证时序)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated clk_125m_unbuf] \
    -group [get_clocks -include_generated clk_125m_tx_unbuf]
```

---

## 4. 固件总览：硬件抽象层

### 4.1 寄存器映射

**源文件**: `c/inc/lcpu_general.h`

固件通过 LCPU 总线（32-bit, 基址 0x80000000）访问所有硬件外设。`HW_REG8(offset)` 宏将字节偏移自动转换为 32 位对齐的寄存器地址：

```c
#define HW_BASE  0x80000000u
#define HW_REG8(offset)  (*(volatile uint32_t *)(HW_BASE + (uint32_t)(offset) * 4))
```

**寄存器地址分配**:

| 偏移 | 寄存器 | 访问 | 功能 |
|------|--------|------|------|
| 0x0010 | REG_LED | RW | LED 控制 (低 4 位) |
| 0x6000 | REG_RX_EMPTY | RO | RX FIFO 空标志 (1=空) |
| 0x6001 | REG_RX_PKT_POP | WC | 弹出当前包 (写 1 生效) |
| 0x6002 | REG_RX_PKT_LEN | RO | 当前包长度 (字节数) |
| 0x6004 | REG_RX_REN | RW | 读使能 |
| 0x6005 | REG_RX_RADDR | RW | 读地址 (字节偏移) |
| 0x6006 | REG_RX_RDATA | RO | 读数据 (低 8 位有效) |
| 0x6100 | REG_TX_FULL | RO | TX FIFO 满标志 (1=满) |
| 0x6101 | REG_TX_WEN | WC | 写使能 (写 1 生效) |
| 0x6102 | REG_TX_WADDR | RW | 写地址 (字节偏移) |
| 0x6103 | REG_TX_WDATA | RW | 写数据 (低 8 位有效) |
| 0x6104 | REG_TX_PKT_LEN | RW | 发送包长度 |
| 0x6106 | REG_TX_PKT_PUSH | WC | 推包发送 (写 1 生效) |

### 4.2 FIFO 高层操作宏

```c
// 收包操作序列
#define LCPU_RD_EMPTY()         (HW_REG8(REG_RX_EMPTY) != 0)
#define LCPU_RD_START_PACKET()  do { HW_REG8(REG_RX_PKT_POP) = 1; HW_REG8(REG_RX_REN) = 1; } while(0)
#define LCPU_RD_STOP()          do { HW_REG8(REG_RX_REN) = 0; } while(0)
#define LCPU_RD_PKT_LEN()       ((uint16_t)(reg32_read(REG_RX_PKT_LEN) & 0xFFFFu))
#define LCPU_RD_DATA8()         ((uint8_t)(reg32_read(REG_RX_RDATA) & 0xFFu))
#define LCPU_RD_SET_ADDR(addr)  rd_set_addr(addr)

// 发包关键步骤: 逐字节写 → 设长度 → 推送
#define LCPU_WR_FULL()          ((HW_REG8(REG_TX_FULL) & 0x01) != 0)
#define LCPU_WR_PULSE_WEN()     do { HW_REG8(REG_TX_WEN) = 1; } while(0)
```

### 4.3 定时器接口

```c
static inline uint32_t lcpu_local_time_l(void) {
    uint32_t t;
    __asm__ volatile ("rdcycle %0" : "=r"(t));
    return t;
}
```

`rdcycle` 读取 PicoRV32 的 32 位 cycle 计数器，50MHz 下每个 tick = 20ns，溢出周期约 85.9 秒。固件基于此接口实现了非阻塞的 LED 流水灯状态机和网络活动快速闪烁。

### 4.4 网络协议常量

```c
// 本机 MAC: 02:00:00:12:34:56
#define LOCAL_MAC_BYTE0 0x02
// ... (6 字节)

// 本机 IP: 169.254.1.1 (链路本地地址, 无需 DHCP)
#define LOCAL_IP_ADDR   0xA9FE0101u

// 以太网类型
#define ETH_TYPE_IP     0x0800
#define ETH_TYPE_ARP    0x0806

// IPv4 协议号
#define IP_PROTO_ICMP   0x01

// ARP 操作码
#define ARP_REQUEST     0x0001
#define ARP_REPLY       0x0002

// ICMP 类型 (Ping)
#define ICMP_ECHO_REQ   0x08
#define ICMP_ECHO_REPLY 0x00
```

**MAC 地址说明**: 使用私有 MAC (Locally Administered Address)，bit 1 of byte 0 = 1 标识为非全球唯一地址，避免与网卡 MAC 冲突。

**IP 地址说明**: 169.254.0.0/16 是 RFC 3927 定义的 IPv4 链路本地地址 (Link-Local)，不需要 DHCP 服务器，PC 和 FPGA 在同一个二层广播域内即可通信。

### 4.5 协议头偏移宏

协议解析代码中所有帧内偏移量均通过宏定义，避免魔术数字：

```c
// 以太网头 (14 字节)
#define OFF_ETH_DST_MAC  0
#define OFF_ETH_SRC_MAC  6
#define OFF_ETH_TYPE    12

// IP 头 (以太网头 + 20 字节)
#define OFF_IP_VER_IHL   (14 + 0)
#define OFF_IP_CHECKSUM  (14 + 10)
#define OFF_IP_SRC_IP    (14 + 12)
#define OFF_IP_DST_IP    (14 + 16)
#define OFF_IP_PROTO     (14 + 9)

// ICMP 头 (IP 头 + 8 字节)
#define OFF_ICMP_TYPE     (34 + 0)
#define OFF_ICMP_CHECKSUM (34 + 2)

// ARP 体 (以太网头 + 28 字节)
#define OFF_ARP_OPCODE     20
#define OFF_ARP_SENDER_MAC 22
#define OFF_ARP_SENDER_IP  28
#define OFF_ARP_TARGET_IP  38
```

---

## 5. 固件设计：main.c — 主循环与帧分发

### 5.1 实验代码

**源文件**: `c/main.c` (约 140 行)

### 5.2 工作原理

#### 入口: reset_entry

RISC-V 上电后 PC=0x00000000，`reset_entry` 作为裸机入口。

PicoRV32 上电后所有寄存器为 0（`REGS_INIT_ZERO=1`），`sp` 也为 0。由于使用 `-nostdlib` 绕过了 picolibc 的 CRT，必须手动完成三项启动工作：

```c
__attribute__((naked, used, section(".text.bootloader")))
void reset_entry() {
    // sp=0 上电默认, 函数调用前必须设栈, 否则写 0xFFFFFFFC 跑飞
    asm volatile(
        "la sp, _stack_top\n"      // sp ← 0x8000 (32KB RAM 顶部)
        "la t0, __bss_start\n"     // .bss 清零循环
        "la t1, __bss_end\n"
        "1:\n"
        "bgeu t0, t1, 2f\n"
        "sw zero, 0(t0)\n"
        "addi t0, t0, 4\n"
        "j 1b\n"
        "2:\n"
        "j main\n"
    );
}
```

`linker.ld` 中定义了三个关键符号：`_stack_top = 0x8000`（栈顶）、`__bss_start` / `__bss_end`（.bss 边界）。`section(".text.bootloader")` + `KEEP` 确保该函数占据地址 0x00000000。

#### 主循环架构

```c
int main(void) {
    arp_init();

    // 上电自检
    LCPU_SET_LED(0x0F); delay_us(100000);
    LCPU_SET_LED(0x00); delay_us(100000);

    last_flow_ticks = lcpu_local_time_l();

    for (;;) {
        led_flow_update();

        if (eth_rx_frame(rx_buffer, &len) != 0)
            continue;
        if (len > ETH_MAX_FRAME_LEN)
            continue;

        uint16_t eth_type = (rx_buffer[OFF_ETH_TYPE] << 8)
                          |  rx_buffer[OFF_ETH_TYPE + 1];

        if (eth_type == ETH_TYPE_ARP) {
            if (arp_process(rx_buffer, len))
                trigger_network_blink();
        } else if (eth_type == ETH_TYPE_IP) {
            if (ip_process(rx_buffer, len))
                trigger_network_blink();
        }
    }
}
```

**设计要点**:

1. **单缓冲区设计**: `rx_buffer` 是 1518 字节的静态数组（`static uint8_t rx_buffer[ETH_MAX_FRAME_LEN]`），不 malloc，不动态分配。ARP 和 ICMP Reply 在原地修改后直接发送，无需额外的发送缓冲区。

2. **非阻塞 LED 状态机**: 基于 `rdcycle` 硬件计数器实现，不占用中断资源：

```
LED 模式优先级:
  1. 网络活动闪烁 (高优先): 收到有效包 → 快闪 2 次 (50ms/拍) → 恢复流水灯
  2. 常规流水灯 (低优先): 4 路 LED 循环点亮 (125ms/拍)

状态机 5 相:
  PHASE 0: 灭  →  PHASE 1: 亮  →  PHASE 2: 灭  →  PHASE 3: 亮  →  PHASE 4: 灭(恢复)
```

3. **仿真加速**: `#define SIM_FAST` 编译宏控制 `delay_us()` 在仿真时跳过 100ms 上电延时，避免 iverilog 仿真的不必要等待。

### 5.3 可能出现的现象

- **正常现象**: LED 流水灯正常循环；PC 执行 ping 169.254.1.1 时 LED 出现快速闪烁
- **异常现象 1**: LED 全灭或不亮 — 上电自检阶段卡住，检查 MMCM 锁定
- **异常现象 2**: LED 只流水灯不闪烁 — 网络包未到达 RISC-V 层，检查 RGMII/MAC/CDC 链路
- **异常现象 3**: Ping 超时但 LED 闪烁 — ARP/ICMP 处理逻辑有误，检查校验和

### 5.4 学习内容与总结

**核心收获**:
1. 掌握了 RISC-V 裸机启动的完整流程：设栈指针 → 清零 .bss → 跳转 main，理解 linker.ld 的内存布局
2. 理解了 PicoRV32 上电 `sp=0` 的原因及手动初始化栈的必要性
3. 学会了基于 rdcycle 的非阻塞状态机设计模式（无需中断）
4. 建立了"轮询 + 分派"的主循环架构（类似于事件驱动模型）
5. 掌握了单缓冲零拷贝的帧处理思想

**总结**: main.c 是整个固件的骨架。它没有使用任何 RTOS，完全依靠 poll-loop 模型驱动协议栈。LED 状态机看似简单，但它是调试网络通信是否正常的第一手信息来源——收到包时 LED 快闪，没收到时正常流水。

---

## 6. 固件设计：eth.c — 以太网帧收发引擎

### 6.1 实验代码

**源文件**: `c/eth.c` (约 55 行)

### 6.2 工作原理

#### eth_rx_frame — 从硬件 FIFO 读取一整帧

```c
int eth_rx_frame(uint8_t *buf, uint16_t *len) {
    if (LCPU_RD_EMPTY()) return -1;        // 无包

    LCPU_RD_START_PACKET();                // POP + REN
    *len = LCPU_RD_PKT_LEN();              // 读取帧长

    if (*len > ETH_MAX_FRAME_LEN) {        // 超长保护
        *len = 0; LCPU_RD_STOP();
        HW_REG8(REG_RX_PKT_POP) = 1;      // 丢弃畸形包
        return -2;
    }

    for (uint16_t i = 0; i < *len; i++) {  // 逐字节读取
        LCPU_RD_SET_ADDR(i);
        buf[i] = LCPU_RD_DATA8();
    }

    LCPU_RD_STOP();
    HW_REG8(REG_RX_PKT_POP) = 1;          // 弹出当前包
    return 0;
}
```

**寄存器操作时序**（与设计文档中时序图一致）:

```
rd_empty:  ‾‾‾\_____________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾           有包!
rd_pop:    _____/‾‾\________________________
rd_len:    -------<N>------------------------
rd_raddr:  ---<0 ><1 ><2 ><3 >...<N-1>-------
rd_ren:    ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\____
rd_rdata:  ---<D0><D1><D2><D3>...<DN-1>------
```

关键点：`rd_empty` 是异步 FIFO 的空标志，`LCPU_RD_DATA8()` 每次读取低 8 位（硬件寄存器为 32 位）。

#### eth_tx_frame — 将内存帧写入 TX FIFO 并推送

```c
void eth_tx_frame(const uint8_t *buf, uint16_t len) {
    if (len == 0) return;                  // 空包保护

    uint32_t timeout = 1000000;            // 超时保护
    while (LCPU_WR_FULL() && timeout--);   // 等待 FIFO 非满
    if (timeout == 0) return;              // 超时放弃

    for (uint16_t i = 0; i < len; i++) {   // 逐字节写入
        timeout = 1000000;
        while (LCPU_WR_FULL() && timeout--);
        if (timeout == 0) return;

        reg32_write(REG_TX_WADDR, (uint32_t)i);
        reg32_write(REG_TX_WDATA, (uint32_t)buf[i]);
        LCPU_WR_PULSE_WEN();               // 写使能脉冲
    }

    reg32_write(REG_TX_PKT_LEN, (uint32_t)len);
    HW_REG8(REG_TX_PKT_PUSH) = 1;          // 推包发送
}
```

**发包时序**（与设计文档一致）:

```
wr_full:   \_____________________________/
wr_waddr:  ---<0 ><1 ><2 >...<N-1>--------
wr_wdata:  ---<D0><D1><D2>...<DN-1>-------
wr_wen:    __/‾\_/‾\_/‾\_..._/‾\_________
wr_pkt_len:------------------<N>-----------
wr_push:   ____________________/‾‾\_______
```

**超时保护机制**: 每次写操作前检查 `wr_full`，最多等待 1000000 次循环后放弃。防止硬件异常（如 FIFO 卡住）导致固件死等。

### 6.3 可能出现的现象

- **正常现象**: 发包后 PC 端 Wireshark 可见 ARP Reply / ICMP Reply
- **异常现象 1**: `eth_rx_frame` 永远返回 -1 — RGMII/MAC/CDC 上游链路未调通
- **异常现象 2**: 帧长度异常（len=0 或 len>1518）— MAC 层前导码检测失败或 CRC 校验异常
- **异常现象 3**: 发出去的包 PC 收不到但 TX FIFO push 成功 — PHY 寄存器配置问题（速度/双工协商）

### 6.4 学习内容与总结

**核心收获**:
1. 掌握了硬件 FIFO 的逐字节访问模式：设地址 → 读数据 / 写数据 → 脉冲使能
2. 理解了 `rd_pop` 与 `rd_empty` 的时序关系：pop 只是弹出操作，空标志由硬件异步更新
3. 学会了在固件层加入超时保护，防止硬件 bug 导致死循环
4. 理解了最小以太网帧 (60B 不含 FCS) 和 jumbo frame 的区别

**总结**: eth.c 是软硬件接口的最底层。逐字节访问虽然比 DMA 慢，但在 PicoRV32 这种资源受限的软核上是最可行的方案。

---

## 7. 固件设计：arp.c — ARP 协议与硬件缓存

### 7.1 实验代码

**源文件**: `c/arp.c` (约 90 行)

### 7.2 工作原理

#### ARP 协议帧格式

```
以太网帧中的 ARP 报文 (总长 = 14 + 28 = 42 字节):

┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ DstMAC       │ SrcMAC       │EtherType     │ HW Type     │
│ 6 字节        │ 6 字节        │ 0x0806       │ 1(Ethernet) │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ProtoType     │HWLen│ProtoLen│ Opcode       │SenderMAC    │
│ 0x0800       │ 6   │ 4      │ 1=Req/2=Rep  │ 6 字节       │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ SenderIP     │TargetMAC     │ TargetIP                     │
│ 4 字节        │ 6 字节        │ 4 字节                       │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

#### arp_process — 核心处理逻辑

```
arp_process(frame, len) 处理流程:

1. 最小帧长校验 (len < 42 → 丢弃)

2. ARP 字段逐项校验 (全部不满足则丢弃):
   ├─ EtherType = 0x0806? ────────────→ 否→return
   ├─ HW Type = 0x0001 (Ethernet)? ───→ 否→return
   ├─ Proto Type = 0x0800 (IPv4)? ────→ 否→return
   ├─ HW Len = 6, Proto Len = 4? ─────→ 否→return
   ├─ Opcode = 0x0001 (Request)? ─────→ 否→return
   └─ Target IP = LOCAL_IP_ADDR? ────→ 否→return

3. 更新 ARP 缓存 (请求方 MAC + IP)

4. 原地构建 Reply (直接修改接收缓冲区):
   ├─ DstMAC ← 请求方 SrcMAC  (frame[0:5] ← frame[6:11])
   ├─ SrcMAC ← 本机 MAC       (frame[6:11] ← my_mac)
   ├─ Opcode ← 0x0002 (Reply) (frame[20:21])
   ├─ TargetMAC ← 请求方 MAC  (frame[32:37])
   ├─ TargetIP  ← 请求方 IP   (frame[38:41])
   └─ Sender MAC/IP ← 本机    (frame[22:31])

5. 填充至 60 字节 (最小以太网帧) → eth_tx_frame()
```

**ARP 缓存设计**:

```c
typedef struct {
    bool     valid;
    uint32_t ip;
    uint8_t  mac[6];
} arp_cache_t;

static arp_cache_t arp_cache;   // 仅缓存一台主机
```

对于 Ping 场景，只和一台 PC 通信，单条缓存足够。缓存设计为后续 TCP 阶段预先准备——TCP 发包时可通过 `arp_get_mac()` 快速获取目标 MAC。

### 7.3 可能出现的现象

- **正常现象**: PC 执行 `arp -a` 可见 169.254.1.1 的 ARP 条目 (动态类型)
- **异常现象 1**: ARP Request 发出但无 Reply — 检查对端 IP 是否匹配、EtherType 解析是否正确
- **异常现象 2**: Wireshark 显示 ARP Reply 但 PC 的 ARP 表未更新 — 确认 SrcMAC/TargetMAC 交换正确
- **异常现象 3**: "Who has 169.254.1.1" 但 Reply 发给错误的 MAC — DstMAC 未正确复制请求方 MAC

### 7.4 学习内容与总结

**核心收获**:
1. 深入理解了 ARP 协议的工作机制：广播问 MAC → 单播答 IP→MAC 映射
2. 掌握了原地修改帧的技巧（零拷贝）——直接修改接收缓冲区的对应字段后发送
3. 学会了多条件防御式校验的编程模式（每项独立 return）
4. 理解了以太网最小帧长 64 字节（含 FCS）→ 固件需填充 60 字节 payload 的根因

**总结**: ARP 是网络层通信的前置条件。PC ping FPGA 的第一步就是发 ARP Request 查询 169.254.1.1 的 MAC。ARP Reply 成功是 Ping 通的必要条件。

---

## 8. 固件设计：ip.c — IPv4 校验与协议分派

### 8.1 实验代码

**源文件**: `c/ip.c` (约 85 行)

### 8.2 工作原理

#### IPv4 头校验和算法

IPv4 头校验和使用 **16 位反码求和** (ones' complement sum)：

```
算法: ip_calc_checksum(data, byte_len)

1. 按 16 位累加: sum += data[i]<<8 | data[i+1]
2. 每次累加后进位回卷: while(sum>>16) sum = (sum&0xFFFF) + (sum>>16)
3. 奇数长度处理: 最后一个字节作为高字节 (padding zero on low byte)
4. 返回 ~sum (ones' complement)

验证方法: orig_csum + calc_csum 进位回卷后 == 0xFFFF
```

**关键实现细节**:

```c
uint16_t ip_calc_checksum(const uint8_t *data, uint16_t byte_len) {
    if (byte_len == 0) return 0xFFFF;       // 防御: 空数据返回全 1

    uint32_t sum = 0;
    uint16_t word_cnt = byte_len / 2;
    for (uint16_t i = 0; i < word_cnt; i++) {
        uint16_t w = (data[i*2] << 8) | data[i*2 + 1];
        sum += w;
        while (sum >> 16)                    // 进位回卷 (可能多次)
            sum = (sum & 0xFFFF) + (sum >> 16);
    }

    if (byte_len & 1) {                      // 奇数长度: 末字节补零
        sum += (uint16_t)(data[byte_len - 1] << 8);
        while (sum >> 16)
            sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return (uint16_t)(~sum);
}
```

**与参考文档的不同之处**: 参考文档的 `cks_sum_cal()` 是逐字节累加，这里的实现在 16 位对齐场景下效率更高（循环次数减半）。

#### ip_swap_src_dst — 交换 IP 地址并自动重算校验和

```c
void ip_swap_src_dst(uint8_t *frame) {
    // 交换 SrcIP ↔ DstIP (4 字节)
    swap(frame[OFF_IP_SRC_IP .. OFF_IP_SRC_IP+3],
         frame[OFF_IP_DST_IP .. OFF_IP_DST_IP+3]);

    // 清零校验和字段 → 重新计算 20 字节 IP 头 → 写回
    frame[OFF_IP_CHECKSUM] = 0;
    frame[OFF_IP_CHECKSUM+1] = 0;
    uint16_t new_cs = ip_calc_checksum(&frame[OFF_IP_VER_IHL], IP_HEADER_LEN);
    frame[OFF_IP_CHECKSUM]   = (new_cs >> 8) & 0xFF;
    frame[OFF_IP_CHECKSUM+1] = new_cs & 0xFF;
}
```

#### ip_process — IP 层主逻辑

```
ip_process(frame, len):

1. 最小长度检查: len < 14+20=34? → 丢弃

2. 版本/头长检查:
   Version != 4?  → 丢弃 (只支持 IPv4)
   IHL    != 5?  → 丢弃 (只支持 20 字节标准头, 无选项)

3. 校验和验证 (使用临时副本):
   tmp[20] ← 拷贝 IP 头
   清零 tmp 中的 checksum 字段
   计算 cks → orig+calc 进位回卷后是否为 0xFFFF
   否 → 丢弃

4. 目的 IP 检查: DstIP != LOCAL_IP_ADDR? → 丢弃

5. 协议分派:
   protocol == IP_PROTO_ICMP(1)? → icmp_process()
   其他协议 → 暂不支持, 丢弃
```

**校验和验证的技巧**:

```c
// 使用临时副本，不污染原始帧
uint8_t ip_hdr_tmp[IP_HEADER_LEN];
memcpy(ip_hdr_tmp, &frame[OFF_IP_VER_IHL], IP_HEADER_LEN);

// 备份原始校验和 → 清零 → 计算 → 验证
uint16_t orig_csum = (ip_hdr_tmp[...] << 8) | ip_hdr_tmp[...];
ip_hdr_tmp[...] = 0; ip_hdr_tmp[...+1] = 0;
uint16_t calc_csum = ip_calc_checksum(ip_hdr_tmp, IP_HEADER_LEN);

// 验证: orig + calc (进位回卷后) == 0xFFFF
uint32_t sum = (uint32_t)orig_csum + (uint32_t)calc_csum;
while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
if ((uint16_t)sum != 0xFFFF) return 0;  // 校验失败
```

### 8.3 可能出现的现象

- **正常现象**: IP 层正确处理 ICMP 包并分派到 icmp_process
- **异常现象 1**: 校验和验证失败丢弃所有 IP 包 — 检查 ip_calc_checksum 实现
- **异常现象 2**: IP 层通过了但 ICMP 层收不到 — 检查协议号 0x01 的偏移位置 (OFF_IP_PROTO)
- **异常现象 3**: 错误的源 IP 被缓存 — IPv4 头中 SrcIP 偏移计算有误

### 8.4 学习内容与总结

**核心收获**:
1. 深入理解了 IPv4 头校验和的 16 位反码求和算法及其验证方法
2. 掌握了"临时副本验校验和不污染原始帧"的编程技巧
3. 理解了 IP 层作为分派器的角色——不做数据处理，只做协议路由
4. 学会了逐项校验的防御式编程：版本/IHL/校验和/目的IP/协议号 全部独立校验

**总结**: IP 层是协议栈的"路由中枢"。本项目中 IP 层非常简单——只校验、不分片、不转发，仅将 ICMP 包路由到 icmp.c。这恰好体现了"只做本层该做的事"的分层设计原则。

---

## 9. 固件设计：icmp.c — ICMP Echo Reply 零拷贝实现

### 9.1 实验代码

**源文件**: `c/icmp.c` (约 70 行)

### 9.2 工作原理

#### ICMP Echo 协议

```
ICMP Echo Request/Reply 格式 (8 字节头):

┌──────────┬──────────┬──────────────┬──────────────┬──────────────┐
│ Type     │ Code     │ Checksum     │ Identifier   │ Sequence     │
│ 1 字节    │ 1 字节    │ 2 字节        │ 2 字节 (BE)   │ 2 字节 (BE)   │
├──────────┴──────────┴──────────────┴──────────────┴──────────────┤
│ Payload (可变长度, Echo Request 的 Payload 原样返回)              │
└──────────────────────────────────────────────────────────────────┘

Type = 0x08: Echo Request  (PC → FPGA)
Type = 0x00: Echo Reply    (FPGA → PC)
```

#### icmp_process — 零拷贝 Echo Reply 构建

```
icmp_process(frame, len) 处理流程:

1. 帧长校验: len < 14+20+8 = 42? → 丢弃

2. ICMP 类型检查: Type != 0x08 (Echo Request)? → 丢弃

3. ICMP 校验和验证 (使用原始帧原地计算):
   记录 orig_cs → 清零 → 计算 calc_cs
   → orig + calc 进位回卷 == 0xFFFF?
   否 → 恢复 orig_cs, 丢弃
   (验证失败但恢复原始值的做法防止缓冲区污染)

4. 零拷贝构建 Reply (直接在 frame[] 上修改):
   ├─ 交换 MAC:  DstMAC ← SrcMAC, SrcMAC ← my_mac
   ├─ 交换 IP:   调用 ip_swap_src_dst() (自动重算 IP 校验和)
   ├─ ICMP Type ← 0x00 (Echo Reply)
   ├─ ICMP Code ← 0
   └─ 重算 ICMP 校验和: ip_calc_checksum(&frame[OFF_ICMP_TYPE], icmp_total_len)

5. 填充至 60 字节 → eth_tx_frame()
```

**ICMP 校验和计算范围**: ICMP 校验和覆盖 ICMP 头 (8 字节) + Payload，不包含 IP 头。这与 IP 头校验和（只覆盖 IP 头自身）是不同的。

**零拷贝的优势**: 不需要分配新的发送缓冲区。PicoRV32 只有 32KB 程序 RAM，任何额外的缓冲区分配都会挤占宝贵的 BRAM 空间。直接在接收缓冲区上修改后发送，是资源受限环境下的最优策略。

### 9.3 可能出现的现象

- **正常现象**: `ping 169.254.1.1` 成功, 延迟 < 1ms (局域网 FPGA 回复)
- **异常现象 1**: Ping 发出但无 reply — 检查 ICMP 校验和是否正确、MAC 交换是否正确
- **异常现象 2**: Ping reply 到达但 "TTL expired" — TTL 未正确设置 (本项目中设为 64)
- **异常现象 3**: Ping 成功但延迟不稳定 — 检查主循环 polling 频率是否够高

### 9.4 学习内容与总结

**核心收获**:
1. 深入理解了 ICMP Echo 协议的 Type/Code 语义和校验和计算范围
2. 掌握了零拷贝帧修改的完整流程：MAC 交换 → IP 交换 → ICMP 修改 → 校验和重算
3. 理解了校验和验证失败后恢复原始值的防御式编程（避免缓冲区污染）
4. 体会了"逐层修改、逐层重算"的分层校验和设计

**总结**: ICMP Echo Reply 是本项目第一个可观测的"端到端"功能。PC 执行 ping，FPGA 回复 pong，验证了从 PHY→RGMII→GMII→MAC→FIFO→RISC-V→C 固件→发包的完整闭环。Ping 通是项目第一阶段的里程碑。

---

## 10. 资源占用与时序收敛分析

### 10.1 资源占用

**综合/布局布线**: Vivado 2024.1, XC7A35T-FGG484-2

| 资源类型 | 用量 | 总量 | 利用率 | 说明 |
|----------|------|------|--------|------|
| Slice LUTs | 3,780 | 20,800 | **18.17%** | 逻辑: 3,760, 存储器: 20 |
| Slice Registers | 5,202 | 41,600 | **12.50%** | Flip-Flop: 5,202, Latch: 0 |
| Block RAM Tile | 18.5 | 50 | **37.00%** | RAMB36: 18, RAMB18: 1 |
| DSP | 0 | 90 | **0.00%** | 未使用 (RV32IC 无硬件乘除) |
| MMCME2_ADV | 1 | 5 | **20.00%** | 时钟管理 |
| IDELAYCTRL | 1 | 5 | **20.00%** | RGMII 延迟校准 |
| IDELAYE2 | 5 | 250 | **2.00%** | RGMII RX 5 通道延迟补偿 |
| BUFGCTRL | 7 | 32 | **21.88%** | 全局时钟缓冲 |
| Bonded IOB | 22 | 250 | **8.80%** | 外部引脚 |

**资源分布特征**:

- **LUT 用量仅 18.17%** — PicoRV32 本身极其精简 (~1000 LUT)，剩余 LUT 用于 MAC 控制器和包 FIFO
- **BRAM 用量 37.00%** — 主要消耗在：PicoRV32 程序 RAM (32KB) + RX/TX 包缓冲 FIFO + instr RAM 初始化
- **DSP 用量 0%** — RV32IC 无硬件乘法器，印证了软件乘除的设计选择
- **剩余资源充裕** — 为 TCP 状态机和 HTTP 应用层预留了大量 LUT 和 BRAM 空间

### 10.2 时序分析

| 时钟域 | 周期约束 | WNS (最差负裕量) | 状态 |
|--------|----------|-------------------|------|
| clk_50m (CPU) | 20.0ns | 待补充 | — |
| clk_125m (MAC) | 8.0ns | 待补充 | — |
| clk_200m (IDELAYCTRL) | 5.0ns | 待补充 | — |
| rgmii_rxc (PHY) | 8.0ns | 异步 (false_path) | — |

**时序收敛策略**:

1. **MMCM 反馈设计**: 使用 CLKFBOUT 闭环反馈，消除 PVT (工艺/电压/温度) 变化对时钟质量的影响
2. **RGMII RXC 异步隔离**: `set_false_path` 声明 RGMII RXC 与内部时钟异步，工具不做跨域时序分析
3. **PicoRV32 流水线优化**: `TWO_STAGE_SHIFT=1` 将移位操作拆分为两级流水，降低关键路径长度

---

## 11. 调试方法与验证策略

### 11.1 三阶段验证体系

本项目采用 **仿真 → ILA 片上调试 → Wireshark 协议验证** 的三级验证漏斗：

```
阶段 1: Iverilog 仿真 (模块级)
  ├─ 验证 RGMII→GMII Bridge 时序
  ├─ 验证 MAC 层 CRC32 计算正确性
  ├─ 验证 CDC FIFO 读写无丢包
  └─ 验证 RISC-V 总线读写寄存器正确

阶段 2: Vivado ILA (系统级, 硬件)
  ├─ 抓取 RGMII TXD/RXD 双沿信号
  ├─ 抓取 GMII 内部信号 (mac_rx 前导码检测)
  ├─ 抓取 cpu_channel FIFO empty/full 标志
  └─ 确认帧数据完整进入 RX FIFO

阶段 3: Wireshark (端到端)
  ├─ PC 端抓 ARP Request/Reply
  ├─ 验证 MAC/IP 地址正确
  ├─ 验证 ICMP Echo Request/Reply 校验和
  └─ 确认 Ping 往返延迟在合理范围
```

### 11.2 LCPU 总线仿真框架

RISC-V 固件开发阶段使用 **LCPU BFM (Bus Functional Model)** 替代真实 RISC-V 核心，允许在 Iverilog 中直接以 Tcl 脚本驱动总线读写操作，无需等待 RISC-V 固件编译烧录：

```verilog
// 仿真模式: lcpu_bfm 通过 JTAG 总线接口读写寄存器
lcpu_bfm u_lcpu_bfm (
    .ADDRESS (jtag_address),
    .WR_DATA (jtag_wdata),
    .RD_DATA (jtag_rdata),
    .RH_WL   (jtag_rhwl),
    .EXEC    (jtag_req)
);
```

仿真模式与硬件模式的切换通过 `sim_mod` 参数控制，RTL 代码零修改。

### 11.3 Wireshark 验证清单

| 验证项 | 期望值 | 检查方法 |
|--------|--------|----------|
| ARP Request | Who has 169.254.1.1 | `arp.opcode == 1` 过滤器 |
| ARP Reply | 169.254.1.1 is at 02:00:00:12:34:56 | `arp.opcode == 2` 过滤器 |
| ICMP Echo Request | Type=8, 目的 IP=169.254.1.1 | `icmp.type == 8` 过滤器 |
| ICMP Echo Reply | Type=0, 源 IP=169.254.1.1 | `icmp.type == 0` 过滤器 |
| Ping 延迟 | < 1ms (局域网) | Wireshark 时间戳差值 |
| 帧填充 | ARP 帧长 ≥ 64 字节 | Wireshark Frame length |

---

## 12. 遇到的问题及解决措施

> *（本章节待补充 — 将在项目调测过程中记录实际遇到的 Bug 和解决方案）*

| 问题 | 原因分析 | 解决措施 | 阶段 |
|------|----------|----------|------|
| *(待补充)* | — | — | — |

---

## 13. 总体收获与总结

### 13.1 技术能力提升

| 领域 | 掌握内容 |
|------|----------|
| **RTL 设计** | RGMII/GMII 接口时序、MAC 层帧处理、异步 FIFO CDC 设计、IDELAY/IDDR/ODDR 原语使用 |
| **RISC-V 软核** | PicoRV32 配置参数、LCPU 总线协议、RV32IC 指令集特性、rdcycle 硬件计数器 |
| **网络协议** | 以太网帧格式 (EtherType 分派)、ARP 协议 (Request/Reply)、IPv4 头结构与校验和、ICMP Echo 协议 |
| **嵌入式 C** | 裸机编程 (无 RTOS)、寄存器映射与 volatile 语义、零拷贝帧处理、CRC/校验和算法 |
| **FPGA 工具链** | Vivado 综合/布局布线/比特流生成、XDC 时序约束、MMCM 时钟配置 |
| **仿真验证** | Iverilog 开源仿真器使用、LCPU BFM 总线功能模型、testbench 编写 |
| **调试方法** | ILA 片上逻辑分析仪、Wireshark 协议抓包分析、串口打印调试 |

### 13.2 工程素养提升

1. **分层设计能力**: 从 RTL 硬件到 C 固件的 6 层协议栈分层，每层职责清晰、接口明确
2. **跨时钟域设计思维**: 理解异步 FIFO、格雷码指针、set_false_path 约束在 CDC 中的角色
3. **零拷贝优化意识**: 在 32KB 程序 RAM 的极端约束下，学会原地修改帧数据而非分配新缓冲区
4. **调试漏斗策略**: 仿真 → ILA → Wireshark 三级验证，逐层缩小问题范围
5. **防御式编程**: 每层都校验帧长/类型/校验和，任何异常直接丢弃，防止错误传播
6. **软硬件协同视角**: 同时理解 Verilog 硬件数据通路和 C 固件协议栈，能够从两端定位问题

### 13.3 关键方法论

1. **先通链路，再写协议** — 确保 RGMII→GMII→MAC→FIFO→CPU 全链路帧数据可达后，再写 ARP/ICMP 协议逻辑
2. **零拷贝优于零分配** — 在资源受限的软核上，原地修改优于 malloc/free
3. **逐层校验、逐层丢弃** — 异常数据不在层间传播，每层独立做完整性检查
4. **硬件自动化优先** — CRC 校验/插入、前导码剥离/生成全部在 Verilog 硬件中完成，CPU 零开销
5. **仿真先行，上板验证** — Iverilog 模块级验证通过后才综合上板，减少 ILA 调试时间

### 13.4 项目统计数据

| 统计项 | 数据 |
|--------|------|
| HDL 模块文件 | 40 个 (.v / .sv) |
| C 固件文件 | 5 个 (.c) + 5 个 (.h) |
| 固件代码总量 | ~595 行 |
| 支持的协议 | 3 种 (ARP / IP / ICMP) |
| 跨时钟域路径 | 4 条 (RXC→125M→50M / 50M→125M→TXC) |
| LUT 利用率 | 18.17% (3,780 / 20,800) |
| BRAM 利用率 | 37.00% (18.5 / 50) |
| 系统时钟数 | 5 个 (50M / 125M / 200M / 125M_90° / RXC) |

---

> **项目感悟**: 从一根网线插进 FPGA 开发板到 PC ping 通，看似简单的一来一回，背后是一条跨越 7 个硬件模块和 5 层 C 协议栈的完整数据通路。RGMII 的 DDR 双沿时序、MAC 层的 CRC32 校验、CPU 的逐字节 FIFO 访问——每一个环节都可能出错，而一旦出错，表现就是"ping 不通"三个字。这让人深刻体会到：**嵌入式网络开发中，"能用"和"不能用"之间只差一个比特**。这个项目为后续实现 TCP 三次握手和 HTTP Web 服务器打下了坚实的软硬件基础。

---

> 本文档持续更新中 · 波形截图 / ILA 抓图 / Wireshark 截图待补充
