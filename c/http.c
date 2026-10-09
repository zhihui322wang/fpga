// http.c — 极简 HTTP 服务器: 解析 GET 请求, 返回 HTML 页面

#include "inc/http.h"
#include "inc/tcp.h"

static const char http_response[] =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/html; charset=UTF-8\r\n"
    "Connection: close\r\n"
    "\r\n"
    "<!DOCTYPE html><html><body>"
    "<h1>Hello from RISC-V WebSoC!</h1>"
    "<p>Running on XC7A35T FPGA with a RISC-V soft core.</p>"
    "</body></html>";

void http_proc(int slot_idx) {
    uint8 a, b, c;
    int is_get = 0;

    // 请求载荷仍在 RX FIFO 中 (零拷贝), 直接读前 3 字节判断是否 GET
    if (tcp_data_len >= 3) {
        LCPU_RD_SET_ADDR(OFF_TCP_PAYLOAD + 0);
        a = LCPU_RD_DATA8();
        LCPU_RD_SET_ADDR(OFF_TCP_PAYLOAD + 1);
        b = LCPU_RD_DATA8();
        LCPU_RD_SET_ADDR(OFF_TCP_PAYLOAD + 2);
        c = LCPU_RD_DATA8();
        if (a == 'G' && b == 'E' && c == 'T') {
            is_get = 1;
        }
    }

    if (is_get) {
        // FIN 与 DATA 合并到同一个包 (对齐参考工程 send_http_data),
        // 避免 DATA 与 FIN 背靠背两个包导致的丢包
        tcp_send_data(slot_idx, (const uint8 *)http_response,
                      sizeof(http_response) - 1,
                      TCP_FLAG_ACK | TCP_FLAG_PSH | TCP_FLAG_FIN);
    } else {
        // 非 GET 请求: 只回 FIN 关闭 (Connection: close)
        tcp_send_fin(slot_idx);
    }

    conn_table[slot_idx].state   = TCP_STATE_TIME_WAIT;
    conn_table[slot_idx].timeout = LCPU_LOCAL_TIME_L() + TCP_TIMEWAIT_TICKS;
}
