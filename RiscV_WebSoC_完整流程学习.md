# RISC-V WebSoC 项目完整流程学习文档

> 生成日期：2026-08-27　|　对照实际源码逐行提取（非设计文档）　|　配套 [开发日报](开发日报.md) 08-25~08-26 协议复习
> 用法：**第一部分**通读整体流程 + 扩展知识；**第二部分**问答自测（可配合 grill-me 质询）。

---

# 第一部分：完整流程总结

## 0. 项目总览与下一步规划

### 0.1 项目是什么

XC7A35T FPGA + RTL8211F 千兆 PHY 上，用 PicoRV32 软核（RV32IC @50MHz）跑一个**裸机零拷贝 TCP/IP 服务器固件**，只回答 ARP、ICMP（ping）、TCP（端口 80）和 HTTP（GET 网页）。三步渐进里程碑全部达成：

| 里程碑 | 验证 | 关键根因 |
|--------|------|---------|
| Ping 通 | `ping -c5 169.254.1.1` → 5/5、0% 丢、~1.8ms | 烧录 bitstream 过期导致位偏移全错 |
| TCP 握手 | `nc -zv ... 80` → succeeded 5/5 | TCP 伪首部校验和字节错位 |
| HTTP 网页 | `curl -i http://169.254.1.1/` → 200 OK 3/3 | FIN 必须 piggyback 进最后一个 DATA 段 |

### 0.2 当前状态与下一步

| 项 | 状态 |
|----|------|
| 三步渐进（ping/TCP/HTTP） | ✅ 全部达成（08-14） |
| 网络协议栈六层学习 | ✅ 学习 08-15~08-19、复习 08-25~08-26 |
| 跨层总纲收尾 | ⏳ 另行安排 |
| **下一步：手写 UART 驱动** | ⏳ 日报既定方向 |
| 再下一步：手写 I2C 驱动 | ⏳ |

**本项目边界（极简嵌入式栈的取舍）**：ip 不分片、不验入包 IP 校验和；tcp 无拥塞控制、`MAX_TCP_CONN=4`、ISN 固定 `0x10000000`；http 只判 GET、响应写死；UDP(17) 只识别未实现；无 ARP 表、无中断（`enable_irq=0`）、定时全靠 `rdcycle` 轮询。

---

## 1. 系统架构总图

### 1.1 硬件链路（RX 与 TX 共用一条主链）

```
PC ←网线→ [RTL8211F PHY] ←RGMII 4bit DDR@125MHz→ FPGA XC7A35T
                                                    │
        ┌───────────────┬───────────────────────────┤
        ▼               ▼                           ▼
  clk_125m_tx      rgmii_gmii_bridge            clk_200m
  (RGMII TXC 90°)  ├─ gmii_to_rgmii (ODDR×3, TX)
                   └─ rgmii_to_gmii (IDELAYE2+IDDR, RX)
                          │ gmii_rxd[7:0] / gmii_tx*
                          ▼
                     gmii2mac (MAC 层, clk_125m)
                     ├─ 异步FIFO (Eth_RXC→clk_125m, 16×10bit)
                     ├─ eth_presemble (前导码剥离/插入)
                     └─ mac_top: mac_rx(CRC32检查) / mac_tx(CRC32生成)
                          │ mac_rx_* / mac_tx_* (包流)
                          ▼
                     cpu_channel (clk_125m 写 / clk_50m 读)
                     ├─ package_fifo_v2 RX (4096B, 125m→50m)
                     └─ package_fifo_v2 TX (50m→125m) + pktfifo2ram
                          │ cpu_rd_* / cpu_wr_* (FIFO 握手)
                          ▼
                     lcpu_fpga_test (寄存器文件, clk_50m)
                          │ LCPU 总线 (req/rhwl/address/wdata/rdata/ack)
                          ▼
                     lcpu_riscv_wrapper → PicoRV32 (clk_50m)
```

### 1.2 时钟域（MMCME2 四路输出）

外部晶振 50MHz → `mmcm_50_125`（VCO 1000MHz）：

| 时钟 | 分频 | 相位 | 服务模块 |
|------|------|------|---------|
| clk_50m | /20 | 0° | PicoRV32、lcpu_fpga_test、cpu_channel 读侧、ILA 核0、ILA hub |
| clk_125m | /8 | 0° | gmii2mac、mac_rx/tx、cpu_channel 写侧、ILA 核1、PHY 复位计数 |
| clk_200m | /5 | 0° | IDELAYCTRL 参考时钟 |
| clk_125m_tx | /8 | **90°** | 仅 RGMII TX ODDR（TXC 时钟） |

