// ip.h — IPv4 校验和 + 地址交换 + 包处理

#ifndef _IP_H_
#define _IP_H_

#include <stdint.h>

uint16_t ip_calc_checksum(const uint8_t *data, uint16_t byte_len);
void     ip_swap_src_dst(uint8_t *frame);
int      ip_process(uint8_t *frame, uint16_t len);

#endif
