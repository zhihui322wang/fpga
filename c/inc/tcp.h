#ifndef __TCP_H__
#define __TCP_H__

#include "lcpu_general.h"

/* ============================================================================
 * 1. TCP 状态常量 (TCP States: Tasks 7, 10, 12)
 * ============================================================================ */
#define TCP_STATE_CLOSED        0
#define TCP_STATE_LISTEN        1
#define TCP_STATE_SYN_RECEIVED  2
#define TCP_STATE_ESTABLISHED   3
#define TCP_STATE_CLOSE_WAIT    4
#define TCP_STATE_LAST_ACK      5
#define TCP_STATE_TIME_WAIT     6

/* ============================================================================
 * 2. TCP Header 控制标志位 (Flags)
 * ============================================================================ */
#define TCP_FLAG_FIN            0x01
#define TCP_FLAG_SYN            0x02
#define TCP_FLAG_RST            0x04
#define TCP_FLAG_PSH            0x08
#define TCP_FLAG_ACK            0x10
#define TCP_FLAG_URG            0x20

/* ============================================================================
 * 3. 常量与超时重传配置 (Task 13)
 * ============================================================================ */
#define MAX_TCP_CONN            4
#define HTTP_PORT               80
#define TCP_SYN_MAX_RETRIES     3
#define TCP_SYN_RETRY_TICKS     50000000UL

/* ============================================================================
 * 4. TCP 连接表结构体定义 (Task 7a)
 * ============================================================================ */
typedef struct {
    uint8  state;         // 当前 TCP 状态
    uint32 remote_ip;     // 远端 IP 地址
    uint16 remote_port;   // 远端端口号
    uint32 local_seq;     // 本机发包序列号 (Sequence Number)
    uint32 remote_seq;    // 远端序列号
    uint32 remote_ack;    // 远端确认号
    uint8  retry_count;   // 超时重传计数
    uint32 timeout;       // 下次超时时间戳
} tcp_conn_t;

/* ============================================================================
 * 5. 全局解析变量与连接池声明 (extern)
 * ============================================================================ */
extern uint16 tcp_src_port;
extern uint16 tcp_dst_port;
extern uint32 tcp_seq;
extern uint32 tcp_ack;
extern uint8  tcp_flags;
extern uint16 tcp_window;
extern uint16 tcp_data_len;

extern tcp_conn_t conn_table[MAX_TCP_CONN];
extern int tcp_active_slot;

/* ============================================================================
 * 6. API 函数原型声明 (Tasks 7~13)
 * ============================================================================ */
void   tcp_init(void);
int    tcp_parse_header(void);
int    tcp_find_conn(uint32 ip, uint16 port);
int    tcp_alloc_slot(void);
void   tcp_free_slot(int slot);

/* 校验和计算 (Task 8a) */
uint16 tcp_calc_checksum(uint32 src_ip, uint32 dst_ip, uint16 src_port,
                         uint16 dst_port, uint32 seq, uint32 ack,
                         uint8 flags, uint16 window, uint16 payload_len);
uint16 tcp_calc_checksum_payload(uint32 src_ip, uint32 dst_ip, uint16 src_port,
                                 uint16 dst_port, uint32 seq, uint32 ack,
                                 uint8 flags, uint16 window,
                                 const uint8 *data, uint16 len);

/* 报文构建与发送 (Tasks 7c, 9a, 11, 12, 13) */
void   tcp_send_syn_ack(int slot);
void   tcp_send_ack(int slot);
void   tcp_send_fin_ack(int slot);
void   tcp_send_rst(uint32 dst_ip, uint16 dst_p, uint16 src_p, uint32 seq);
int    tcp_send_data(int slot, const uint8 *data, uint16 len, uint8 flags);
void   tcp_send_fin(int slot);

/* 状态机分发与处理 (Tasks 10, 11, 12) */
uint16 tcp_proc(void);
uint16 tcp_handle_listen(void);
uint16 tcp_handle_syn_received(int slot);
uint16 tcp_handle_established(int slot);
uint16 tcp_handle_close_wait(int slot);
uint16 tcp_handle_last_ack(int slot);

/* 定时器与超时重传 (Task 13) */
void   tcp_timer_check(void);

#endif /* __TCP_H__ */