`sys_rst_n = reset_l & pll_locked`；PHY 复位由 clk_125m 计数器延迟 ~16ms 释放。

### 1.3 两个关键跨时钟域（CDC）

| CDC 段 | 从→到 | 手段 | 丢包根因对应 |
|--------|-------|------|-------------|
| RX 站点 A | PHY 恢复时钟 Eth_RXC → clk_125m | gmii2mac 内 16 深异步 FIFO（格雷码指针） | `rx_afifo_full_cnt`（08-13 曾误判站点 A） |
| RX 站点 B | clk_125m → clk_50m | cpu_channel 内 package_fifo_v2（描述符 FIFO + 回读指针） | `mac_in_full` / `recv_pkt_drop_cnt`（双 pop 根因） |

---

## 2. 收包全链路（网线 → CPU 固件）

| 级 | 模块 | 时钟 | 做什么 | 关键点 |
|----|------|------|--------|--------|
| ① | rgmii_to_gmii | Eth_RXC | 4bit DDR → 8bit GMII | IDELAYE2 固定 20 tap≈1.56ns 移到采样窗口中央；SAME_EDGE_PIPELINED IDDR：Q1=posedge 低 4 位、Q2=negedge 高 4 位；`rx_dv=rx_ctl_q1`、`rx_er=q1^q2` |
| ② | gmii2mac 异步 FIFO | Eth_RXC→clk_125m | 跨时钟域搬运 | 16×10bit `{ER,DV,RXD}`，双端 free-running；写满计数 `rx_afifo_full_cnt` |
| ③ | eth_presemble | clk_125m | 剥前导码 | 认 `7×0x55 + 0xD5` 后才放行数据（`rx_valid_header`） |
| ④ | mac_rx | clk_125m | CRC32/FCS 检查 | 并行 CRC32，残差 `0x1cdf4421` 判好帧；**坏帧不丢**，只计数 `rx_crc_err_pkt_cnt`；FCS 不剥离 |
| ⑤ | cpu_channel | clk_125m 写 | 流式字节→包 FIFO | `frame_hit=1`（过滤关）；`wpkt_push = ~ram_wen & wen`（末字节后一拍） |
| ⑥ | package_fifo_v2 RX | 写 125m / 读 50m | 包缓冲 | 4096B 数据 RAM + 8 深描述符 FIFO（`{起始指针,para,len}`）；满阈值 `avail<1518`（used>2578）；`mac_in_full`/`recv_pkt_drop_cnt` |
| ⑦ | lcpu_fpga_test | clk_50m | 暴露寄存器 | `0x6000` 空标志、`0x6001` pop、`0x6002` 长度、`0x6005` 读偏移、`0x6006` 读数据 |

**三个必须记住的事实**：
1. **首字节 = 目的 MAC 高字节**（DMAC[47:40]），存在 FIFO 起始地址 0，CPU 从偏移 0 开始读（`eth_proc` 读 raddr 0~5 即 DMAC）。
2. **帧长含 FCS 4 字节**：`rpkt_len` 数到帧尾（含 CRC）；固件解析时按偏移即可，不回退 FCS。
3. **坏 CRC 帧照样进 FIFO**：mac_rx_err 不接 cpu_channel，只有 ILA 计数器能看见——别假设 CPU 只收到好包。

**sop_eop_gen 时序（易踩坑）**：`o_sop = i_en & ~i_en_d0`、`o_en = i_en_d0`、`o_data = i_data_d0`——**SOP、EN、首字节三者同拍**；`o_eop = ~i_en & i_en_d0`——EOP 与末字节同拍。文档里「SOP 提前 1 拍」是 TB 自造时序的注释，不是模块输出，照它建模会出 off-by-one。

---

## 3. 固件处理流程（主循环 + 协议分发）

### 3.1 启动与主循环

