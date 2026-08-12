#===== 输入时钟 50MHz =====
create_clock -period 20.000 -name clk_50m_in [get_ports clk_50m_in]

#===== RGMII RXC (来自 PHY, 125MHz, 异步) =====
create_clock -period 8.000 -name rgmii_rxc [get_ports rgmii_rxc]
set_false_path -from [get_clocks rgmii_rxc] -to [all_clocks]
set_false_path -to   [get_clocks rgmii_rxc] -from [all_clocks]

#===== MMCM 输出时钟组 — 不同频率时钟之间为异步关系 =====
# clk_125m_unbuf     : 125MHz, GMII/MAC 主时钟
# clk_125m_tx_unbuf  : 125MHz, 90°相移, RGMII TX ODDR 专用
# clk_200m_unbuf     : 200MHz, IDDR/过采样
# clk_50m_cpu_unbuf  : 50MHz, CPU 子系统
# clk_fb             : 50MHz, MMCM 反馈 (内部)
set_clock_groups -asynchronous \
    -group [get_clocks clk_125m_unbuf] \
    -group [get_clocks clk_125m_tx_unbuf] \
    -group [get_clocks clk_200m_unbuf] \
    -group [get_clocks -include_generated clk_50m_cpu_unbuf]
