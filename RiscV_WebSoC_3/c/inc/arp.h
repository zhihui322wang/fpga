// arp.h — ARP 缓存 + 处理接口

#ifndef _ARP_H_
#define _ARP_H_
#include "lcpu_general.h"

typedef struct {
    bool     valid;
    uint32_t ip;
    uint8_t  mac[6];
} arp_cache_t;

void arp_init(void);
int  arp_get_mac(uint32_t ip, uint8_t *mac);
int  arp_process(uint8_t *frame, uint16_t len);

#endif