```
reset_entry (裸函数)          program_main
  la sp, _stack_top             LED=0x0F → (SIM_FAST 跳过延时) → LED=0
  bss 清零循环                  tcp_init()           // 连接表全清 CLOSED
  j program_main                while(1) {
                                  ① LED 心跳 (rdcycle 每 50M≈1s)
                                  ② tcp_timer_check()          // 超时重传
                                  ③ if (LCPU_RD_EMPTY()) continue;   // 判空
                                  ④ LCPU_RD_START_PACKET(); len=PKT_LEN();
                                     if (len==0 || len>2048) continue; // 坏包
                                  ⑤ eth_proc() → 协议分发
                                }
```

### 3.2 协议分发树（核心）

```
eth_proc()
├─ EtherType=0x0806 → ARP_PROC ──────────► arp_reply()
├─ EtherType=0x0800 → 验 dst MAC==本机?    // 广播 IP 不收，只有 ARP 认广播
│    ├─ 通过 → eth_write_tx_header()      // 预写 14B 以太网头到 TX
│    └─ 其他 → NO_PROC
└─ 其他 → NO_PROC
      ip_proc()
      ├─ 验 ver=4、IHL>=5、dst IP==169.254.1.1
      ├─ 读 src_ip / protocol / total_len
      ├─ protocol=1  → ICMP_PROC ────────► icmp_reply()
      ├─ protocol=6  → TCP_PROC ─────────► tcp_proc()
      │    └─ 返回 HTTP_PROC ───────────► http_proc(tcp_active_slot)
      └─ protocol=17 → UDP_PROC（未实现）
```

### 3.3 各层处理要点

| 层 | 函数 | 做什么 | 文件:行 |
|----|------|--------|---------|
| 以太网 | `eth_write_tx_header` | 预写 TX 头：src MAC=本机、dst MAC=RX 源 MAC、EtherType 照抄 | eth.c:7 |
| ARP | `arp_reply` | 三过滤（dst MAC 本机或广播 / target IP 本机 / opcode=Request）→ 9 段对调重填 → 补 0 到 64 字节 push | arp.c:4 |
| IP | `ip_proc` | 校验 + 读三全局量 + 分派；`ip_header_update` 复制 20B 头只换 total_len/src/dst/checksum | ip.c:10,79 |
| ICMP | `icmp_reply` | 零拷贝：type→0、code=0、id/seq/payload 抄回、算校验和；`tx_pkt_len=14+ip_total_len+4` | icmp.c:55 |
| TCP | `tcp_proc` | dst_port≠80→NO_PROC；无连接 SYN→listen 否则 RST；按状态分发 | tcp.c:395 |
| HTTP | `http_proc` | 判 GET（读 payload 前 3 字节）→ `tcp_send_data(ACK|PSH|FIN)` 单包；非 GET→`tcp_send_fin`；立刻 TIME_WAIT | http.c:16 |

### 3.4 ARP 应答 9 段「对调重填」（arp.c:44-105）

| 段 | TX 字段（字节） | 来源 |
|----|----------------|------|
| 1 | 目的 MAC 0-5 | RX 源 MAC 6-11 |
| 2 | 源 MAC 6-11 | 本机 Local_MAC |
| 3 | EtherType 12-13 | 照抄 0x0806 |
| 4 | htype/ptype/hlen/plen 14-19 | 照抄 |
| 5 | opcode 20-21 | 改 REPLY(2) |
| 6 | sender MAC 22-27 | 本机 MAC |
| 7 | sender IP 28-31 | 本机 IP |
| 8 | target MAC 32-37 | RX sender MAC 22-27 |
| 9 | target IP 38-41 | RX sender IP 28-31 |

### 3.5 TCP 状态机（实际用到的 6 个状态）

| 状态 | 进入 | 动作 |
|------|------|------|
| CLOSED | 复位/free | 槽位空闲 |
| SYN_RECEIVED | 收 SYN（`tcp_handle_listen`） | 记 remote_ip/port/seq、local_seq=ISN、回 SYN+ACK |
| ESTABLISHED | 收 ACK（`tcp_handle_syn_received`） | `local_seq+=1`（SYN 占 1 号）；收数据→回 ACK+上报 HTTP |
| CLOSE_WAIT | 主动关闭路径 | 回 FIN+ACK → LAST_ACK |
| LAST_ACK | 收 FIN（`tcp_handle_established`） | 回 FIN+ACK；收 ACK → free |
| TIME_WAIT | http 响应后立即 | 定时释放（`TCP_TIMEWAIT_TICKS`） |

