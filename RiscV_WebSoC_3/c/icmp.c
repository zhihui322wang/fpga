// icmp.c — ICMP Echo Reply, 零拷贝流水线处理

#include "inc/lcpu_general.h"
#include "inc/comlib.h"
#include "inc/ip.h"
#include "inc/icmp.h"

// ICMP 头字段偏移 (相对 icmp_start)
#define ICMP_OFS_TYPE       0
#define ICMP_OFS_CODE       1
#define ICMP_OFS_CHECKSUM   2
#define ICMP_OFS_IDENTIFIER 4
#define ICMP_OFS_SEQUENCE   6
#define ICMP_HEADER_LEN     8

// ICMP 体校验和: type+code+id+seq+payload, type 用 ECHO_REPLY(0)
uint16 icmp_body_checksum(uint16 icmp_req_len, uint16 checksum_ini) {
    uint16 icmp_start = eth_header_len + ip_header_len;
    uint16 icmp_checksum = checksum_ini;
    uint16 processed_len = 0;
    uint32 hi_byte = 0;
    uint32 fifo_data = 0;

    bool is_odd = false;
    if (icmp_req_len % 2) {
        is_odd = true;
        processed_len = icmp_req_len - 1;
    } else {
        is_odd = false;
        processed_len = icmp_req_len;
    }

    // 首字节: type=ECHO_REPLY(0), code=0
    icmp_checksum = cks_sum_cal(ICMP_ECHO_REPLY, 0, icmp_checksum);

    // 从 id/seq 开始累加 (跳过 type/code/checksum 4 字节)
    uint32 i = 0;
    for (i = icmp_start + ICMP_OFS_IDENTIFIER; i < icmp_start + processed_len; i++) {
        LCPU_RD_SET_ADDR(i);
        fifo_data = LCPU_RD_DATA8();
        if (i % 2 == 0) {
            hi_byte = fifo_data;
        } else {
            icmp_checksum = cks_sum_cal(hi_byte, fifo_data, icmp_checksum);
        }
    }
    if (is_odd) {
        LCPU_RD_SET_ADDR(icmp_start + processed_len);
        fifo_data = LCPU_RD_DATA8();
        icmp_checksum = cks_sum_cal(fifo_data, 0, icmp_checksum);
    }
    return ~icmp_checksum;
}

void icmp_reply() {
    uint16 icmp_start = eth_header_len + ip_header_len;
    uint16 icmp_req_len = 0;
    uint16 tx_pkt_len = 0;
    uint16 i = 0;

    icmp_req_len = ip_total_len - ip_header_len;
    tx_pkt_len = eth_header_len + ip_total_len + 4;
    if (tx_pkt_len < 64) tx_pkt_len = 64;

    // 先写 IP 头 (交换 src/dst, 重算 checksum)
    ip_header_update(src_ip, ip_total_len);

    // ICMP 头: type=Reply, code=0
    LCPU_WR_BYTE(icmp_start + ICMP_OFS_TYPE, ICMP_ECHO_REPLY);
    LCPU_WR_BYTE(icmp_start + ICMP_OFS_CODE, 0);

    // 复制 id + seq (4 字节)
    for (i = 0; i < 4; i++) {
        LCPU_RD_SET_ADDR(icmp_start + ICMP_OFS_IDENTIFIER + i);
        LCPU_WR_BYTE(icmp_start + ICMP_OFS_IDENTIFIER + i, LCPU_RD_DATA8());
    }

    // 复制 payload (跳过 8 字节 ICMP 头)
    for (i = icmp_start + ICMP_HEADER_LEN; i < icmp_start + icmp_req_len; i++) {
        LCPU_RD_SET_ADDR(i);
        LCPU_WR_BYTE(i, LCPU_RD_DATA8());
    }

    // 计算 ICMP 校验和并写入
    uint16 icmp_checksum = icmp_body_checksum(icmp_req_len, 0);
    for (i = 0; i < 2; i++) {
        LCPU_WR_BYTE(icmp_start + ICMP_OFS_CHECKSUM + i,
                     (icmp_checksum >> (8 - i * 8)) & 0xFF);
    }

    // 填充最小以太网帧
    for (i = eth_header_len + ip_total_len; i < tx_pkt_len - 4; i++) {
        LCPU_WR_BYTE(i, 0);
    }

    LCPU_WR_PUSH_PACKET(tx_pkt_len);
}
