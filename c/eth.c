// eth.c — 以太网帧解析 + MAC 头预写到 TX FIFO

#include "inc/lcpu_general.h"

// 预写完整的 14 字节以太网头到 TX FIFO (字节 0-13)
// 每个 PUSH 的包进独立 block, 故每发一个包都必须重写一次 eth 头
void eth_write_tx_header(void)
{
    uint32 fifo_data = 0;
    uint32 i;

    // 源 MAC (本机 MAC) → 字节 6-11
    LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 0, (Local_MAC_HIGH >> 24) & 0xFF);
    LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 1, (Local_MAC_HIGH >> 16) & 0xFF);
    LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 2, (Local_MAC_HIGH >> 8) & 0xFF);
    LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 3, (Local_MAC_HIGH >> 0) & 0xFF);
    LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 4, (Local_MAC_LOW >> 8) & 0xFF);
    LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 5, (Local_MAC_LOW >> 0) & 0xFF);

    // 目的 MAC = 接收包源 MAC → 字节 0-5
    for (i = 0; i < 6; i++) {
        LCPU_RD_SET_ADDR(OFF_ETH_SRC_MAC + i);
        fifo_data = LCPU_RD_DATA8();
        LCPU_WR_BYTE(OFF_ETH_DST_MAC + i, fifo_data);
    }

    // EtherType → 字节 12-13
    LCPU_RD_SET_ADDR(OFF_ETH_TYPE);
    fifo_data = LCPU_RD_DATA8();
    LCPU_WR_BYTE(OFF_ETH_TYPE, fifo_data);
    LCPU_RD_SET_ADDR(OFF_ETH_TYPE + 1);
    fifo_data = LCPU_RD_DATA8();
    LCPU_WR_BYTE(OFF_ETH_TYPE + 1, fifo_data);
}

uint16 eth_proc()
{
    uint32 fifo_data = 0;
    uint16 eth_type = 0;

    // 读 EtherType (字节 12-13)
    LCPU_RD_SET_ADDR(OFF_ETH_TYPE);
    fifo_data = LCPU_RD_DATA8();
    eth_type = (uint16)fifo_data << 8;
    LCPU_RD_SET_ADDR(OFF_ETH_TYPE + 1);
    fifo_data = LCPU_RD_DATA8();
    eth_type = eth_type | fifo_data;

    if (eth_type == ETH_TYPE_ARP) {
        return ARP_PROC;
    }
    else if (eth_type == ETH_TYPE_IP) {
        // 读目的 MAC 高 4 字节 (raddr 0→4)
        uint32 dst_mac_high = 0;
        LCPU_RD_SET_ADDR(OFF_ETH_DST_MAC);
        dst_mac_high  = (uint32)LCPU_RD_DATA8() << 24;
        LCPU_RD_INC_ADDR();
        dst_mac_high |= (uint32)LCPU_RD_DATA8() << 16;
        LCPU_RD_INC_ADDR();
        dst_mac_high |= (uint32)LCPU_RD_DATA8() << 8;
        LCPU_RD_INC_ADDR();
        dst_mac_high |= (uint32)LCPU_RD_DATA8();
        LCPU_RD_INC_ADDR();  // raddr now at 4

        // 读目的 MAC 低 2 字节 (raddr 4→6)
        uint32 dst_mac_low = 0;
        dst_mac_low  = (uint32)LCPU_RD_DATA8() << 8;
        LCPU_RD_INC_ADDR();
        dst_mac_low |= (uint32)LCPU_RD_DATA8();

        // MAC 不是本机也不是广播 → 丢弃
        if (dst_mac_high != Local_MAC_HIGH || dst_mac_low != (uint32)Local_MAC_LOW) {
            return NO_PROC;
        }

        // 预写以太网头 (后续 tcp_send_* 继续写 IP+TCP 头)
        eth_write_tx_header();

        return IP_PROC;
    }
    else {
        return NO_PROC;
    }
}