**要点**：序号=字节流位置，SYN/FIN 各占 1 号，所以 ACK=对方 seq+1；`tcp_send_data` 末尾 `local_seq+=len`，带 FIN 再 +1。

### 3.6 定时与超时（无中断，全靠 rdcycle 轮询）

| 定时器 | 常量 | 行为 |
|--------|------|------|
| SYN+ACK 重传 | `TCP_SYN_RETRY_TICKS=50000000` | `tcp_timer_check` 超时重发，最多 3 次后 free |
| TIME_WAIT 清理 | `TCP_TIMEWAIT_TICKS=100000000` | 超时 free 槽位 |

> ⚠️ 坑：`TCP_SYN_RETRY_TICKS` 在 lcpu_general.h=150000000、tcp.h=50000000 重复定义，tcp.c/http.c 后 include tcp.h 生效值 50000000。依赖该值要小心。

---

## 4. 发包全链路（固件 → 网线）

```
固件 (clk_50m)
  LCPU_WR_SET_ADDR → _WR(2)=0x6102 (waddr)
  LCPU_WR_SET_DATA → _WR(3)=0x6103 (wdata)
  LCPU_WR_PULSE_WEN→ _WR(1)=0x6101 (wen, 产生 wen_ind 脉冲)
  逐字节写完
  LCPU_WR_PUSH_PACKET(len) = _WR(4)=len(0x6104) + _WR(6)=1(0x6106 push, 产生 push_ind)
        │
        ▼
cpu_channel (写 50m / 读 125m)
  package_fifo_v2 TX → pktfifo2ram_int_v2 自动排空(IPG=8)
  → sop_eop_gen: mac_tx_sop 提前 1 拍 / mac_tx_en / mac_tx_data
        │ clk_125m
        ▼
mac_tx
  fix_delay(4拍) → CRC32 并行计算(覆盖 DA..payload, 不含前导码)
  → 4 拍输出 FCS(crc[31:24]→[23:16]→[15:8]→[7:0]); mac_tx_err 时最后 FCS 字节反相
        │
        ▼
eth_presemble TX
  fix_delay(8) 对齐 → 插入 7×0x55 + 0xD5 前导码
        │
        ▼
gmii_to_rgmii (clk_125m_tx, 90°)
  3×ODDR: TXC(D1=1/D2=0 → 125MHz) / TX_CTL(D1=tx_en, D2=tx_en^tx_er)
          TXD(D1=gmii_txd[3:0] 上升沿, D2=gmii_txd[7:4] 下降沿)
        ▼
RGMII → PHY → PC
```

**两条硬规则**：
1. **push 长度含 FCS +4**：`tcp_send_data` 用 `14+40+len+4`，`icmp_reply` 用 `14+ip_total_len+4`；最小帧 64B，填充循环到 `tx_len-4` 为止（留 FCS 区）。
2. **每个 PUSH 是独立 TX block，eth 头必须每包重写**：eth_proc 只写了当前收包的第 1 个回包；HTTP 事务里第 2 个包（`tcp_send_data` tcp.c:324）和第 3 个包（`tcp_send_fin` tcp.c:365）都要自己再调 `eth_write_tx_header()`。

---

## 5. 寄存器接口（固件 ↔ 硬件）

### 5.1 地址编码规则

`FIFO_BASE = 0x80000000`。固件用 **word 索引 n** 表达寄存器，宏 ×4 变 CPU 字节地址；RTL 直接按 word 地址解码。

- `_RD(n) = *(volatile uint32*)(0x80000000 + (0x6000+n)*4)` → RX 区 word `0x6000+n`
- `_WR(n) = *(volatile uint32*)(0x80000000 + (0x6100+n)*4)` → TX 区 word `0x6100+n`
- riscv_reg 路由：`address >= 0x80000000` → 外设寄存器；`< 0x80000000` → 指令/数据 RAM

### 5.2 完整寄存器映射

