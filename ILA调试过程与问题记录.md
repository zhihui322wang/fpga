# ILA 调通过程与问题记录

> 项目：RiscV_WebSoC（PicoRV32 + XC7A35T-FGG484-2 + RTL8211F PHY）
> 工具：fpga_ila 软逻辑分析仪（封装工具，只读使用）
> 日期：2026-08-14

---

## 一、背景与目标

用 fpga_ila 抓波形定位 RiscV_WebSoC 的网络调试问题（ping 丢包 → TCP 握手 → HTTP 网页）。ILA 是封装好的软逻辑分析仪，只调用 host API 配置触发/抓波/回读，不改其源码。

**核心结论**：ILA 采样时钟必须与探针信号时钟域匹配——50MHz 采样抓不到 125MHz 域的 GMII/MAC 单拍脉冲，需要拆双核分别挂到各自的时钟域。

---

## 二、最终架构：双核 ILA

| 项 | core0 | core1 |
|----|-------|-------|
| 采样时钟 | clk_50m（CPU 域） | clk_125m（GMII/MAC 域） |
| 探针数 / 位宽 | 32 探针 / **184bit** | 13 探针 / **41bit** |
| 深度 | 2048 | 2048 |
| 签名 | `0x00000800200100B8` | `0x000008000D010029` |
| 抓什么 | CPU 总线 + 包 FIFO 握手 + 计数器 | GMII/MAC SDR 上游信号（含 SOP/EOP 单拍） |

- 传输：单路 UART `/dev/ttyACM1` @ 921600（`ILA_TRANSPORT_EN=3'b001`）
- 寄存器总线：`jtag_clk` 仍走 50MHz，与采样时钟分离
- 多核通过 `core_id`（0/1）在协议里寻址；`core=255` 是 hub 广播（ping）

---

## 三、调试过程（时间线）

### 阶段 1：单核 50MHz 抓 GMII/MAC → 失败

最初 ILA 用 `clk_50m` 当 `sample_clk`，抓 `gmii_rx_dv`/`gmii_rxd`/`mac_rx_*` 等信号。

**现象**：`gmii_rx_dv=1` 触发等 12s **超时强制触发**，抓回 2048 样本里 gmii/mac 侧**全 0**；但 `rx_correct_pkt_cnt=131` 证明帧一直在收，`cpu_rd_ren`/`bus_req`（50MHz 域）抓得准。

**结论**：ILA/回读/位偏移都没问题，唯独 125MHz 域信号跨域采样采成恒 0。

### 阶段 2：定位根因 — 采样时钟域错配（欠采样）

追 RTL 确认信号时钟域：

- `gmii_rx_dv`/`gmii_rxd` 在 PHY 的 `Eth_RXC`（千兆 = **125MHz**）域
- `mac_rx_*` 在 `clk_125m`（**125MHz**）域

50MHz 采样周期 20ns，采 125MHz 信号的 8ns 单拍脉冲（SOP/EOP）——低于 Nyquist（2×125MHz=250MHz），异步跨时钟域，单拍脉冲被漏掉。**不是 ILA 坏了，是采样时钟没匹配信号域。**

### 阶段 3：双核方案设计

拆成两个核，各自挂正确的采样时钟：

- core0 保持 `clk_50m` → 抓 CPU 域（总线 + 包 FIFO 握手 + 计数器）
- 新增 core1 挂 `clk_125m` → 抓 GMII/MAC SDR 上游信号

### 阶段 4：时钟域核实（追 RTL 得出，非猜测）

确认 TX 侧信号域，决定是否还需要第三个核：

- `mac_tx_sop/en/data/eop/err`、`gmii_txd`、`gmii_tx_en` **全在 clk_125m** 域（gmii2mac 只有 `clk`→clk_125m 和 `Eth_RXC` 两个时钟，TX 走 `clk`）
- `clk_125m_tx`（90°移相）**只**服务 `rgmii_gmii_bridge` 的 DDR 输出引脚（`rgmii_txd/rgmii_txc`），soft ILA 不采（DDR 需 250m + IDDR）

**结论**：RX+TX 全塞一个 125m 核即可，**无需第三个核**。

### 阶段 5：编译 + 时序收敛

- `build.tcl` 全量重跑：synth_1 17:04 / impl_1 17:05:36 "Bitgen Completed Successfully"，0 Errors 0 Critical Warnings
- 时序收敛：WNS **+1.083ns** @125m（此前担心的 151bit 宽总线 -4ns 问题消失）；Hold +0.034ns

### 阶段 6：BRAM 布局移位坑（关键）

