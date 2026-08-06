# fpga_ila RTL 文件清单
# 使用方式: 设置 FPGA_ILA_HOME 环境变量后 -F fpga_ila_files.f

# === 公共（必需）===
${FPGA_ILA_HOME}/rtl/soft_ila_top_fcapz.v
${FPGA_ILA_HOME}/rtl/ila_hub_top.v
${FPGA_ILA_HOME}/rtl/ila_hub.v
${FPGA_ILA_HOME}/rtl/ila_transport_mux.v
${FPGA_ILA_HOME}/rtl/reg_bus_bridge.v
${FPGA_ILA_HOME}/rtl/ila_sync_fifo.v
${FPGA_ILA_HOME}/rtl/ila_pkg.vh
${FPGA_ILA_HOME}/rtl/crc16_func.vh
${FPGA_ILA_HOME}/rtl/ila_transport_if.vh

# === fcapz 核 ===
${FPGA_ILA_HOME}/rtl/fcapz/fcapz_ela.v
${FPGA_ILA_HOME}/rtl/fcapz/trig_compare.v
${FPGA_ILA_HOME}/rtl/fcapz/dpram.v
${FPGA_ILA_HOME}/rtl/fcapz/fcapz_core_manager.v
${FPGA_ILA_HOME}/rtl/fcapz/fcapz_async_fifo.v
${FPGA_ILA_HOME}/rtl/fcapz/reset_sync.v
${FPGA_ILA_HOME}/rtl/fcapz/dff_sync.v
${FPGA_ILA_HOME}/rtl/fcapz/dff_reg_sync.v
${FPGA_ILA_HOME}/rtl/fcapz/fcapz_version.vh

# === UART 传输 ===
${FPGA_ILA_HOME}/rtl/uart_backend.v
${FPGA_ILA_HOME}/rtl/uart_rx_ila.v
${FPGA_ILA_HOME}/rtl/uart_tx_ila.v
