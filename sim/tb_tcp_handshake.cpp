// TCP three-way handshake simulation - Verilator C++ testbench
#include "Vtb_tcp_handshake.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstdint>

Vtb_tcp_handshake *top;
VerilatedVcdC *tfp;
vluint64_t sim_time = 0;

// Clock: 50MHz = 20ns period = 10ns half-period
void tick() {
    top->clk_50m_in = !top->clk_50m_in;
    top->eval();
    if (tfp) tfp->dump(sim_time);
    sim_time += 10;
}

// TCP SYN packet (54 bytes, no options)
uint8_t syn_pkt[] = {
    0x00,0x00,0x01,0x02,0x04,0x05,  // dst MAC = FPGA
    0x9c,0x2d,0xcd,0xac,0x8f,0xa4,  // src MAC = PC
    0x08,0x00,                        // EtherType IPv4
    0x45,0x00, 0x00,0x28, 0x00,0x01, 0x40,0x00, 0x40,0x06,
    0x00,0x00,
    0xa9,0xfe,0x5c,0x15,              // src IP = 169.254.92.21
    0xa9,0xfe,0x01,0x01,              // dst IP = 169.254.1.1
    0x30,0x39,  // src port 12345
    0x00,0x07,  // dst port 7
    0x05,0x85,0x2e,0xa5,              // seq
    0x00,0x00,0x00,0x00,              // ack
    0x50, 0x02,                        // dataOfs=5, flags=SYN
    0xfa,0xf0,  // window
    0x00,0x00,  // checksum
    0x00,0x00   // urg
};
const int PKT_LEN = 54;

// Access DUT mac_rx signals via public-flat-rw hierarchy
#define MAC_RX_SOP  top->tb_tcp_handshake__DOT__u_dut__DOT__mac_rx_sop
#define MAC_RX_EN   top->tb_tcp_handshake__DOT__u_dut__DOT__mac_rx_en
#define MAC_RX_DATA top->tb_tcp_handshake__DOT__u_dut__DOT__mac_rx_data
#define MAC_RX_EOP  top->tb_tcp_handshake__DOT__u_dut__DOT__mac_rx_eop

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vtb_tcp_handshake;
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("tb_tcp_handshake.vcd");

    top->clk_50m_in = 0;
    top->reset_l = 0;
    top->rgmii_rxc = 0;
    top->rgmii_rxd = 0;
    top->rgmii_rx_ctl = 0;
    top->uart_rx = 1;

    // Reset
    for (int i=0; i<20; i++) { tick(); tick(); }
    top->reset_l = 1;

    printf("[SIM] Waiting for firmware load...\n");
    for (int i=0; i<200000; i++) { tick(); tick(); }
    printf("[SIM] Injecting TCP SYN packet (%d bytes)\n", PKT_LEN);

    // Force mac_rx to inject SYN packet
    MAC_RX_SOP = 1;
    MAC_RX_EN  = 1;
    MAC_RX_DATA = syn_pkt[0];
    MAC_RX_EOP = 0;
    tick(); tick();
    MAC_RX_SOP = 0;

    for (int i=1; i<PKT_LEN-1; i++) {
        MAC_RX_DATA = syn_pkt[i];
        tick(); tick();
    }
    MAC_RX_DATA = syn_pkt[PKT_LEN-1];
    MAC_RX_EOP = 1;
    tick(); tick();
    MAC_RX_EN  = 0;
    MAC_RX_EOP = 0;
    printf("[SIM] SYN injected\n");

    // Wait for SYN+ACK response
    printf("[SIM] Waiting for SYN+ACK...\n");
    bool tx_started = false;
    int tx_bytes[200], tx_count = 0;
    vluint64_t tx_start_time = 0;

    for (int i=0; i<5000000; i++) {
        tick(); tick();
        if (!tx_started && top->mac_tx_sop && top->mac_tx_en) {
            tx_started = true;
            tx_start_time = sim_time;
            tx_bytes[tx_count++] = top->mac_tx_data;
            continue;
        }
        if (tx_started && tx_count < 200) {
            if (top->mac_tx_en)
                tx_bytes[tx_count++] = top->mac_tx_data;
            if (top->mac_tx_eop) {
                printf("[SIM] TX complete: %d bytes (t=%lu ns)\n", tx_count, sim_time);
                if (tx_count >= 54) {
                    int flags    = tx_bytes[47];
                    int src_port = (tx_bytes[34]<<8)|tx_bytes[35];
                    int dst_port = (tx_bytes[36]<<8)|tx_bytes[37];
                    printf("  ETH dst: %02x:%02x:%02x:%02x:%02x:%02x\n",
                        tx_bytes[0],tx_bytes[1],tx_bytes[2],tx_bytes[3],tx_bytes[4],tx_bytes[5]);
                    printf("  TCP flags: 0x%02x (expected 0x12)\n", flags);
                    printf("  TCP src=%d (expect 7) dst=%d (expect 12345)\n", src_port, dst_port);

                    // Verify checksum
                    uint32_t cs=0;
                    cs += 0xa9fe; cs += 0x0101;   // src FPGA
                    cs += 0xa9fe; cs += 0x5c15;   // dst PC
                    cs += 0x0006; cs += 20;        // proto+len
                    for (int j=34; j<tx_count; j+=2)
                        cs += (tx_bytes[j]<<8)|tx_bytes[j+1];
                    while (cs>>16) cs=(cs&0xFFFF)+(cs>>16);
                    uint16_t calc=(uint16_t)(~cs);
                    uint16_t pkt_cs=(tx_bytes[50]<<8)|tx_bytes[51];

                    bool ok = true;
                    if (flags != 0x12) { printf("  FAIL: flags 0x%02x\n", flags); ok=false; }
                    if (src_port != 7) { printf("  FAIL: src_port %d\n", src_port); ok=false; }
                    if (dst_port != 12345) { printf("  FAIL: dst_port %d\n", dst_port); ok=false; }
                    if (calc == pkt_cs)
                        printf("  Checksum: 0x%04x PASS\n", calc);
                    else
                        { printf("  FAIL: checksum calc=0x%04x pkt=0x%04x\n", calc, pkt_cs); ok=false; }
                    printf("  === %s ===\n", ok?"PASS":"FAIL");
                }
                break;
            }
            continue;
        }
    }
    if (!tx_started) printf("[SIM] TIMEOUT: no SYN+ACK response\n");

    tfp->close();
    top->final();
    delete top;
    return 0;
}
