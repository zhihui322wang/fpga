// xilinx_stubs.v — Xilinx 7-series 原语仿真模型 (iverilog 用)
// 所有原语行为级建模, 不依赖 UNISIM 库

// ── BUFG ──
module BUFG (input I, output O);
    assign O = I;
endmodule

// ── IDELAYCTRL ──
module IDELAYCTRL (
    input  REFCLK,
    input  RST,
    output RDY
);
    assign RDY = 1'b1;
endmodule

// ── IDELAYE2 ──
// 仿真中 IDELAY = 0, 直接透传
module IDELAYE2 #(
    parameter CINVCTRL_SEL           = "FALSE",
    parameter DELAY_SRC              = "IDATAIN",
    parameter HIGH_PERFORMANCE_MODE  = "FALSE",
    parameter IDELAY_TYPE            = "FIXED",
    parameter IDELAY_VALUE           = 0,
    parameter PIPE_SEL               = "FALSE",
    parameter REFCLK_FREQUENCY       = 200.0,
    parameter SIGNAL_PATTERN         = "DATA"
) (
    input  C,
    input  CE,
    input  CINVCTRL,
    input  CNTVALUEIN,
    input  DATAIN,
    input  IDATAIN,
    input  INC,
    input  LD,
    input  LDPIPEEN,
    input  REGRST,
    output CNTVALUEOUT,
    output DATAOUT
);
    // 仿真模式: 直通, 零延迟
    wire data_in;
    assign data_in = (DELAY_SRC == "IDATAIN") ? IDATAIN : DATAIN;
    assign DATAOUT      = data_in;
    assign CNTVALUEOUT  = 5'b0;
endmodule

// ── IDDR ──
// 双沿采样: posedge 捕获到 Q1, negedge 捕获到 Q2
// DDR_CLK_EDGE="SAME_EDGE_PIPELINED": Q1/Q2 同时在下个 posedge 输出
module IDDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE",
    parameter INIT_Q1 = 1'b0,
    parameter INIT_Q2 = 1'b0,
    parameter SRTYPE  = "SYNC"
) (
    input  C,
    input  CE,
    input  D,
    input  R,
    input  S,
    output Q1,
    output Q2
);
    // SAME_EDGE_PIPELINED: 内部采样 + 流水线输出
    reg q1_int, q2_int;
    reg q1_r, q2_r;

    // 采样阶段: posedge 捕获 Q1 候选, negedge 捕获 Q2 候选
    always @(posedge C) q1_int <= D;
    always @(negedge C) q2_int <= D;

    // 输出阶段: 下个 posedge 同时更新 Q1/Q2 (PIPELINED)
    always @(posedge C) begin
        q1_r <= q1_int;
        q2_r <= q2_int;
    end

    assign Q1 = q1_r;
    assign Q2 = q2_r;
endmodule

// ── ODDR ──
// SDR → DDR: posedge 输出 D1, negedge 输出 D2
module ODDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE",
    parameter INIT  = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    input  C,
    input  CE,
    input  D1,
    input  D2,
    input  R,
    input  S,
    output Q
);
    reg q_r;
    always @(posedge C) q_r <= D1;
    always @(negedge C) q_r <= D2;
    assign Q = q_r;
endmodule

// ── XPM_MEMORY_TDPRAM ──
// Xilinx 参数化真双口 RAM 行为模型
module xpm_memory_tdpram #(
    parameter ADDR_WIDTH_A       = 6,
    parameter ADDR_WIDTH_B       = 6,
    parameter AUTO_SLEEP_TIME    = 0,
    parameter BYTE_WRITE_WIDTH_A = 8,
    parameter BYTE_WRITE_WIDTH_B = 8,
    parameter CLOCKING_MODE      = "common_clock",
    parameter ECC_MODE           = "no_ecc",
    parameter MEMORY_SIZE        = 2048,
    parameter READ_DATA_WIDTH_A  = 8,
    parameter READ_DATA_WIDTH_B  = 8,
    parameter READ_LATENCY_A     = 1,
    parameter READ_LATENCY_B     = 1,
    parameter WRITE_DATA_WIDTH_A = 8,
    parameter WRITE_DATA_WIDTH_B = 8,
    parameter WRITE_MODE_A       = "read_first",
    parameter WRITE_MODE_B       = "read_first",
    parameter MEMORY_PRIMITIVE   = "block",
    parameter MEMORY_INIT_FILE   = "none",
    parameter MEMORY_INIT_PARAM  = "0",
    parameter USE_MEM_INIT       = 1,
    parameter CASCADE_HEIGHT     = 0,
    parameter MESSAGE_CONTROL    = 0,
    parameter MEMORY_OPTIMIZATION = "true",
    parameter RST_MODE_A         = "SYNC",
    parameter RST_MODE_B         = "SYNC",
    parameter SIM_ASSERT_CHK     = 1,
    parameter USE_EMBEDDED_CONSTRAINT = 0,
    parameter WAKEUP_TIME        = "disable_sleep",
    parameter READ_RESET_VALUE_A = "0",
    parameter READ_RESET_VALUE_B = "0"
) (
    input  sleep,
    input  clka, clkb,
    input  ena, enb,
    input  regcea, regceb,
    input  rsta, rstb,
    input  [ADDR_WIDTH_A-1:0] addra, addrb,
    input  [WRITE_DATA_WIDTH_A-1:0] dina, dinb,
    input  [WRITE_DATA_WIDTH_A/8-1:0] wea, web,
    output [READ_DATA_WIDTH_A-1:0] douta, doutb,
    output sbiterra, sbiterrb,
    output dbiterra, dbiterrb,
    input  injectsbiterra, injectsbiterrb,
    input  injectdbiterra, injectdbiterrb
);
    localparam DEPTH = (MEMORY_SIZE + READ_DATA_WIDTH_A - 1) / READ_DATA_WIDTH_A;
    reg [READ_DATA_WIDTH_A-1:0] douta_r, doutb_r;

    // 简单行为模型: 直接在 reg 数组上读/写 (初始化为 0, 避免 X 传播)
    reg [READ_DATA_WIDTH_A-1:0] mem [0:DEPTH-1];
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1)
            mem[init_i] = {READ_DATA_WIDTH_A{1'b0}};
    end

    always @(posedge clka) if (ena) begin
        if (wea != 0) mem[addra] <= dina;
        douta_r <= mem[addra];
    end
    always @(posedge clkb) if (enb) begin
        if (web != 0) mem[addrb] <= dinb;
        doutb_r <= mem[addrb];
    end

    assign douta = douta_r;
    assign doutb = doutb_r;
    assign sbiterra = 0; assign sbiterrb = 0;
    assign dbiterra = 0; assign dbiterrb = 0;
endmodule
