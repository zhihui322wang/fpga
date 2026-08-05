#include "inc/lcpu_general.h"
#include "inc/comlib.h"
#include "inc/ip.h"
#include "inc/tcp.h"

uint16 tcp_src_port = 0;
uint16 tcp_dst_port = 0;
uint32 tcp_seq      = 0;
uint32 tcp_ack      = 0;
uint8  tcp_flags    = 0;
uint16 tcp_window   = 0;
uint16 tcp_data_len = 0;

tcp_conn_t conn_table[MAX_TCP_CONN];

// TX FIFO 写入辅助函数
static void tcp_wr16(uint32 addr, uint16 val) {
    LCPU_WR_BYTE(addr,     (val >> 8) & 0xFF);
    LCPU_WR_BYTE(addr + 1, val & 0xFF);
}

static void tcp_wr32(uint32 addr, uint32 val) {
    LCPU_WR_BYTE(addr,     (val >> 24) & 0xFF);
    LCPU_WR_BYTE(addr + 1, (val >> 16) & 0xFF);
    LCPU_WR_BYTE(addr + 2, (val >> 8)  & 0xFF);
    LCPU_WR_BYTE(addr + 3, val & 0xFF);
}

// RX FIFO 读取辅助函数
static uint16 tcp_rd16(void) {
    uint16 val = (uint16)LCPU_RD_DATA8() << 8;
    LCPU_RD_INC_ADDR();
    val |= LCPU_RD_DATA8();
    LCPU_RD_INC_ADDR();
    return val;
}

static uint32 tcp_rd32(void) {
    uint32 val = 0;
    int i;
    for (i = 0; i < 4; i++) {
        val = (val << 8) | (LCPU_RD_DATA8() & 0xFFu);
        LCPU_RD_INC_ADDR();
    }
    return val;
}

// 连接池管理
void tcp_init(void) {
    int i;
    tcp_src_port = 0;
    tcp_dst_port = 0;
    tcp_seq      = 0;
    tcp_ack      = 0;
    tcp_flags    = 0;
    tcp_window   = 0;
    tcp_data_len = 0;

    for (i = 0; i < MAX_TCP_CONN; i++) {
        tcp_free_slot(i);
    }
}

int tcp_find_conn(uint32 ip, uint16 port) {
    int i;
    for (i = 0; i < MAX_TCP_CONN; i++) {
        if (conn_table[i].state != TCP_STATE_CLOSED &&
            conn_table[i].remote_ip == ip &&
            conn_table[i].remote_port == port) {
            return i;
        }
    }
    return -1;
}

int tcp_alloc_slot(void) {
    int i;
    for (i = 0; i < MAX_TCP_CONN; i++) {
        if (conn_table[i].state == TCP_STATE_CLOSED) {
            return i;
        }
    }
    return -1;
}

void tcp_free_slot(int slot) {
    if (slot < 0 || slot >= MAX_TCP_CONN) return;

    conn_table[slot].state       = TCP_STATE_CLOSED;
    conn_table[slot].remote_ip   = 0;
    conn_table[slot].remote_port = 0;
    conn_table[slot].local_seq   = 0x10000000;
    conn_table[slot].remote_seq  = 0;
    conn_table[slot].remote_ack  = 0;
    conn_table[slot].retry_count = 0;
    conn_table[slot].timeout     = 0;
}

// TCP 首部解析
int tcp_parse_header(void) {
    LCPU_RD_SET_ADDR(OFF_TCP_SRC_PORT);
    tcp_src_port = tcp_rd16();
    tcp_dst_port = tcp_rd16();

    tcp_seq = tcp_rd32();
    tcp_ack = tcp_rd32();

    LCPU_RD_SET_ADDR(OFF_TCP_DATA_OFS);
    uint8 data_ofs_raw = LCPU_RD_DATA8();
    uint8 tcp_hdr_len  = ((data_ofs_raw >> 4) & 0x0F) * 4;

    LCPU_RD_SET_ADDR(OFF_TCP_FLAGS);
    tcp_flags = LCPU_RD_DATA8();

    LCPU_RD_SET_ADDR(OFF_TCP_WINDOW);
    tcp_window = tcp_rd16();

    if (ip_total_len >= (ip_header_len + tcp_hdr_len)) {
        tcp_data_len = ip_total_len - ip_header_len - tcp_hdr_len;
    } else {
        tcp_data_len = 0;
    }

    return tcp_find_conn(src_ip, tcp_src_port);
}

// TCP 校验和, 基于寄存器参数, 不读 FIFO
uint16 tcp_calc_checksum(uint32 src_i, uint32 dst_i, uint16 src_p,
                         uint16 dst_p, uint32 seq, uint32 ack,
                         uint8 flags, uint16 win, uint16 payload_len) {
    uint32 sum = 0;
    uint16 tcp_tot_len = 20 + payload_len;

    // 伪首部: SrcIP + DstIP + Zero + Proto + TCP_Length
    sum = cks_sum_cal((src_i >> 16) & 0xFFFF, src_i & 0xFFFF, sum);
    sum = cks_sum_cal((dst_i >> 16) & 0xFFFF, dst_i & 0xFFFF, sum);
    sum = cks_sum_cal(0x00, IP_PROTOCOL_TCP, sum);
    sum = cks_sum_cal((tcp_tot_len >> 8) & 0xFF, tcp_tot_len & 0xFF, sum);

    // TCP 头 20 字节逐字段累加
    sum = cks_sum_cal((src_p >> 8) & 0xFF, src_p & 0xFF, sum);
    sum = cks_sum_cal((dst_p >> 8) & 0xFF, dst_p & 0xFF, sum);
    sum = cks_sum_cal((seq >> 24) & 0xFF, (seq >> 16) & 0xFF, sum);
    sum = cks_sum_cal((seq >> 8) & 0xFF, seq & 0xFF, sum);
    sum = cks_sum_cal((ack >> 24) & 0xFF, (ack >> 16) & 0xFF, sum);
    sum = cks_sum_cal((ack >> 8) & 0xFF, ack & 0xFF, sum);
    sum = cks_sum_cal(0x50, flags, sum);
    sum = cks_sum_cal((win >> 8) & 0xFF, win & 0xFF, sum);
    sum = cks_sum_cal(0, 0, sum);

    return (uint16)(~sum);
}

