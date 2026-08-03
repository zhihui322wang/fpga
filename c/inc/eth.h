// eth.h — 以太网帧收发接口

#ifndef _ETH_H_
#define _ETH_H_
#include "lcpu_general.h"

int  eth_rx_frame(uint8_t *buf, uint16_t *len);
void eth_tx_frame(const uint8_t *buf, uint16_t len);
void eth_get_mac(uint8_t *mac);

#endif
