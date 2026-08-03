// lcpu_general.h — 硬件抽象层: 寄存器地址 + FIFO 操作 + 协议常量

#ifndef _LCPU_GEN_H_
#define _LCPU_GEN_H_

#include <stdint.h>
#include <stdbool.h>

// ── 基础类型 ──
typedef uint8_t   uint8;
typedef uint16_t  uint16;
typedef uint32_t  uint32;
typedef int8_t    int8;
typedef int16_t   int16;
typedef int32_t   int32;

// ── LCPU 总线 32-bit 访问, 基址 0x8000_0000 ──
#define HW_BASE  0x80000000u

// 每个寄存器占 4 字节, offset 是字偏移
#define HW_REG8(offset)  (*(volatile uint32_t *)(HW_BASE + (uint32_t)(offset) * 4))

static inline uint32_t reg32_read(uint32_t offset) {
    return HW_REG8(offset);
}
static inline void reg32_write(uint32_t offset, uint32_t val) {
    HW_REG8(offset) = val;
}

// ── 寄存器字节偏移 ──
// 系统
#define REG_FPGA_DATE      0x0000
#define REG_FPGA_TIME      0x0001
#define REG_SW_DATE        0x0002
#define REG_SW_TIME        0x0003
#define REG_SCRATCH0       0x0004
#define REG_SCRATCH5       0x0009
#define REG_LED            0x0010   // RW 低 4 位
#define REG_PLL_LOCKED     0x0011
#define REG_RISCV_RST      0x0100

// RX FIFO
#define REG_RX_EMPTY       0x6000   // RO bit0, 1=空
#define REG_RX_PKT_POP     0x6001   // WC 写 1 弹出
#define REG_RX_PKT_LEN     0x6002   // RO 当前包字节数
#define REG_RX_PKT_PARA    0x6003   // RO
#define REG_RX_REN         0x6004   // RW 读使能
#define REG_RX_RADDR       0x6005   // RW 字节偏移
#define REG_RX_RDATA       0x6006   // RO 低 8 位
#define REG_RX_REOP_PRE    0x6007   // RO

// TX FIFO
#define REG_TX_FULL        0x6100   // RO bit0, 1=满
#define REG_TX_WEN         0x6101   // WC 写使能脉冲
#define REG_TX_WADDR       0x6102   // RW 字节偏移
#define REG_TX_WDATA       0x6103   // RW 低 8 位
#define REG_TX_PKT_LEN     0x6104   // RW 发包长度
#define REG_TX_PKT_PUSH    0x6106   // WC 写 1 推送

// ── RX FIFO 操作 ──
#define LCPU_RD_EMPTY()         (HW_REG8(REG_RX_EMPTY) != 0)

// 开始读包: 弹出当前包 → 锁存到读缓冲区 + 读使能
#define LCPU_RD_START_PACKET()  do { \
    HW_REG8(REG_RX_PKT_POP) = 1;     \
    HW_REG8(REG_RX_REN) = 1;         \
} while(0)

#define LCPU_RD_STOP()          do { HW_REG8(REG_RX_REN) = 0; } while(0)
#define LCPU_RD_PKT_LEN()       ((uint16_t)(reg32_read(REG_RX_PKT_LEN) & 0xFFFFu))
#define LCPU_RD_PKT_PARA()      (reg32_read(REG_RX_PKT_PARA))

static inline void rd_set_addr(uint32_t addr) { reg32_write(REG_RX_RADDR, addr); }
#define LCPU_RD_SET_ADDR(addr)  rd_set_addr(addr)
#define LCPU_RD_DATA8()         ((uint8_t)(reg32_read(REG_RX_RDATA) & 0xFFu))
#define LCPU_RD_REOP_PRE()      ((HW_REG8(REG_RX_REOP_PRE) & 0x01) != 0)

// ── TX FIFO 操作 ──
#define LCPU_WR_FULL()          ((HW_REG8(REG_TX_FULL) & 0x01) != 0)
#define LCPU_WR_PULSE_WEN()     do { HW_REG8(REG_TX_WEN) = 1; } while(0)

// ── LED ──
#define LCPU_SET_LED(val)       do { HW_REG8(REG_LED) = (uint8_t)(val); } while(0)

// ── 定时器 (rdcycle) ──
static inline uint32_t lcpu_local_time_l(void) {
    uint32_t t;
    __asm__ volatile ("rdcycle %0" : "=r"(t));
    return t;
}

// ── 调试 RAM ──
#define LCPU_DBG_WRITE(idx, val) reg32_write(0x10000 + (idx)*4, (uint32_t)(val))
#define LCPU_DBG_READ(idx)       ((uint8_t)(reg32_read(0x10000 + (idx)*4) & 0xFFu))

// ── 本机网络参数 ──
#define LOCAL_MAC_BYTE0  0x02
#define LOCAL_MAC_BYTE1  0x00
#define LOCAL_MAC_BYTE2  0x00
#define LOCAL_MAC_BYTE3  0x12
#define LOCAL_MAC_BYTE4  0x34
#define LOCAL_MAC_BYTE5  0x56

#define LOCAL_IP_ADDR    0xA9FE0101u   // 169.254.1.1 (链路本地)

// ── 协议常量 ──
#define ETH_TYPE_IP      0x0800
#define ETH_TYPE_ARP     0x0806
#define ETH_MAX_FRAME_LEN 1518

#define IP_PROTO_ICMP    0x01

#define ARP_REQUEST      0x0001
#define ARP_REPLY        0x0002

#define ICMP_ECHO_REQ    0x08
#define ICMP_ECHO_REPLY  0x00

// ── 协议头长度 ──
#define ETH_HEADER_LEN   14
#define IP_HEADER_LEN    20
#define ICMP_HEADER_LEN  8

// ── 帧内偏移 ──
// 以太网头
#define OFF_ETH_DST_MAC   0
#define OFF_ETH_SRC_MAC   6
#define OFF_ETH_TYPE     12

// IP 头 (ETH + 14)
#define OFF_IP_VER_IHL   (ETH_HEADER_LEN +  0)
#define OFF_IP_TOTAL_LEN (ETH_HEADER_LEN +  2)
#define OFF_IP_PROTO     (ETH_HEADER_LEN +  9)
#define OFF_IP_CHECKSUM  (ETH_HEADER_LEN + 10)
#define OFF_IP_SRC_IP    (ETH_HEADER_LEN + 12)
#define OFF_IP_DST_IP    (ETH_HEADER_LEN + 16)

// ICMP 头 (ETH + IP)
#define OFF_ICMP_TYPE     (ETH_HEADER_LEN + IP_HEADER_LEN + 0)
#define OFF_ICMP_CODE     (ETH_HEADER_LEN + IP_HEADER_LEN + 1)
#define OFF_ICMP_CHECKSUM (ETH_HEADER_LEN + IP_HEADER_LEN + 2)

// ARP 体 (ETH + 14)
#define OFF_ARP_HTYPE      14
#define OFF_ARP_PTYPE      16
#define OFF_ARP_HLEN       18
#define OFF_ARP_PLEN       19
#define OFF_ARP_OPCODE     20
#define OFF_ARP_SENDER_MAC 22
#define OFF_ARP_SENDER_IP  28
#define OFF_ARP_TARGET_MAC 32
#define OFF_ARP_TARGET_IP  38

#endif