// SYN+ACK 报文构造与发送
void tcp_send_syn_ack(int slot) {
    uint16 ip_tot = ip_header_len + tcp_header_len;
    uint16 tx_len = eth_header_len + ip_tot;
    uint32 tcp_start = eth_header_len + ip_header_len;
    uint32 i;

    if (tx_len < 64) tx_len = 64;

    ip_header_update(conn_table[slot].remote_ip, ip_tot);

    uint16 csum = tcp_calc_checksum(
        Local_IP_ADDR,
        conn_table[slot].remote_ip,
        HTTP_PORT,
        conn_table[slot].remote_port,
        conn_table[slot].local_seq,
        conn_table[slot].remote_seq + 1,
        TCP_FLAG_SYN | TCP_FLAG_ACK,
        1460,
        0
    );

    tcp_wr16(tcp_start + 0,  HTTP_PORT);
    tcp_wr16(tcp_start + 2,  conn_table[slot].remote_port);
    tcp_wr32(tcp_start + 4,  conn_table[slot].local_seq);
    tcp_wr32(tcp_start + 8,  conn_table[slot].remote_seq + 1);
    LCPU_WR_BYTE(tcp_start + 12, 0x50);
    LCPU_WR_BYTE(tcp_start + 13, TCP_FLAG_SYN | TCP_FLAG_ACK);
    tcp_wr16(tcp_start + 14, 1460);
    tcp_wr16(tcp_start + 16, csum);
    tcp_wr16(tcp_start + 18, 0x0000);

    for (i = 54; i < tx_len; i++) {
        LCPU_WR_BYTE(i, 0);
    }
    LCPU_WR_PUSH_PACKET(tx_len);
}

// RST 报文
void tcp_send_rst(uint32 dst_ip, uint16 dst_p, uint16 src_p, uint32 seq) {
    uint16 ip_tot = ip_header_len + tcp_header_len;
    uint16 tx_len = eth_header_len + ip_tot;
    uint32 tcp_start = eth_header_len + ip_header_len;
    uint32 i;

    if (tx_len < 64) tx_len = 64;

    ip_header_update(dst_ip, ip_tot);

    uint16 csum = tcp_calc_checksum(
        Local_IP_ADDR, dst_ip, src_p, dst_p, 0, seq + 1,
        TCP_FLAG_RST | TCP_FLAG_ACK, 0, 0
    );

    tcp_wr16(tcp_start + 0,  src_p);
    tcp_wr16(tcp_start + 2,  dst_p);
    tcp_wr32(tcp_start + 4,  0);
    tcp_wr32(tcp_start + 8,  seq + 1);
    LCPU_WR_BYTE(tcp_start + 12, 0x50);
    LCPU_WR_BYTE(tcp_start + 13, TCP_FLAG_RST | TCP_FLAG_ACK);
    tcp_wr16(tcp_start + 14, 0);
    tcp_wr16(tcp_start + 16, csum);
    tcp_wr16(tcp_start + 18, 0x0000);

    for (i = 54; i < tx_len; i++) {
        LCPU_WR_BYTE(i, 0);
    }
    LCPU_WR_PUSH_PACKET(tx_len);
}

// TCP 状态机入口
uint16 tcp_proc(void) {
    int slot = tcp_parse_header();

    if (tcp_dst_port != HTTP_PORT) {
        return NO_PROC;
    }

    if (slot < 0) {
        if (tcp_flags & TCP_FLAG_SYN) {
            return tcp_handle_listen();
        } else {
            tcp_send_rst(src_ip, tcp_src_port, tcp_dst_port, tcp_seq);
            return TCP_PROC;
        }
    }

    switch (conn_table[slot].state) {
        case TCP_STATE_SYN_RECEIVED:
            return tcp_handle_syn_received(slot);
        default:
            break;
    }

    return NO_PROC;
}

// 收到 SYN, 分配槽位, 回复 SYN+ACK
uint16 tcp_handle_listen(void) {
    int slot = tcp_alloc_slot();
    if (slot < 0) return NO_PROC;

    conn_table[slot].state       = TCP_STATE_SYN_RECEIVED;
    conn_table[slot].remote_ip   = src_ip;
    conn_table[slot].remote_port = tcp_src_port;
    conn_table[slot].remote_seq  = tcp_seq;
    conn_table[slot].local_seq   = 0x10000000;
    conn_table[slot].timeout     = LCPU_LOCAL_TIME_L() + TCP_SYN_RETRY_TICKS;

    tcp_send_syn_ack(slot);
    return TCP_PROC;
}

// 收到 ACK, 验证通过 → ESTABLISHED
uint16 tcp_handle_syn_received(int slot) {
    if (tcp_flags & TCP_FLAG_ACK) {
        conn_table[slot].state      = TCP_STATE_ESTABLISHED;
        conn_table[slot].local_seq += 1;
        conn_table[slot].remote_ack = tcp_ack;
        return TCP_PROC;
    }
    return NO_PROC;
}