| word | 字节地址(0x8000_0000+) | 宏 | 读/写 | 含义 |
|------|----------------------|-----|-------|------|
| 0x00 | 0x00000000 | — | R | fpga_build_date |
| 0x01 | 0x00000004 | — | R | fpga_build_time |
| 0x02/0x03 | 0x08/0x0C | — | RW | sw_build_date/time |
| 0x04~0x0F | 0x10~0x3C | — | RW | Scrach_RW_0..11 |
| 0x10 | 0x00000040 | `LCPU_SET_LED` | RW [3:0] | LED（复位 0xF） |
| 0x11 | 0x00000044 | — | R | pll_locked bit0 |
| 0x100 | 0x00000400 | — | RW bit0 | riscv_reset_l（低有效，默认 1=运行） |
| 0x6000 | 0x00018000 | `LCPU_RD_EMPTY` | R bit0 | RX 空标志（**非 0=空**，轮询到 0） |
| 0x6001 | 0x00018004 | `START_PACKET` 第1步 | W bit0 | cpu_rd_rpkt_pop（产生 pop_ind 脉冲） |
| 0x6002 | 0x00018008 | `LCPU_RD_PKT_LEN` | R 低16 | cpu_rd_rpkt_len 包长 |
| 0x6003 | 0x0001800C | — | R | cpu_rd_rpkt_para（未用） |
| 0x6004 | 0x00018010 | `START_PACKET` 第2步 | W bit0 | cpu_rd_ren（实际 no-op） |
| 0x6005 | 0x00018014 | `SET_ADDR/INC_ADDR` | RW | cpu_rd_raddr 读偏移 |
| 0x6006 | 0x00018018 | `LCPU_RD_DATA8` | R 低8 | cpu_rd_rdata 读数据 |
| 0x6007 | 0x0001801C | — | R | cpu_rd_reop_pre（未用） |
| 0x6100 | 0x00018400 | — | R bit0 | cpu_wr_full |
| 0x6101 | 0x00018404 | `PULSE_WEN` | W bit0 | cpu_wr_wen（产生 wen_ind 脉冲） |
| 0x6102 | 0x00018408 | `SET_ADDR` | RW | cpu_wr_waddr 写偏移 |
| 0x6103 | 0x0001840C | `SET_DATA` | RW | cpu_wr_wdata 写数据（低 8 位有效） |
| 0x6104 | 0x00018410 | `PUSH_PACKET` 第1步 | RW | cpu_wr_wpkt_len |
| 0x6105 | 0x00018414 | — | **洞** | 未解码，读回 0xdeaddead |
| 0x6106 | 0x00018418 | `PUSH_PACKET` 第2步 | W bit0 | cpu_wr_wpkt_push（产生 push_ind 脉冲） |
| 0x10000~0x1FFFF | 0x00040000+ | — | RW | 程序 RAM（4096 词） |

### 5.3 收包/发包寄存器时序

**收包**：轮询 0x6000 到 0 → `_RD(1)=1; _RD(4)=1`（pop）→ 读 0x6002 长度 → 对每字节写 0x6005=偏移、读 0x6006=数据。

**发包**：写 0x6102 偏移 + 0x6103 数据 + 0x6101 wen 脉冲（每字节）→ 写 0x6104 长度 + 0x6106 push 脉冲。

**关键**：驱动 FIFO 的是 `*_ind` 单拍脉冲（pop_ind / wen_ind / push_ind），不是寄存器电平；**写 0x6001/0x6101/0x6106 就触发脉冲**（与 wdata 值无关）。FIFO 数据宽 8 位，32 位写只有低 8 位有效。

---

## 6. 三层封包与三种校验和

### 6.1 封装与偏移

| 字段 | 字节偏移 | 说明 |
|------|---------|------|
| 以太网头 | 0~13 | DMAC(6)+SMAC(6)+EtherType(2) |
| IP 头 | 14~33 | `OFF_IP_* = 14 + 相对` |
| TCP 头 | 34~53 | `OFF_TCP_* = 14+20 + 相对` |
| TCP payload | 54+ | `OFF_TCP_PAYLOAD = 14+20+20`（HTTP 数据起点） |
| ARP 报文 | 14~41 | `OFF_ARP_* = 14 + 相对` |

### 6.2 三种校验和覆盖范围（最易混）

| 层 | 覆盖 | 计算要点 |
|----|------|---------|
| IP | 仅 20B 头 | 跳过 checksum 字段（当 0）、替换 total_len、反码求和取反（`ip_header_checksum`） |
| ICMP | 整个报文（8B 头+payload） | type 用改后的 0 参与；奇数 payload 末尾补 0 |
| TCP | 12B 伪首部 + 20B 头 + payload | 伪首部=srcIP+dstIP+0+协议6+TCP长度，不实际发送；checksum/urgent 填 0 |

