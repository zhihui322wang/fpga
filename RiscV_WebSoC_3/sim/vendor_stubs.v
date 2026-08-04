// vendor_stubs.v — MMCM 仿真 bypass
// sim_mod=1 时用此模块替代 mmcm_50_125
// 50MHz 直接通到各时钟输出 (仿真无需真实 PLL)

module mmcm_50_125 (
    input  wire clk_50m,
    output wire clk_125m,
    output wire clk_200m,
    output wire clk_125m_tx,
    output wire clk_50m_cpu,
    output wire locked,
    input  wire rst_n
);
    // 仿真: 所有时钟 = 50MHz 直通
    assign clk_125m    = clk_50m;
    assign clk_200m    = clk_50m;
    assign clk_125m_tx = clk_50m;
    assign clk_50m_cpu = clk_50m;
    assign locked      = 1'b1;       // 上电即锁定
endmodule
