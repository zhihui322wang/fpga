// arp.c — ARP 协议: 收到 Request → 原地改包 → 发 Reply

#include "lcpu_general.h"
#include "arp.h"
#include "eth.h"
#include <string.h>

static arp_cache_t arp_cache;

void arp_init(void) {
    arp_cache.valid = false;
    arp_cache.ip = 0;
    memset(arp_cache.mac, 0, 6);
}

// 查缓存, 命中返回 1 并拷贝 MAC
int arp_get_mac(uint32_t ip, uint8_t *mac) {
    if (arp_cache.valid && arp_cache.ip == ip) {
        memcpy(mac, arp_cache.mac, 6);
        return 1;
    }
    return 0;
}

// 处理 ARP 帧, 请求 → 原地改包发送 Reply
int arp_process(uint8_t *frame, uint16_t len) {
    if (len < 42) return 0;

    // 只处理 ARP
    uint16_t eth_type = (frame[OFF_ETH_TYPE] << 8)
                      |  frame[OFF_ETH_TYPE + 1];
    if (eth_type != ETH_TYPE_ARP) return 0;

    // 校验: Ethernet + IPv4 + 6/4 地址长度
    if (frame[OFF_ARP_HTYPE]   != 0x00 || frame[OFF_ARP_HTYPE+1] != 0x01) return 0;
    if (frame[OFF_ARP_PTYPE]   != 0x08 || frame[OFF_ARP_PTYPE+1] != 0x00) return 0;
    if (frame[OFF_ARP_HLEN]    != 6    || frame[OFF_ARP_PLEN]    != 4)    return 0;

    // 只回 Request
    uint16_t opcode = (frame[OFF_ARP_OPCODE] << 8)
                    |  frame[OFF_ARP_OPCODE + 1];
    if (opcode != ARP_REQUEST) return 0;

    // 检查 Target IP 是不是本机
    uint32_t target_ip =
        ((uint32_t)frame[OFF_ARP_TARGET_IP]   << 24) |
        ((uint32_t)frame[OFF_ARP_TARGET_IP+1] << 16) |
        ((uint32_t)frame[OFF_ARP_TARGET_IP+2] <<  8) |
        (uint32_t)frame[OFF_ARP_TARGET_IP+3];
    if (target_ip != LOCAL_IP_ADDR) return 0;

    // 更新缓存
    uint32_t sender_ip =
        ((uint32_t)frame[OFF_ARP_SENDER_IP]   << 24) |
        ((uint32_t)frame[OFF_ARP_SENDER_IP+1] << 16) |
        ((uint32_t)frame[OFF_ARP_SENDER_IP+2] <<  8) |
        (uint32_t)frame[OFF_ARP_SENDER_IP+3];
    arp_cache.valid = true;
    arp_cache.ip = sender_ip;
    memcpy(arp_cache.mac, &frame[OFF_ARP_SENDER_MAC], 6);

    // 原地改包: 交换 MAC, 改 Opcode, 填本机信息
    memcpy(&frame[OFF_ETH_DST_MAC], &frame[OFF_ETH_SRC_MAC], 6);
    uint8_t my_mac[6];
    eth_get_mac(my_mac);
    memcpy(&frame[OFF_ETH_SRC_MAC], my_mac, 6);

    // Opcode ← Reply
    frame[OFF_ARP_OPCODE]     = 0x00;
    frame[OFF_ARP_OPCODE + 1] = ARP_REPLY & 0xFF;

    // Target = 请求方, Sender = 本机
    memcpy(&frame[OFF_ARP_TARGET_MAC], &frame[OFF_ARP_SENDER_MAC], 6);
    frame[OFF_ARP_TARGET_IP]   = (sender_ip >> 24) & 0xFF;
    frame[OFF_ARP_TARGET_IP+1] = (sender_ip >> 16) & 0xFF;
    frame[OFF_ARP_TARGET_IP+2] = (sender_ip >>  8) & 0xFF;
    frame[OFF_ARP_TARGET_IP+3] =  sender_ip        & 0xFF;

    memcpy(&frame[OFF_ARP_SENDER_MAC], my_mac, 6);
    frame[OFF_ARP_SENDER_IP]   = (LOCAL_IP_ADDR >> 24) & 0xFF;
    frame[OFF_ARP_SENDER_IP+1] = (LOCAL_IP_ADDR >> 16) & 0xFF;
    frame[OFF_ARP_SENDER_IP+2] = (LOCAL_IP_ADDR >>  8) & 0xFF;
    frame[OFF_ARP_SENDER_IP+3] =  LOCAL_IP_ADDR        & 0xFF;

    // 填充到 60 字节 (最小以太网帧)
    for (uint16_t i = 42; i < 60; i++)
        frame[i] = 0x00;

    eth_tx_frame(frame, 60);
    return 1;
}
