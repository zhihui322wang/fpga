#ifndef __TCP_H__
#define __TCP_H__

#include "lcpu_general.h"

// TCP 状态常量
#define TCP_STATE_CLOSED        0
#define TCP_STATE_LISTEN        1
#define TCP_STATE_SYN_RECEIVED  2
#define TCP_STATE_ESTABLISHED   3
#define TCP_STATE_CLOSE_WAIT    4
#define TCP_STATE_LAST_ACK      5
#define TCP_STATE_TIME_WAIT     6

// TCP Header Flags
#define TCP_FLAG_FIN            0x01
#define TCP_FLAG_SYN            0x02
#define TCP_FLAG_RST            0x04
#define TCP_FLAG_PSH            0x08
#define TCP_FLAG_ACK            0x10
#define TCP_FLAG_URG            0x20

// 连接表配置
#define MAX_TCP_CONN            4
#define TCP_SYN_MAX_RETRIES     3

// 连接表结构体
typedef struct {
    uint8  state;
    uint32 remote_ip;
    uint16 remote_port;
    uint32 local_seq;
    uint32 remote_seq;
    uint32 remote_ack;
    uint8  retry_count;
    uint32 timeout;
} tcp_conn_t;

// 全局解析变量 (extern)
extern uint16 tcp_src_port;
extern uint16 tcp_dst_port;
extern uint32 tcp_seq;
extern uint32 tcp_ack;
extern uint8  tcp_flags;
extern uint16 tcp_window;
extern uint16 tcp_data_len;

extern tcp_conn_t conn_table[MAX_TCP_CONN];

// API
void   tcp_init(void);
int    tcp_parse_header(void);
int    tcp_find_conn(uint32 ip, uint16 port);
int    tcp_alloc_slot(void);
void   tcp_free_slot(int slot);

uint16 tcp_calc_checksum(uint32 src_ip, uint32 dst_ip, uint16 src_port,
                         uint16 dst_port, uint32 seq, uint32 ack,
                         uint8 flags, uint16 window, uint16 payload_len);

void   tcp_send_syn_ack(int slot);
void   tcp_send_rst(uint32 dst_ip, uint16 dst_p, uint16 src_p, uint32 seq);

uint16 tcp_proc(void);
uint16 tcp_handle_listen(void);
uint16 tcp_handle_syn_received(int slot);

#endif /* __TCP_H__ */