校验和原语统一是 `cks_sum_cal(a,b,c)` = 16 位反码求和 + 进位折叠（comlib.c）。

---

## 7. 开发工作流（仿真 → 编译 → 烧录 → 调试）

| 阶段 | 命令/脚本 | 做什么 |
|------|----------|--------|
| 仿真 | `sim/run_sim.sh` | iverilog `-g2012 -s tb_webserver_cpu_top`，源=rtl/*.v + vendor_stubs + xpm 模型 + lcpu_bfm.sv + 主 TB；BFM 逐行执行 `tcl/InstructRAM.tcl` 把固件写进 IRAM；LED==0xF 判 PASS |
| 固件编译 | `cd c_build && make all` | riscv64-unknown-elf-gcc（rv32ic/ilp32、picolibc、-O2、nostdlib、--gc-sections）→ elf → objcopy → bin → pad 到 5120×4B → `bin_to_tcl.py` → InstructRAM.tcl |
| 综合/实现 | `build_xilinx/build.tcl` | Vivado 综合/实现/bitgen，内嵌 fpga_ila RTL；`write_mem_info` 生成 .mmi |
| 烧录 | `bash build_xilinx/load_fw_jtag.sh` | `updatemem` 把 16 个 bank*.mem bake 进 BRAM INIT → `_fw.bit` → JTAG program（~1 分钟） |
| 调试 | `./ila_gui.sh`（Qt/Web）、`ila_capture_core0.py` | UART 921600 连 fpga_ila 核，抓 2048 样本转 VCD/CSV |

**注意**：当前 `sim/` 里没有 Makefile / tb_fast.v（那是 git 历史里的旧流程）；现流程是 `run_sim.sh → tb_webserver_cpu_top.vcd`。设计文档里的 `web_app.c`/`designApp.c`/`tls.c` 也不存在，实际固件是 `main.c` 直接管主循环、`http.c` 只回写死网页。

---

## 8. 扩展知识（顺带沉淀）

### 8.1 RGMII = GMII 引脚减半版
- 4bit DDR @125MHz 双沿采样，等效 GMII 8bit SDR；引脚 ~12 根 vs ~24 根。
- RX：上升沿低 4 位、下降沿高 4 位；RX_CTL 上升沿=DV、下降沿=DV^ER（所以 `rx_er = q1^q2`）。
- TX：`clk_125m_tx` 90° 移相，让数据变化落在 TXC 窗口中央。

### 8.2 异步 FIFO / CDC
- 格雷码指针（相邻跳变只变 1 bit）+ 两级同步器；满/空用指针相等判断。
- package_fifo_v2 在包级再加 `pulse_clock_region_pass` 脉冲握手，把 pop 跨时钟域送过去，并把读指针回写域算出精确 used。

### 8.3 CRC32 / FCS
- 多项式 `0x04C11DB7`；以太网反射版 `0xEDB88320`。校验端不存发送 CRC，比对残差 `0x1cdf4421` 判好帧。
- MAC 自动算 FCS 并在帧尾追加，固件 push 长度要 +4；最小帧 64B。

### 8.4 ILA 双核分工
- 核0 @clk_50m：CPU 域（bus、`*_ind` 脉冲、计数器）——抓不到 125MHz 单拍脉冲。
- 核1 @clk_125m：GMII/MAC SDR 信号（SOP/EOP 单拍可见）——不碰 RGMII DDR 引脚（那是 clk_125m_tx 域）。
- 跨域关联用 `cpu_wr_wen_ind / cpu_wr_wpkt_push_ind` 脉冲对齐，别对裸边沿。

### 8.5 rdcycle 软件定时
- `LCPU_LOCAL_TIME_L()` 是 RISC-V `rdcycle` CSR，非 MMIO；所有超时（SYN 重传、TIME_WAIT）在主循环轮询，无中断。

### 8.6 零拷贝 FIFO 设计
- RX 包躺在双时钟包 FIFO 里，CPU 按偏移随机读（raddr/rdata），不拷进 CPU SRAM；TX 在独立 RAM 里逐字节堆，写完 push。代价是逐字节访问慢。

---

## 9. 下一步：手写 UART 驱动

项目下一步（日报既定）是 **手写 UART 驱动**。学习要点（对照项目里已有 `rtl/uart.v`、`uart_rx.v`、`uart_tx.v`）：

| 要点 | 内容 |
|------|------|
| 帧格式 | 起始位(1,低) + 数据 8bit LSB first + 停止位(1,高)，无校验 |
| 波特率 | 115200 → 每 bit ≈ 8.68μs；波特率分频 = clk/(baud×过采样率) |
| 过采样 | 通常 16×，用多数判决抑制噪声，采到下降沿即起始位 |
| 发送 | 空闲保持高电平；起始位拉低一 bit 宽，逐位移位输出 |
| 接收状态机 | IDLE → 检测下降沿 → 半位宽到中点 → 每 16 采样读一次 → 拼 8 位 → 停止位 |
| 与 ILA 关系 | 当前板载 UART 永久归 ILA（921600），CPU 侧 RX 置空闲；手写驱动先过仿真（vendor_stubs 无碍），验证收发再接硬件 |

---

# 第二部分：对应问答

> 分主题自测。先盖住答案试答，答不上再看。后面可配合 grill-me 质询轮。

## A. 架构与时钟域

**A1. 系统有几路时钟，各管什么？**
MMCME2 四路：clk_50m（CPU/寄存器/ILA核0/hub）、clk_125m（MAC/cpu_channel 写侧/ILA核1）、clk_200m（IDELAYCTRL 参考）、clk_125m_tx（RGMII TX ODDR，90° 移相）。

**A2. RX 路径上有几个 CDC 边界？分别在哪、靠什么？**
两个。① gmii2mac 内 16 深异步 FIFO：PHY 恢复时钟 Eth_RXC → clk_125m；② cpu_channel 内 package_fifo_v2：clk_125m → clk_50m。①靠格雷码指针，②在包级加脉冲握手。

**A3. 为什么 RGMII 的 TXC 要 90° 移相？**
让数据/控制跳变落在 PHY 采样窗口中央，保证 setup/hold。

**A4. `sys_rst_n` 是怎么来的？**
`reset_l & pll_locked`。PHY 复位另用 clk_125m 计数延迟 ~16ms 释放。

## B. 收包路径

**B1. RGMII 4bit 怎么还原成 8bit GMII？**
SAME_EDGE_PIPELINED IDDR：上升沿采低 4 位（Q1→gmii_rxd[3:0]）、下降沿采高 4 位（Q2→gmii_rxd[7:4]）。IDELAYE2 固定 20 tap≈1.56ns 移采样点。

**B2. FIFO 里一个帧的首字节是什么？长度含不含 FCS？**
首字节是目的 MAC 高字节（偏移 0）。长度含 FCS 4 字节。坏 CRC 帧也进 FIFO，只有 ILA 计数器能看。

**B3. sop_eop_gen 的 SOP/EN/首字节时序？**
三者**同拍**（`o_sop=i_en&~i_en_d0`，`o_en=i_en_d0`，`o_data=i_data_d0`）；EOP 与末字节同拍。

**B4. 满阈值怎么算？**
`avail_space = 4096 - used_words`；`full` 当 `avail < 1518`（即 used>2578），保证还能塞一个最大包。

## C. 固件处理

**C1. reset_entry 干了哪三件事？**
设栈顶 SP → 清零 BSS → 跳 program_main。

**C2. 主循环每圈做什么？**
① LED 心跳 ② tcp_timer_check ③ 判 RX 空 ④ 弹包+读长（坏包丢弃）⑤ eth_proc 分发。

**C3. eth_proc 对 IP 包先做什么检查？**
验目的 MAC == 本机（广播 IP 不收）；通过就 `eth_write_tx_header()` 预写回包以太网头。

**C4. ARP 应答的前置过滤是哪三条？**
目的 MAC 是本机或广播；target IP == 本机；opcode == Request(1)。

**C5. IP 校验和不校验入包？**
对，只查 ver/IHL、目的 IP；入包 IP 校验和不在 ip_proc 里验。

**C6. icmp_reply 的 push 长度公式？**
`14 + ip_total_len + 4`（+4 是 FCS），最小 64。

**C7. tcp_proc 对「无匹配连接」的包怎么处理？**
SYN → tcp_handle_listen（回 SYN+ACK）；其他 → tcp_send_rst。

**C8. 三次握手每一步序号怎么走？**
收 SYN 记 remote_seq；回 SYN+ACK 的 ACK=remote_seq+1；收 ACK 后 local_seq+=1（自身 SYN 占号）。

**C9. http_proc 为什么 FIN 要 piggyback？**
DATA 和 FIN 背靠背两包，第二个包在 TX FIFO 竞争里会被丢；合并单包（ACK|PSH|FIN）避免。根因记录于 08-14。

**C10. 定时器怎么实现？**
`rdcycle` 读周期计数，主循环轮询：SYN 重传最多 3 次；TIME_WAIT 到期释放槽位。无中断。

## D. 发包路径

**D1. 固件写一个字节到 TX 要哪三步寄存器？**
写 0x6102 偏移 + 0x6103 数据 + 0x6101 wen 脉冲。

**D2. 推包为什么是两步？**
`PUSH_PACKET(len)` = 写 0x6104 长度 + 写 0x6106 push 脉冲；push 产生 push_ind 驱动跨时钟 FIFO。

**D3. mac_tx 的 CRC 覆盖范围？FCS 何时输出？**
覆盖 DA..payload（不含前导码）；CRC 算完 4 拍连续输出 crc[31:24]→[7:0]。

**D4. 前导码在哪插入？**
eth_presemble TX 侧，fix_delay(8) 对齐后插 7×0x55+0xD5。

**D5. 为什么 HTTP 第 2/3 个包要重写 eth 头？**
每个 PUSH 是独立 TX block；eth_proc 只写了当前收包对应的第 1 个回包，后续包要自己 `eth_write_tx_header()`。

## E. 寄存器

**E1. `_RD(n)` 到底访问哪个地址？**
`0x80000000 + (0x6000+n)*4`（word 0x6000+n）；`_WR(n)` 同理 word 0x6100+n。RTL 按 word 解码。

**E2. `_RD(0)` 的语义是什么坑？**
非 0=空（轮询到 0 表示有包），和直觉相反。

**E3. 0x6105 是什么？**
洞，未解码；写/读回 `0xdeaddead`（超时 ack 路径），会掩盖 bug。

**E4. 驱动 FIFO 的是电平还是脉冲？**
`*_ind` 单拍脉冲（pop/wen/push_ind），写 0x6001/0x6101/0x6106 即触发，与 wdata 值无关。

**E5. FIFO 数据宽度？**
8 位。32 位写只有低 8 位有效，必须逐字节写。

## F. 开发流程

**F1. 现在仿真怎么跑？**
`sim/run_sim.sh`（iverilog，主 TB=tb_webserver_cpu_top，BFM 读 InstructRAM.tcl 写 IRAM）。没有 Makefile/tb_fast.v（旧流程）。

**F2. 固件怎么进 FPGA？**
c_build 编出 firmware.bin → 切 bank*.mem → `load_fw_jtag.sh` 用 updatemem bake 进 BRAM INIT 生成 _fw.bit → JTAG program。

**F3. 为什么板载 UART 不能用来上传固件？**
永久归 ILA（921600），CPU 侧 RX 置 1'b1；固件改由 JTAG 烧。旧 upload_fw.py（UART 上传 ~39min）已弃用。

**F4. 改固件后怎么生效？**
c_build 重编 + 重切 bank*.mem + 重跑 load_fw_jtag.sh。

## G. 边界与取舍

**G1. 本项目 TCP 栈缺什么？**
无拥塞控制、无窗口缩放/选项（固定窗 1460）、只并发 4 连接、ISN 固定、无 ACK 重传（只 SYN 重传）、IP 不分片不验入包校验和。

**G2. 为什么 `eth_proc` 不收广播 IP 包？**
只有 ARP 认广播目的（arp.c 里 `dst==0xFFFFFFFF`），IP 分支要求 `dst==Local_MAC` 精确匹配。

**G3. 一个 HTTP 请求对应几个 TX 包？**
1 个（GET→DATA+FIN 合并单包）；非 GET 也是 1 个（纯 FIN）。

---

*文档对照实际源码生成：c/main.c、eth.c、arp.c、ip.c、icmp.c、tcp.c、http.c、inc/lcpu_general.h、inc/tcp.h；rtl/webserver_cpu_top.v、lcpu_fpga_test.v、riscv_reg.v、gmii2mac.v、mac_rx.v、cpu_channel.v、package_fifo_v2.v、rgmii_to_gmii.v、gmii_to_rgmii.v、mmcm_50_125.v；sim/run_sim.sh、c_build/Makefile、build_xilinx/load_fw_jtag.sh、signals.json。*
