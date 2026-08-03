// ip.c — IPv4 层: 校验头 + 协议分派

#include "lcpu_general.h"
#include "ip.h"
#include "icmp.h"
#include <string.h>

// 16 位反码求和, 进位回卷
uint16_t ip_calc_checksum(const uint8_t *data, uint16_t byte_len) {
    if (byte_len == 0) return 0xFFFF;

    uint32_t sum = 0;
    uint16_t word_cnt = byte_len / 2;

    for (uint16_t i = 0; i < word_cnt; i++) {
        uint16_t w = (data[i*2] << 8) | data[i*2 + 1];
        sum += w;
        while (sum >> 16)
            sum = (sum & 0xFFFF) + (sum >> 16);
    }

    // 奇数长度尾部补零
    if (byte_len & 1) {
        sum += (uint16_t)(data[byte_len - 1] << 8);
        while (sum >> 16)
            sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return (uint16_t)(~sum);
}

// 交换 SrcIP ↔ DstIP, 清零 checksum 重算
void ip_swap_src_dst(uint8_t *frame) {
    uint8_t tmp[4];
    memcpy(tmp, &frame[OFF_IP_SRC_IP], 4);
    memcpy(&frame[OFF_IP_SRC_IP], &frame[OFF_IP_DST_IP], 4);
    memcpy(&frame[OFF_IP_DST_IP], tmp, 4);

    frame[OFF_IP_CHECKSUM]     = 0;
    frame[OFF_IP_CHECKSUM + 1] = 0;
    uint16_t ck = ip_calc_checksum(&frame[OFF_IP_VER_IHL], IP_HEADER_LEN);
    frame[OFF_IP_CHECKSUM]     = (ck >> 8) & 0xFF;
    frame[OFF_IP_CHECKSUM + 1] =  ck       & 0xFF;
}

// IP 包主处理
int ip_process(uint8_t *frame, uint16_t len) {
    if (len < ETH_HEADER_LEN + IP_HEADER_LEN)
        return 0;

    // 只支持 IPv4, 标准 20 字节头
    uint8_t ver_ihl = frame[OFF_IP_VER_IHL];
    if (((ver_ihl >> 4) != 4) || ((ver_ihl & 0x0F) != 5))
        return 0;

    // 校验 IP 头 (用副本, 不污染帧)
    uint8_t hdr[IP_HEADER_LEN];
    memcpy(hdr, &frame[OFF_IP_VER_IHL], IP_HEADER_LEN);
    uint16_t orig_cs = (hdr[OFF_IP_CHECKSUM - OFF_IP_VER_IHL] << 8)
                     |  hdr[OFF_IP_CHECKSUM - OFF_IP_VER_IHL + 1];
    hdr[OFF_IP_CHECKSUM - OFF_IP_VER_IHL]     = 0;
    hdr[OFF_IP_CHECKSUM - OFF_IP_VER_IHL + 1] = 0;
    uint16_t calc_cs = ip_calc_checksum(hdr, IP_HEADER_LEN);

    uint32_t cs_sum = (uint32_t)orig_cs + (uint32_t)calc_cs;
    while (cs_sum >> 16)
        cs_sum = (cs_sum & 0xFFFF) + (cs_sum >> 16);
    if ((uint16_t)cs_sum != 0xFFFF)
        return 0;

    // 目的 IP 不是本机 → 丢弃
    uint32_t dst = ((uint32_t)frame[OFF_IP_DST_IP]   << 24)
                 | ((uint32_t)frame[OFF_IP_DST_IP+1] << 16)
                 | ((uint32_t)frame[OFF_IP_DST_IP+2] <<  8)
                 |  (uint32_t)frame[OFF_IP_DST_IP+3];
    if (dst != LOCAL_IP_ADDR)
        return 0;

    // 按协议号分派
    if (frame[OFF_IP_PROTO] == IP_PROTO_ICMP)
        return icmp_process(frame, len);

    return 0;
}
