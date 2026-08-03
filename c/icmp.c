// icmp.c — ICMP Echo Reply, 零拷贝原地改包

#include "lcpu_general.h"
#include "icmp.h"
#include "ip.h"
#include "eth.h"
#include <string.h>

int icmp_process(uint8_t *frame, uint16_t len) {
    if (len < ETH_HEADER_LEN + IP_HEADER_LEN + ICMP_HEADER_LEN)
        return 0;

    // 只回 Echo Request
    if (frame[OFF_ICMP_TYPE] != ICMP_ECHO_REQ)
        return 0;

    // 校验 ICMP 校验和
    uint16_t icmp_len = len - OFF_ICMP_TYPE;
    uint16_t orig_cs  = (frame[OFF_ICMP_CHECKSUM] << 8)
                      |  frame[OFF_ICMP_CHECKSUM + 1];

    frame[OFF_ICMP_CHECKSUM]     = 0;
    frame[OFF_ICMP_CHECKSUM + 1] = 0;
    uint16_t calc_cs = ip_calc_checksum(&frame[OFF_ICMP_TYPE], icmp_len);

    uint32_t cs_sum = (uint32_t)orig_cs + (uint32_t)calc_cs;
    while (cs_sum >> 16)
        cs_sum = (cs_sum & 0xFFFF) + (cs_sum >> 16);
    if ((uint16_t)cs_sum != 0xFFFF) {
        // 校验失败, 恢复原值避免污染
        frame[OFF_ICMP_CHECKSUM]     = (orig_cs >> 8) & 0xFF;
        frame[OFF_ICMP_CHECKSUM + 1] =  orig_cs       & 0xFF;
        return 0;
    }

    // 原地改包: 交换 MAC + 交换 IP + Type→Reply + 重算 ICMP 校验和
    memcpy(&frame[OFF_ETH_DST_MAC], &frame[OFF_ETH_SRC_MAC], 6);
    uint8_t my_mac[6];
    eth_get_mac(my_mac);
    memcpy(&frame[OFF_ETH_SRC_MAC], my_mac, 6);

    ip_swap_src_dst(frame);

    frame[OFF_ICMP_TYPE] = ICMP_ECHO_REPLY;
    frame[OFF_ICMP_CODE] = 0;

    uint16_t new_cs = ip_calc_checksum(&frame[OFF_ICMP_TYPE], icmp_len);
    frame[OFF_ICMP_CHECKSUM]     = (new_cs >> 8) & 0xFF;
    frame[OFF_ICMP_CHECKSUM + 1] =  new_cs       & 0xFF;

    // 填充最小帧
    if (len < 60) {
        for (uint16_t i = len; i < 60; i++)
            frame[i] = 0x00;
        len = 60;
    }

    eth_tx_frame(frame, len);
    return 1;
}
