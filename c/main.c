#define SIM_FAST  // 仿真跳过延时, 上板注释此行

#include "inc/lcpu_general.h"
#include "inc/system.h"
#include "inc/eth.h"
#include "inc/arp.h"
#include "inc/ip.h"
#include "inc/icmp.h"
#include "inc/tcp.h"

__attribute__((naked, used, section(".text.bootloader")))
void reset_entry() {
    asm volatile(
        "la sp, _stack_top\n"
        "la t0, __bss_start\n"
        "la t1, __bss_end\n"
        "1:\n"
        "bgeu t0, t1, 2f\n"
        "sw zero, 0(t0)\n"
        "addi t0, t0, 4\n"
        "j 1b\n"
        "2:\n"
        "j program_main\n"
    );
}

int main() {
    program_main();
    return 0;
}

void program_main() {
    LCPU_SET_LED(0x0F);
#ifndef SIM_FAST
    volatile uint32 dly = 5000000;
    while (dly--) { asm volatile("nop"); }
#endif
    LCPU_SET_LED(0x00);

    tcp_init();

    uint32 led_val = 0x01;

    while (1) {
        // LED 心跳
        {
            static uint32 last_toggle = 0;
            uint32 now = LCPU_LOCAL_TIME_L();
            if ((now - last_toggle) >= 50000000UL) {
                last_toggle = now;
                LCPU_SET_LED(led_val);
                led_val = (led_val == 0x08) ? 0x01 : (led_val << 1);
            }
        }

        if (LCPU_RD_EMPTY())
            continue;

        LCPU_RD_START_PACKET();
        uint32 len = LCPU_RD_PKT_LEN();
        if (len == 0 || len > 2048) {
            LCPU_RD_START_PACKET();
            continue;
        }

        uint16 ptype = eth_proc();

        if (ptype == ARP_PROC) {
            arp_reply();
        } else if (ptype == IP_PROC) {
            uint16 iptype = ip_proc();
            if (iptype == ICMP_PROC) {
                icmp_reply();
            } else if (iptype == TCP_PROC) {
                tcp_proc();
            }
        }

        _RD(1) = 1;
    }
}