新增 core1 的 BRAM 采样缓冲把 16 个指令 RAM bank 的**物理布局顶移位**（bank9 `X2Y5`→`X1Y3`）。而 `build.tcl` 主进程在 16:57 挂掉、没走到 `write_mem_info`，旧 `.mmi` 会让 `updatemem` 把固件写进**错误 BRAM 位置** → CPU 起来是空 RAM。

**修复**：写 `finish_build.tcl` 补跑 `open_run impl_1 → write_mem_info`，`.mmi` 18:08 重生成。

### 阶段 7：烧录 — 孤儿 hw_server 坑

首次 JTAG 下载报 `no active target ... locked by another hw_server`。根因：孤儿 `hw_server`（PID 12661，PPID=1，由已退出的 GUI Vivado spawn）锁住 JTAG-SMT2。杀掉残留 hw_server + cs_server 后重跑即通 → "PROGRAMMING SUCCESS"。

### 阶段 8：核1 抓波验证成功（@125MHz）

`gmii_rx_dv` 触发 + ping，回读 2048 样本，解码出**完整以太网 RX 帧**：

```
前导码 55×7 + SFD d5
目的 MAC 00:00:01:02:04:05   源 MAC 9c:69:d3:7d:47:4c（主机）
EtherType 0x0800 → IPv4 / ICMP
SOP@sample536  EOP@sample637（单拍脉冲清晰可见）
```

这证明 core1 抓到了 core0（50MHz）此前抓不到的单拍 SOP/EOP 脉冲。

### 阶段 9：核0 触发信号选择（关键）

抓 CPU 总线时，触发信号的选择直接决定抓到的内容：

| 触发信号 | 结果 |
|----------|------|
| `bus_req`（bit41） | ❌ 抓到 **CPU 空闲轮询**：地址恒 `0x6000`、读回恒 `0x80018010`，`bus_req` 全程仅 2 个上升沿。CPU 空闲也周期性访问总线，arm 后立刻触发 |
| `cpu_wr_wen_ind`（bit144） | ✅ 精确钉住 ping 回复的 TX 包写瞬间（`_ind` 脉冲仅发送包时单拍拉高） |

### 阶段 10：核0 抓 CPU 总线成功

6 次 ping 回复，每个回复 = 3 次总线写事务循环：

| 地址 | 数据 | 含义 |
|------|------|------|
| `0x6101` | `wdata=1` | 写控制/包起始（伴随 `cpu_wr_wen_ind` 脉冲） |
| `0x6102` | `wdata=6,7,8,9,a,b` 递增 | TX 数据（递增 = ICMP 序号） |
| `0x6103` | `wdata=0,1,2,4,5` 递增 | TX 数据 |

触发点落位 sample 512（=pretrig），`bus_req` 上升沿总数 61，事务干净可读。

---

## 四、发现的问题清单

### A. 采样时钟域问题

| 问题 | 现象 | 解决 |
|------|------|------|
| 采样时钟与信号域错配 | 50MHz 采 125MHz 信号，单拍脉冲（8ns SOP/EOP）采不到，波形全 0 | 拆双核，核1 挂 clk_125m |

**原则**：`sample_clk` 必须 ≥ 2×信号频率（Nyquist），且与探针信号同域。50M 只能采 50M 域（CPU 总线/计数器）。

### B. 触发问题

| 问题 | 现象 | 解决 |
|------|------|------|
| 触发信号选「电平」而非「事件脉冲」 | `bus_req` 空闲也周期性拉高，抓到空闲轮询 | 改用 `cpu_wr_wen_ind` 等 `_ind` 单拍脉冲 |
| 触发掩码默认全 1（仿真阶段） | TRIG_MASK 上电默认 96bit 全 1，只写 word0 导致高位比较失败 | 所有 word 都清零 |

**原则**：`_ind` 后缀脉冲只在特定事件单拍拉高，做触发能精确钉住业务事件；电平信号（bus_req 等）空闲也变化，易误触发。

### C. 构建 / 烧录问题

| 问题 | 现象 | 解决 |
|------|------|------|
| 新增 BRAM 顶移位 + 旧 `.mmi` | updatemem 把固件写进错误 BRAM，CPU 空 RAM | 重新 `write_mem_info` 生成 `.mmi` |
| `build.tcl` 主进程挂掉 | 没走到 `write_mem_info`，`.mmi` 过期 | `finish_build.tcl` 补跑收尾 |
| 孤儿 hw_server 锁 JTAG | "no active target ... locked by another hw_server" | 杀残留 hw_server + cs_server |

