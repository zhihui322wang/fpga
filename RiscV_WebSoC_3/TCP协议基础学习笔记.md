# TCP 协议基础学习笔记

> 项目: RISC-V WebSoC (PicoRV32 + XC7A35T + RTL8211F)  
> 日期: 2026-08-04  
> 对应: 任务 6 — 学习 TCP 协议基础

---

## 一、TCP 报文格式

TCP 固定头 20 字节, 后面可选 Options 和 Payload。

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Source Port          |       Destination Port        |   字节 0-3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Sequence Number                        |   字节 4-7
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Acknowledgment Number                      |   字节 8-11
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Data  |           |U|A|P|R|S|F|                               |
| Offset| Reserved  |R|C|S|S|Y|I|            Window             |   字节 12-15
|       |           |G|K|H|T|N|N|                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           Checksum            |         Urgent Pointer        |   字节 16-19
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Options (if Data Offset > 5)                |   字节 20+
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Payload (应用数据)                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 关键字段

| 字段 | 位宽 | 字节偏移 | 说明 |
|------|------|----------|------|
| Source Port | 16 bit | 0 | 源端口, FPGA 回复时填入收到的 DstPort |
| Destination Port | 16 bit | 2 | 目的端口, FPGA 监听 80 |
| Sequence Number (SEQ) | 32 bit | 4 | 本方发送的字节编号, SYN/FIN 也占一个序号 |
| Acknowledgment Number (ACK) | 32 bit | 8 | 期望收到的下一个字节序号 = 对方SEQ+数据长度 |
| Data Offset | 4 bit | 12(高4bit) | TCP 头长度, 以4字节为单位, 无选项时=5(20字节) |
| Flags | 9 bit | 13(低6bit) | 控制标志, 见下表 |
| Window | 16 bit | 14 | 接收窗口大小 |
| Checksum | 16 bit | 16 | TCP 校验和, 含伪首部 |
| Urgent Pointer | 16 bit | 18 | 紧急指针, 本项目填 0 |

### 六个 Flag 位

| Flag | 十六进制 | 位位置 | 含义 | 本项目使用 |
|------|----------|--------|------|-----------|
| FIN | 0x01 | bit 0 | 结束发送, 关闭连接 | HTTP 响应完成后发送 |
| SYN | 0x02 | bit 1 | 同步序列号, 建立连接 | 三次握手第1、2步 |
| RST | 0x04 | bit 2 | 复位连接 | 收到非法/无匹配包时 |
| PSH | 0x08 | bit 3 | 推送, 立即交给应用层 | 可选 |
| ACK | 0x10 | bit 4 | 确认号字段有效 | ESTABLISHED 后几乎所有包都置位 |
| URG | 0x20 | bit 5 | 紧急指针有效 | 本项目不使用 |

```c
// 宏定义
#define TCP_FLAG_FIN  0x01
#define TCP_FLAG_SYN  0x02
#define TCP_FLAG_RST  0x04
#define TCP_FLAG_PSH  0x08
#define TCP_FLAG_ACK  0x10
```

---

## 二、TCP 校验和 (伪首部 + TCP 段)

TCP 校验和与 IP/ICMP 的关键区别: 需要包含一个 12 字节的"伪首部", 这个伪首部不会实际发送, 仅用于校验计算。

### 伪首部结构

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Source IP Address                       |   字节 0-3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Destination IP Address                    |   字节 4-7
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     Zero      |   Protocol    |        TCP Length              |   字节 8-11
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段 | 大小 | 值来源 |
|------|------|--------|
| Source IP | 4 字节 | 收到的 IP 包中 SrcIP (对方 IP) |
| Destination IP | 4 字节 | 收到的 IP 包中 DstIP (本机 = 169.254.1.1) |
| Zero | 1 字节 | 恒为 0x00 |
| Protocol | 1 字节 | 恒为 0x06 (TCP 协议号) |
| TCP Length | 2 字节 | TCP 头长度 + Payload 长度, 大端序 |

### 计算步骤

```
步骤 1: 构造伪首部 (12 字节)
步骤 2: 构造 TCP 头, Checksum 字段先填 0x0000
步骤 3: 拼接 → 伪首部 + TCP头 + Payload
步骤 4: 按 16 位一组做反码求和
步骤 5: 结果取反, 写入 TCP 头的 Checksum 字段
```

### 与现有校验和函数的衔接

项目已有 `comlib.c` 的 `cks_sum_cal(a, b, c)` 可复用:

```c
uint16 sum = 0;
// 遍历伪首部 (12 字节 = 6 个 16 位字)
sum = cks_sum_cal(pseudo[0], pseudo[1], sum);  // ×6
// 遍历 TCP 头 + Payload
for (int i = 0; i < tcp_total_len; i += 2)
    sum = cks_sum_cal(tcp_data[i], tcp_data[i+1], sum);
// 奇数长度补零
if (tcp_total_len % 2 == 1)
    sum = cks_sum_cal(tcp_data[tcp_total_len-1], 0x00, sum);
uint16 checksum = ~sum;
```

注意事项: Payload 奇数长度时末尾补 0x00。伪首部 IP 地址直接从收到的 IP 头读取。TCP Length 必须大端序。

---

## 三、三次握手

```
  客户端 (PC)                       服务器 (FPGA - 169.254.1.1:80)
       |                                        |
       |                                        | 状态: CLOSED → LISTEN
       |                                        |
       |  ==== 第 1 步: SYN ====                |
       |  SEQ = x (PC 的 ISN)                    |
       |  Flags = SYN (0x02)                     |
       |  DstPort = 80                           |
       |  ──────────────────────────────>        |
       |                                        | 检查 DstPort == 80
       |                                        | 记录 remote_seq = x
       |                                        | 生成 local_seq = y
       |                                        | 状态 → SYN_RECEIVED
       |                                        |
       |  <=== 第 2 步: SYN+ACK ===             |
       |  SEQ = y (FPGA 的 ISN)                   |
       |  ACK_Num = x + 1                        |
       |  Flags = SYN | ACK (0x12)               |
       |  <──────────────────────────────        |
       |                                        |
       |  ==== 第 3 步: ACK ====                |
       |  SEQ = x + 1                             |
       |  ACK_Num = y + 1                        |
       |  Flags = ACK (0x10)                     |
       |  ──────────────────────────────>        |
       |                                        | 验证 ACK == y+1
       |                                        | 状态 → ESTABLISHED
       |                                        |
       |  ~~~~ 连接建立, 可传输数据 ~~~~          |
```

### FPGA 端处理逻辑

收到 SYN:
```c
if (tcp->DstPort != 80) return;           // 不是监听端口
int slot = alloc_conn_slot();             // 分配连接槽
if (slot < 0) return;                     // 表满, 忽略
conn[slot].remote_ip   = ip->SrcIP;       // 记录对方 IP
conn[slot].remote_port = tcp->SrcPort;    // 记录对方端口
conn[slot].remote_seq  = tcp->SEQ;        // 记录对方 ISN = x
conn[slot].local_seq   = generate_isn();  // 生成 FPGA ISN = y
conn[slot].state = TCP_SYN_RECEIVED;
```

收到 ACK (验证):
```c
if (!(tcp->Flags & TCP_FLAG_ACK)) return;
int slot = find_conn(ip->SrcIP, tcp->SrcPort);
if (slot < 0 || conn[slot].state != TCP_SYN_RECEIVED) { send_rst(); return; }
if (tcp->ACK_Num != conn[slot].local_seq + 1) return;  // 验证失败
conn[slot].state = TCP_ESTABLISHED;
```

### 关键序号规则

SYN 和 FIN 都占用一个序号。ACK_Num = 对方SEQ + 数据长度。

| 场景 | SEQ | 数据长度 | 下次 SEQ |
|------|-----|----------|-----------|
| PC 发 SYN | x | 0 (SYN占1) | x + 1 |
| PC 发数据 100字节 | x + 1 | 100 | x + 101 |
| PC 发 FIN | x + 101 | 0 (FIN占1) | x + 102 |

---

## 四、TCP 状态机

### 本项目核心 4 状态

| 状态 | 宏 | 含义 | 触发条件 |
|------|-----|------|----------|
| TCP_CLOSED | 0 | 槽位空闲 | 初始值/超时/RST |
| TCP_LISTEN | 1 | 等待 SYN | 系统初始化后 |
| TCP_SYN_RECEIVED | 2 | 已回复 SYN+ACK | 收到有效 SYN |
| TCP_ESTABLISHED | 3 | 连接建立 | 收到有效 ACK |

(CLOSE_WAIT / LAST_ACK / TIME_WAIT 在任务 11 完善)

### 状态转移规则

