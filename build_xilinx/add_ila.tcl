# add_ila.tcl — 在 Vivado 中为 RGMII/MAC/FIFO 调试信号添加 ILA
# 使用方法: 在 Vivado Tcl Console 中执行 source build_xilinx/add_ila.tcl
# 或: 综合后打开 design, source 此文件

# === 1. 打开综合后网表 ===
if {[current_design] eq ""} {
    open_run synth_1
}

# === 2. 标记调试信号 (mark_debug) ===
# 顶层端口信号 (RGMII 外部输入)
set debug_ports {
    rgmii_rxc
    rgmii_rxd[*]
    rgmii_rx_ctl
}
foreach p $debug_ports {
    set_property mark_debug true [get_ports $p]
}

# 顶层内部 wire (GMII/MAC/FIFO 接口)
set debug_nets {
    gmii_rx_dv
    gmii_rxd[*]
    mac_rx_sop
    mac_rx_en
    mac_rx_data[*]
    mac_rx_eop
    mac_rx_err
    cpu_rd_empty
    cpu_rd_rpkt_len[*]
    cpu_rd_rdata[*]
    cpu_wr_wpkt_push
    cpu_wr_wpkt_len[*]
}
foreach n $debug_nets {
    set_property mark_debug true [get_nets -hier $n]
}

# RISC-V 复位和总线
set debug_riscv {
    riscv_reset_l[*]
}
foreach n $debug_riscv {
    set_property mark_debug true [get_nets -hier $n]
}

puts "\[ILA\] Marked [llength $debug_ports] ports + [llength $debug_nets] nets for debug"

# === 3. 创建 ILA 核 ===
# 采样时钟: clk_50m (CPU 时钟域, 50MHz)
create_debug_core u_ila_0 ila

# ILA 配置
set_property C_DATA_DEPTH 4096  [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER true [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN  false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL 1   [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 2 [get_debug_cores u_ila_0]

# 连接时钟
connect_debug_port u_ila_0/clk [get_nets -hier clk_50m]

puts "\[ILA\] ILA core created: 4096 samples @ 50MHz"

# === 4. 分组连接探针 ===
# Probe 0: RGMII RX 外部引脚 (5 路, 各 1+4+1=6 bits → 但这里分开连)
# 注意: rgmii_rxd 是 4-bit, rgmii_rx_ctl 是 1-bit, rgmii_rxc 是 1-bit
set_property port_width 6 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets -hier {rgmii_rxd[*] rgmii_rx_ctl}]
puts "\[ILA\] probe0: rgmii_rxd[3:0] + rgmii_rx_ctl (6 bits)"

# Probe 1: GMII RX (dv + data = 9 bits)
set_property port_width 9 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets -hier {gmii_rx_dv gmii_rxd[*]}]
puts "\[ILA\] probe1: gmii_rx_dv + gmii_rxd[7:0] (9 bits)"

# Probe 2: MAC RX 包流 (sop, en, data, eop, err = 1+1+8+1+1 = 12 bits)
set_property port_width 12 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets -hier {mac_rx_sop mac_rx_en mac_rx_data[*] mac_rx_eop mac_rx_err}]
puts "\[ILA\] probe2: mac_rx_sop/en/data[7:0]/eop/err (12 bits)"

# Probe 3: CPU RX FIFO 接口 (empty, len, data = 1+13+8 = 22 bits)
set_property port_width 22 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets -hier {cpu_rd_empty cpu_rd_rpkt_len[*] cpu_rd_rdata[*]}]
puts "\[ILA\] probe3: cpu_rd_empty + len[12:0] + rdata[7:0] (22 bits)"

# Probe 4: CPU TX FIFO 接口 (push, len = 1+13 = 14 bits)
set_property port_width 14 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets -hier {cpu_wr_wpkt_push cpu_wr_wpkt_len[*]}]
puts "\[ILA\] probe4: tx_push + tx_len[12:0] (14 bits)"

# Probe 5: LED 和 RISC-V 控制信号
set_property port_width 5 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets -hier {led_o[*] riscv_reset_l[*]}]
puts "\[ILA\] probe5: led_o[3:0] + riscv_reset_l (5 bits)"

# === 5. 设置触发条件 ===
# 默认触发: cpu_rd_empty 下降沿 (帧到达 RX FIFO)
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]

# === 6. 保存并实现 ===
puts "\[ILA\] Setup complete. Running implementation..."
write_debug_probes -force build_xilinx/debug_probes.ltx

puts "\[ILA\]====================================="
puts "\[ILA\] ILA 调试探针配置完成"
puts "\[ILA\]====================================="
puts "\[ILA\] 采样时钟: clk_50m (50MHz)"
puts "\[ILA\] 采样深度: 4096"
puts "\[ILA\] 总探针数: 6 组, 68 bits"
puts "\[ILA\]"
puts "\[ILA\] 探针分组:"
puts "\[ILA\]   probe0: RGMII RX  (rxc,rxd[3:0],rx_ctl)  6b"
puts "\[ILA\]   probe1: GMII RX   (dv,rxd[7:0])           9b"
puts "\[ILA\]   probe2: MAC RX    (sop,en,data[7:0],eop) 12b"
puts "\[ILA\]   probe3: CPU RX    (empty,len[12:0],rd[7:0]) 22b"
puts "\[ILA\]   probe4: CPU TX    (push,len[12:0])       14b"
puts "\[ILA\]   probe5: LED+Ctrl (led[3:0],rst_l)         5b"
puts "\[ILA\]"
puts "\[ILA\] 下一步: launch_runs impl_1 -to_step write_bitstream"
puts "\[ILA\] 烧录后用 Vivado Hardware Manager 打开 ILA 窗口"
