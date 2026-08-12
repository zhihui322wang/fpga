# =============================================================================
# fpga_ila RTL files — RiscV_WebSoC_3
# IP source: fpga_ila-snapshot-20260812133532 (flat rtl/ structure)
#
# Usage:
#   Set FPGA_ILA_HOME to the IP root before building:
#     FPGA_ILA_HOME=/home/zhihuiw/fpga_work/ip_copy
#
#   In Vivado build.tcl:
#     set fpga_ila_home /home/zhihuiw/fpga_work/ip_copy/fpga_ila-snapshot-20260812133532
#     read_verilog -sv [glob $fpga_ila_home/rtl/*.v]
#     add_files -fileset utils_1 [glob $fpga_ila_home/rtl/*.vh]
#
#   In iverilog:
#     iverilog -I${FPGA_ILA_HOME}/rtl -F fpga_ila_files.f ...
# =============================================================================

# ---- Core (soft_ila_top + ila_ela) ----
${FPGA_ILA_HOME}/rtl/soft_ila_top.v
${FPGA_ILA_HOME}/rtl/ila_ela.v
${FPGA_ILA_HOME}/rtl/trig_compare.v
${FPGA_ILA_HOME}/rtl/ila_async_fifo.v

# ---- Hub + Multi-transport ----
${FPGA_ILA_HOME}/rtl/ila_hub_top.v
${FPGA_ILA_HOME}/rtl/ila_hub.v
${FPGA_ILA_HOME}/rtl/ila_transport_mux.v

# ---- UART transport (TRANSPORT_EN[0]) ----
${FPGA_ILA_HOME}/rtl/uart_backend.v
${FPGA_ILA_HOME}/rtl/uart_rx_ila.v
${FPGA_ILA_HOME}/rtl/uart_tx_ila.v

# ---- ETH transport (TRANSPORT_EN[1]) — uncomment if needed ----
#${FPGA_ILA_HOME}/rtl/eth_backend.v
#${FPGA_ILA_HOME}/rtl/eth_rx.v
#${FPGA_ILA_HOME}/rtl/gmii_rx.v
#${FPGA_ILA_HOME}/rtl/gmii_tx.v
#${FPGA_ILA_HOME}/rtl/arp.v
#${FPGA_ILA_HOME}/rtl/ip_udp.v

# ---- Common headers (include path: -I${FPGA_ILA_HOME}/rtl) ----
${FPGA_ILA_HOME}/rtl/ila_pkg.vh
${FPGA_ILA_HOME}/rtl/ila_version.vh
${FPGA_ILA_HOME}/rtl/crc_func.vh
${FPGA_ILA_HOME}/rtl/ila_sync_fifo.v