**原则**：改 RTL（新增核）后**必须重新生成 `.mmi`**，否则固件合并写错位置；读波形前先核对 bitstream 与源码一致（`get_core_cfg().total_width` 是最快体检——150bit vs 184bit 不一致就说明烧错）。

### D. 传输 / 设备问题

| 问题 | 现象 | 解决 |
|------|------|------|
| UART 设备重枚举 | 脚本用 `/dev/ttyACM0`，实际设备已变成 `/dev/ttyACM1` | 重新编程后确认设备号 |
| 串口独占 | GUI 占着串口时脚本连不上 | 抓波前先关 GUI 释放串口 |

### E. 仿真阶段问题（iverilog，前期定位）

| 问题 | 现象 | 解决 |
|------|------|------|
| IDDR stub 缺 SAME_EDGE_PIPELINED | RGMII 采样错误 | 加 q1_int/q2_int 内部寄存器 |
| testbench 缺前导码 | eth_presemble 不透传数据 | 补 7×0x55 + 0xD5 |
| RGMII 驱动时序 | negedge 驱动 lower nibble / posedge upper | zero-delay NBA 规则 |
| XPM RAM 未初始化 | 读回不确定值 | 初始化内存为 0 |
| BURST_PTR 不回读 Bug | data_byte_off 整数除法=0，4096 样本全相同 | 扁平偏移编址 |
| 监控错误信号 | `cpu_wr_wpkt_push`（顶层未连接）vs `_ind` 版本 | 用 `cpu_wr_wpkt_push_ind` |

---

## 五、关键经验与原则

1. **采样时钟域匹配是 ILA 第一原则**：`sample_clk` 要和探针信号同域，否则跨域采样（欠采样）采成恒 0。50M 抓 50M 域，125M 抓 125M 域。
2. **触发选「事件脉冲」而非「电平」**：`_ind` 单拍脉冲精确钉住业务事件；电平信号（bus_req）空闲也变化。
3. **读波形前先核对 bitstream**：`get_core_cfg().total_width` 是最快体检，位宽对不上说明烧错，据此的诊断全是误诊。
4. **改 RTL（新增核/BRAM）后必须重新生成 `.mmi`**：BRAM 物理布局会移位，旧 `.mmi` 让固件写错位置。
5. **触发掩码写全所有 word**：TRIG_MASK 上电默认全 1，只写 word0 会导致高位比较失败。
6. **GUI 与脚本互斥**：两者共享一个 UART 串口，同时只能一个进程占用。
7. **工具只读**：只改项目 RTL 例化参数/probe 连接/signals.json，不碰 fpga_ila 源码、不碰 ip 库。

---

## 六、附录

### 6.1 寄存器映射

| 寄存器 | 地址 | 说明 |
|--------|------|------|
| CTRL | 0x04 | 控制（arm/disarm） |
| STATUS | 0x08 | bit0=armed bit1=triggered bit2=done bit3=overflow |
| PRETRIG | 0x14 | 前触发样本数 |
| POSTTRIG | 0x18 | 后触发样本数 |
| TRIG_MODE | 0x20 | 触发模式（0x1=值匹配） |
| TRIG_VALUE | 0x24（word0-3）| 触发值（legacy 4 字） |
| TRIG_MASK | 0x28（word0-3）| 触发掩码（legacy 4 字） |
| TRIG_VALUE_EXT | 0xD0（word4+）| 触发值扩展（>128bit 用） |
| TRIG_MASK_EXT | 0xE0（word4+）| 触发掩码扩展 |
| SEQ_BASE | 0x40 | sequencer 配置（写 0 禁用） |

> 184bit = 6 触发字：word0-3 走 legacy（0x24/0x28），word4-5 走 EXT（0xD0/0xE0）。`set_trigger` 自动处理此映射。

### 6.2 抓波脚本

| 脚本 | 用途 |
|------|------|
| `ila_capture_core0.py` | 核0（50MHz）抓 CPU 总线，`cpu_wr_wen_ind` 触发 |
| `ila_capture_core1.py` | 核1（125MHz）抓 GMII/MAC，`gmii_rx_dv` 触发 |
| `ila_gui.sh` | 打开 Qt GUI（切核看波形） |
| `ila/` | 归档的旧调试脚本 |

### 6.3 常用命令

```bash
# 抓波（先确认 GUI 已关闭释放串口）
python3 ila_capture_core0.py      # 核0 CPU 总线
python3 ila_capture_core1.py      # 核1 GMII/MAC

# 打开 GUI
./ila_gui.sh

# 抓波后触发流量（另开终端或输入框 ! 前缀）
ping -c 3 -i 0.2 169.254.1.1
```
