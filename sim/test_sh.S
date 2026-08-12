# Minimal RISC-V test: two halfword stores to same word
# Replicates the firmware's tcp_src_port/tcp_dst_port write pattern
# Uses same register base (0x1000) and offsets (0x75a, 0x758) as firmware

    .section .text
    .global _start
_start:
    # ---- Write 0x1234 to upper halfword [0x175a] (same as tcp_src_port) ----
    lui  a2, 0x1              # a2 = 0x1000
    li   a6, 0x1234           # a6 = 0x1234 (4660)
    sh   a6, 0x75a(a2)        # [0x175a] = 0x1234 (wstrb should = 1100)

    # ---- Write 0x0050 to lower halfword [0x1758] (same as tcp_dst_port) ----
    lui  a1, 0x1              # a1 = 0x1000
    li   a5, 0x0050           # a5 = 0x0050 (80)
    sh   a5, 0x758(a1)        # [0x1758] = 0x0050 (wstrb should = 0011)

    # ---- Wait for writes to complete (5 nops = enough cycles) ----
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    # ---- Infinite loop ----
1:
    j 1b
