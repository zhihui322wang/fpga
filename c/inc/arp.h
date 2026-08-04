// arp.h — ARP 缓存 + 处理接口

#ifndef _ARP_H_
#define _ARP_H_

#include <stdint.h>

#define ARP_ECHO_REPLY      0x0002u
#define ARP_OPCODE_REQUEST  0x0001u
#define ARP_OPCODE_REPLY    0x0002u

#pragma pack(push, 1)

typedef struct {
    uint8_t  dst_mac[6];
    uint8_t  src_mac[6];
    uint16_t ether_type; // 0x0806
} arp_eth_header_t;

typedef struct {
    uint16_t hardware_type; // 1 = Ethernet
    uint16_t protocol_type; // 0x0800
    uint8_t  hardware_len;  // 6
    uint8_t  protocol_len;  // 4
    uint16_t opcode;        // 1=req, 2=reply
    uint8_t  sender_mac[6];
    uint8_t  sender_ip[4];
    uint8_t  target_mac[6];
    uint8_t  target_ip[4];
} arp_payload_t;

typedef struct {
    arp_eth_header_t eth;
    arp_payload_t    arp;
} arp_frame_t;

#pragma pack(pop)

void arp_reply();

#endif // _ARP_H_
