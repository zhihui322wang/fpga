// icmp.h — ICMP Echo Reply 处理

#ifndef _ICMP_H_
#define _ICMP_H_

#include <stdint.h>

#define ICMP_ECHO_REPLY   0x00u
#define ICMP_ECHO_REQUEST 0x08u

#pragma pack(push, 1)

// ICMP 以太网头
typedef struct {
    uint8_t  dst_mac[6];
    uint8_t  src_mac[6];
    uint16_t ether_type; // 0x0800
} icmp_eth_header_t;

// IPv4 头 (20 字节, IHL=5)
typedef struct {
    uint8_t  ver_ihl;
    uint8_t  dscp_ecn;
    uint16_t total_len;
    uint16_t identification;
    uint16_t flags_frag_offset;
    uint8_t  ttl;
    uint8_t  protocol;   // 0x01
    uint16_t hdr_checksum;
    uint8_t  src_ip[4];
    uint8_t  dst_ip[4];
} icmp_ipv4_header_t;

// ICMP Echo 头 (8 字节)
typedef struct {
    uint8_t  type;       // 0x08 req, 0x00 reply
    uint8_t  code;
    uint16_t checksum;
    uint16_t identifier;
    uint16_t sequence;
} icmp_echo_header_t;

// 完整 ICMP Echo 帧
typedef struct {
    icmp_eth_header_t  eth;
    icmp_ipv4_header_t ip;
    icmp_echo_header_t icmp;
} icmp_echo_frame_t;

#pragma pack(pop)

uint16 icmp_body_checksum(uint16 icmp_req_len, uint16 checksum_ini);
void icmp_reply(void);

#endif // _ICMP_H_
