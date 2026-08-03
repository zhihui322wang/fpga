// main.c — RISC-V 上电入口 + 主循环

#define SIM_FAST  // 仿真跳过延时, 上板注释掉

#include "lcpu_general.h"
#include "eth.h"
#include "arp.h"
#include "ip.h"
#include <stdint.h>

// ── 复位入口, 上电 PC=0 ──
__attribute__((naked, used, section(".text.bootloader")))
void reset_entry() {
    // sp=0 上电默认, 函数调用前必须设栈, 否则写 0xFFFFFFFC 跑飞
    asm volatile(
        "la sp, _stack_top\n"
        // .bss 清零
        "la t0, __bss_start\n"
        "la t1, __bss_end\n"
        "1:\n"
        "bgeu t0, t1, 2f\n"
        "sw zero, 0(t0)\n"
        "addi t0, t0, 4\n"
        "j 1b\n"
        "2:\n"
        "j main\n"
    );
}

// ── 静态缓冲区, 全程复用 ──
static uint8_t  rx_buffer[ETH_MAX_FRAME_LEN];

// ── 50MHz 时序常量 ──
#define CPU_FREQ_HZ            50000000UL
#define LED_FLOW_INTERVAL_TICKS 6250000UL   // 125ms
#define LED_BLINK_STEP_TICKS    2500000UL   // 50ms

// ── 上电自检延时 ──
static inline void delay_us(uint32_t n) {
#ifdef SIM_FAST
    (void)n;
#else
    volatile uint32_t cnt = n * 12;
    while (cnt--) __asm__ volatile("nop");
#endif
}

// ── LED 状态 ──
static uint32_t last_flow_ticks;
static uint8_t  current_led;
static uint8_t  led_blink_pending;
static uint32_t blink_start_ticks;
static uint8_t  blink_phase;

// ── LED 流水灯, 非阻塞, 主循环每圈调用 ──
static inline void led_flow_update(void) {
    uint32_t now = lcpu_local_time_l();

    // 网络包闪烁优先打断流水灯
    if (led_blink_pending) {
        switch (blink_phase) {
        case 0:
            LCPU_SET_LED(0x00);
            blink_start_ticks = now;
            blink_phase = 1;
            break;
        case 1:
            if (now - blink_start_ticks >= LED_BLINK_STEP_TICKS) {
                LCPU_SET_LED(1u << current_led);
                blink_start_ticks = now;
                blink_phase = 2;
            }
            break;
        case 2:
            if (now - blink_start_ticks >= LED_BLINK_STEP_TICKS) {
                LCPU_SET_LED(0x00);
                blink_start_ticks = now;
                blink_phase = 3;
            }
            break;
        case 3:
            if (now - blink_start_ticks >= LED_BLINK_STEP_TICKS) {
                LCPU_SET_LED(1u << current_led);
                blink_start_ticks = now;
                blink_phase = 4;
            }
            break;
        case 4:
            if (now - blink_start_ticks >= LED_BLINK_STEP_TICKS) {
                LCPU_SET_LED(0x00);
                led_blink_pending = 0;
                blink_phase = 0;
                last_flow_ticks = now;
            }
            break;
        default:
            led_blink_pending = 0;
            blink_phase = 0;
            break;
        }
        return;
    }

    // 常规流水: 4 路循环移位 (125ms/拍)
    if (now - last_flow_ticks >= LED_FLOW_INTERVAL_TICKS) {
        LCPU_SET_LED(0x00);
        current_led = (current_led + 1) & 0x03;
        LCPU_SET_LED(1u << current_led);
        last_flow_ticks = now;
    }
}

// ── 收到有效包时触发 LED 快闪 ──
static inline void trigger_network_blink(void) {
    if (!led_blink_pending) {
        led_blink_pending = 1;
        blink_phase = 0;
    }
}

// ── 主入口 ──
int main(void) {
    arp_init();
    uint16_t len;

    // 上电自检
    LCPU_SET_LED(0x0F);
    delay_us(100000);
    LCPU_SET_LED(0x00);
    delay_us(100000);

    last_flow_ticks = lcpu_local_time_l();

    for (;;) {
        led_flow_update();

        if (eth_rx_frame(rx_buffer, &len) != 0)
            continue;

        if (len > ETH_MAX_FRAME_LEN)
            continue;

        uint16_t eth_type = (rx_buffer[OFF_ETH_TYPE] << 8)
                          |  rx_buffer[OFF_ETH_TYPE + 1];

        if (eth_type == ETH_TYPE_ARP) {
            if (arp_process(rx_buffer, len))
                trigger_network_blink();
        } else if (eth_type == ETH_TYPE_IP) {
            if (ip_process(rx_buffer, len))
                trigger_network_blink();
        }
    }
}