```
CLOSED  →(主动打开端口80)→ LISTEN
LISTEN  →(收到 SYN)→ 回复 SYN+ACK → SYN_RECEIVED
LISTEN  →(收到非SYN)→ 忽略 → LISTEN
SYN_RECEIVED →(收到 ACK 验证通过)→ ESTABLISHED
SYN_RECEIVED →(收到重复 SYN)→ 重传 SYN+ACK → SYN_RECEIVED
SYN_RECEIVED →(超时无 ACK)→ 重传×3 → CLOSED
ESTABLISHED →(收到数据)→ 交给上层 → ESTABLISHED
ESTABLISHED →(收到 FIN)→ 回复 ACK → CLOSE_WAIT
任何状态 →(收到 RST)→ 释放连接槽 → CLOSED
任何状态 →(无匹配连接)→ 回复 RST → 不变
```

---

## 五、实现数据结构

连接表用并行数组 (在 RISC-V 软核上比结构体数组更高效):

```c
#define MAX_TCP_CONN 16

uint8_t  tcp_state     [MAX_TCP_CONN];  // CLOSED/LISTEN/SYN_RECEIVED/ESTABLISHED
uint32_t tcp_remote_ip [MAX_TCP_CONN];  // 对方 IP
uint16_t tcp_remote_port[MAX_TCP_CONN]; // 对方端口
uint32_t tcp_local_seq [MAX_TCP_CONN];  // FPGA 自己的 SEQ
uint32_t tcp_remote_seq[MAX_TCP_CONN];  // 对方最新发来的 SEQ
uint32_t tcp_remote_ack[MAX_TCP_CONN];  // 对方确认的序号
uint8_t  tcp_retry_cnt [MAX_TCP_CONN];  // SYN+ACK 重传计数
uint32_t tcp_timer     [MAX_TCP_CONN];  // 超时计数器

// 分配空闲槽位
int alloc_tcp_slot(void) {
    for (int i = 0; i < MAX_TCP_CONN; i++)
        if (tcp_state[i] == TCP_CLOSED) return i;
    return -1;
}

// 根据 IP+Port 查找连接
int find_tcp_slot(uint32_t ip, uint16_t port) {
    for (int i = 0; i < MAX_TCP_CONN; i++)
        if (tcp_state[i] != TCP_CLOSED &&
            tcp_remote_ip[i] == ip && tcp_remote_port[i] == port)
            return i;
    return -1;
}
```

---

## 六、TCP 头在帧中的字节偏移

基于项目现有偏移体系, TCP 头起点 = 以太网头(14) + IP头(20) = 34:

```
OFF_TCP_SRC_PORT  = 34   (2B)
OFF_TCP_DST_PORT  = 36   (2B)
OFF_TCP_SEQ       = 38   (4B)
OFF_TCP_ACK_NUM   = 42   (4B)
OFF_TCP_DATA_OFS  = 46   (高4bit)
OFF_TCP_FLAGS     = 47   (低6bit)
OFF_TCP_WINDOW    = 48   (2B)
OFF_TCP_CHECKSUM  = 50   (2B)
OFF_TCP_PAYLOAD   = 54   (Data Offset=5)
```

---

## 七、与现有代码的衔接

现有调度流程:
```
main.c: program_main()
  ├─ eth_proc()        → 解析 EtherType, 返回 ARP_PROC/IP_PROC
  ├─ arp_reply()       → 处理 ARP
  ├─ ip_proc()         → 解析 IP 头, 返回 ICMP_PROC
  └─ icmp_reply()      → 处理 ICMP
```

需要改动的文件:

| 文件 | 修改 | 对应任务 |
|------|------|----------|
| lcpu_general.h | 加 TCP 常量、Flag、偏移宏 | 任务 7 |
| ip.c ip_proc() | 加 protocol==0x06 → 返回 TCP_PROC | 任务 8 |
| main.c | 加 if(iptype==TCP_PROC) tcp_proc() | 任务 8 |

---

## 八、学习检查清单

- TCP 头固定 20 字节。Data Offset=5 表示 20 字节 (5×4)。
- SYN=0x02, ACK=0x10, SYN|ACK=0x12。
- 校验和加伪首部是为了防止数据被错误路由。伪首部: SrcIP(4B)+DstIP(4B)+Zero(1B)+Proto(6,1B)+TCP_Length(2B)。
- 第二步 ACK_Num=x+1 而不是 x: SYN 消耗一个序号, 对方 SEQ=x 的 SYN 消耗了序号 x, 期望下一个 x+1。
- 收到重复 SYN: 重传 SYN+ACK (对方没收到我们的), 不改变状态。
- ACK=0 不能进入 ESTABLISHED: ACK 标志未置位或序号无效。
- TCP 校验和 vs ICMP 校验和: TCP 包含 12 字节伪首部, ICMP 只覆盖自身。
