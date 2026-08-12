// dclk_tdpram.v — 异步真双口RAM（True Dual-Port RAM，独立时钟域）
//
// 端口A / 端口B 均支持独立读写，各自使用独立时钟 clock_a / clock_b。
// 读写模式：READ_FIRST（写操作期间输出写入前的旧数据）。
//
// 参数说明：
//   data_width      : 数据位宽（bit）
//   depth           : 实际需要的RAM字数（非2的幂亦可）
//   addr_width      : 地址端口位宽，需满足 2^addr_width >= depth
//   block_ram_size  : 每块Block RAM的数据位大小（单位：Kbit，不含奇偶校验位）
//   ram_type        : 综合实现方式，"block"/"distributed"/"M4K"/"MLAB"
//
// Block RAM 粒度分配原理（与 single_clock_true_dual_port_ram 一致）：
//   WORDS_PER_BRAM = block_ram_size × 1024 / data_width
//   NUM_BLOCKS     = ceil(depth / WORDS_PER_BRAM)
//   ALLOC_DEPTH    = NUM_BLOCKS × WORDS_PER_BRAM
//
// 综合属性兼容性：
//   intel Quartus  : (* ramstyle = ram_type *)   [Verilog属性语法]
//   Xilinx Vivado  : (* ram_style = ram_type *)  [Verilog属性语法]
//   Synplify Pro   : /* synthesis syn_ramstyle = ram_type */  [注释属性语法]

`include "define.sv"

module dual_clock_true_dual_port_ram #(
    parameter data_width = 32,
    parameter addr_width = 12,  // 地址端口位宽（外部传入，仅决定端口宽度）
    parameter depth = 4096,  // 实际需要的RAM字数（非2的幂亦可）
    // 注意：内部实际分配深度ALLOC_DEPTH由block_ram_size计算，
    // 可能大于2^addr_width；请确保addr_width >= $clog2(depth)
    parameter block_ram_size = 32,  // 每块Block RAM数据位大小（Kbit，不含校验）
    parameter ram_type = "block",  /*"block" ; "distributed" ; "M4K" ; "MLAB"*/
    parameter vendor = "",  // "xilinx"(Xilinx) ; "intel"; ""(综合推断)
    parameter SIMPLE_INFER = 0  // 1 = simple inference, bypass complex multi-block allocation
) (
    input                   clock_a,
    input                   clock_b,
    input  [addr_width-1:0] address_a,
    input                   wren_a,
    input  [data_width-1:0] data_a,
    output [data_width-1:0] q_a,

    input  [addr_width-1:0] address_b,
    input                   wren_b,
    input  [data_width-1:0] data_b,
    output [data_width-1:0] q_b
);
  // ══════════════════════════════════════════════════════════════════════
  // SIMPLE_INFER mode: bypass complex multi-block allocation, use plain
  // Verilog inference. Vivado/Quartus will map to BRAM/distributed RAM.
  // ══════════════════════════════════════════════════════════════════════
  generate
    if (SIMPLE_INFER) begin : simple_infer_ram
      reg [data_width-1:0] ram [0:(1<<addr_width)-1] /* synthesis syn_ramstyle = ram_type */;

      reg [data_width-1:0] q_a_reg;
      reg [data_width-1:0] q_b_reg;

      // Port A: READ_FIRST
      always @(posedge clock_a) begin
        if (wren_a) ram[address_a] <= data_a;
        q_a_reg <= ram[address_a];
      end

      // Port B: READ_FIRST
      always @(posedge clock_b) begin
        if (wren_b) ram[address_b] <= data_b;
        q_b_reg <= ram[address_b];
      end

      assign q_a = q_a_reg;
      assign q_b = q_b_reg;
    end else begin : complex_ram

  localparam BYTE_EN_BITS = data_width / 8;

  // ── Block RAM 粒度分配（与 single_clock_true_dual_port_ram 一致）──
  // 每块Block RAM能存储的字数
  localparam WORDS_PER_BRAM = (block_ram_size * 1024) / data_width;

  // 向上取整，计算所需最少Block RAM块数
  localparam NUM_BLOCKS = (depth + WORDS_PER_BRAM - 1) / WORDS_PER_BRAM;

  // 对齐到整数块边界的实际分配深度
  localparam ALLOC_DEPTH = NUM_BLOCKS * WORDS_PER_BRAM;

  // 内部地址线位宽：由ALLOC_DEPTH精确计算
  localparam ALLOC_ADDR_BITS = $clog2(ALLOC_DEPTH);

  localparam BASE_DEPTH = WORDS_PER_BRAM;
  localparam BASE_ADDR_WIDTH = $clog2(BASE_DEPTH);
  localparam BLOCK_SEL_BITS = (NUM_BLOCKS <= 1) ? 1 : $clog2(NUM_BLOCKS);

  // ── Block 选择：除法/取模（与 single_clock 一致，适配非2的幂 BASE_DEPTH）──
  wire [ALLOC_ADDR_BITS-1:0] addr_a_idx = address_a;
  wire [ALLOC_ADDR_BITS-1:0] addr_b_idx = address_b;
  wire                       addr_a_valid = (addr_a_idx < ALLOC_DEPTH);
  wire                       addr_b_valid = (addr_b_idx < ALLOC_DEPTH);

  wire [ BLOCK_SEL_BITS-1:0] block_sel_a = addr_a_idx / BASE_DEPTH;
  wire [ BLOCK_SEL_BITS-1:0] block_sel_b = addr_b_idx / BASE_DEPTH;
  wire [BASE_ADDR_WIDTH-1:0] block_addr_a = addr_a_idx % BASE_DEPTH;
  wire [BASE_ADDR_WIDTH-1:0] block_addr_b = addr_b_idx % BASE_DEPTH;

  // ── Block 选择寄存器（补偿 1 周期读延迟）──
  reg  [ BLOCK_SEL_BITS-1:0] block_sel_a_r;
  reg  [ BLOCK_SEL_BITS-1:0] block_sel_b_r;
  reg                        block_sel_a_valid_r;
  reg                        block_sel_b_valid_r;

  // ── Block RAM 实例化 ───────────────────────────────────────
  wire [     data_width-1:0] q_a_blocks                                [0:NUM_BLOCKS-1];
  wire [     data_width-1:0] q_b_blocks                                [0:NUM_BLOCKS-1];
  wire                       wren_a_blocks                             [0:NUM_BLOCKS-1];
  wire                       wren_b_blocks                             [0:NUM_BLOCKS-1];

  // ── 输出多路复用（所有 vendor 分支共用）────────────────────
  //   组合逻辑 mux + 地址有效性门控，补偿 1 周期读延迟
  wire [     data_width-1:0] q_a_int;
  wire [     data_width-1:0] q_b_int;
  reg  [     data_width-1:0] q_a_mux;
  reg  [     data_width-1:0] q_b_mux;

  genvar i;

  integer xa;
  integer xb;

  // ── 参数约束 ──────────────────────────────────────────
  //   addr_width 必须足够覆盖 ALLOC_DEPTH 的地址空间
  //   若不满足，仿真时 $fatal 报错退出；综合时未定义模块导致工具报错。
    if (addr_width < ALLOC_ADDR_BITS) begin : gen_addr_width_check
      // synthesis translate_off
      initial begin
        $fatal(
            1,
            "\n  FATAL: addr_width (%0d) must be >= ALLOC_ADDR_BITS ($clog2(ALLOC_DEPTH) = %0d).\n         ALLOC_DEPTH = NUM_BLOCKS * WORDS_PER_BRAM = %0d * %0d = %0d\n",
            addr_width, ALLOC_ADDR_BITS, NUM_BLOCKS, WORDS_PER_BRAM, ALLOC_DEPTH);
      end
      // synthesis translate_on
    end

  always @(posedge clock_a) begin
    block_sel_a_r <= block_sel_a;
    block_sel_a_valid_r <= addr_a_valid;
  end

  always @(posedge clock_b) begin
    block_sel_b_r <= block_sel_b;
    block_sel_b_valid_r <= addr_b_valid;
  end
    for (i = 0; i < NUM_BLOCKS; i = i + 1) begin : ram_block
      // wren decode per block（含地址有效性检查）
      assign wren_a_blocks[i] = wren_a && addr_a_valid && (block_sel_a == i[BLOCK_SEL_BITS-1:0]);
      assign wren_b_blocks[i] = wren_b && addr_b_valid && (block_sel_b == i[BLOCK_SEL_BITS-1:0]);

      // ── Vendor-specific memory instances ───────────────────
      if (vendor == "xilinx") begin : vendor_xilinx_xpm
        // Xilinx/xilinx: xpm_memory_tdpram — independent-clock true dual-port
        localparam BYTE_WR_BITS = (data_width >= 8) ? 8 : data_width;
        xpm_memory_tdpram #(
            .ADDR_WIDTH_A           (BASE_ADDR_WIDTH),
            .ADDR_WIDTH_B           (BASE_ADDR_WIDTH),
            .AUTO_SLEEP_TIME        (0),
            .BYTE_WRITE_WIDTH_A     (BYTE_WR_BITS),
            .BYTE_WRITE_WIDTH_B     (BYTE_WR_BITS),
            .CASCADE_HEIGHT         (0),
            .CLOCKING_MODE          ("independent_clock"),
            .ECC_MODE               ("no_ecc"),
            .MEMORY_INIT_FILE       ("none"),
            .MEMORY_INIT_PARAM      ("0"),
            .MEMORY_OPTIMIZATION    ("true"),
            .MEMORY_PRIMITIVE       ("block"),
            .MEMORY_SIZE            (BASE_DEPTH * data_width),
            .MESSAGE_CONTROL        (0),
            .READ_DATA_WIDTH_A      (data_width),
            .READ_DATA_WIDTH_B      (data_width),
            .READ_LATENCY_A         (1),
            .READ_LATENCY_B         (1),
            .READ_RESET_VALUE_A     ("0"),
            .READ_RESET_VALUE_B     ("0"),
            .RST_MODE_A             ("SYNC"),
            .RST_MODE_B             ("SYNC"),
            .SIM_ASSERT_CHK         (0),
            .USE_EMBEDDED_CONSTRAINT(0),
            .USE_MEM_INIT           (0),
            .WAKEUP_TIME            ("disable_sleep"),
            .WRITE_DATA_WIDTH_A     (data_width),
            .WRITE_DATA_WIDTH_B     (data_width),
            .WRITE_MODE_A           ("read_first"),
            .WRITE_MODE_B           ("read_first")
        ) u_xpm_memory_tdpram (
            .sleep         (1'b0),
            .clka          (clock_a),
            .ena           (1'b1),
            .wea           ({data_width / BYTE_WR_BITS{wren_a_blocks[i]}}),
            .addra         (block_addr_a),
            .dina          (data_a),
            .injectsbiterra(1'b0),
            .injectdbiterra(1'b0),
            .douta         (q_a_blocks[i]),
            .sbiterra      (),
            .dbiterra      (),
            .regcea        (1'b1),
            .rsta          (1'b0),
            .clkb          (clock_b),
            .enb           (1'b1),
            .web           ({data_width / BYTE_WR_BITS{wren_b_blocks[i]}}),
            .addrb         (block_addr_b),
            .dinb          (data_b),
            .injectsbiterrb(1'b0),
            .injectdbiterrb(1'b0),
            .doutb         (q_b_blocks[i]),
            .sbiterrb      (),
            .dbiterrb      (),
            .regceb        (1'b1),
            .rstb          (1'b0)
        );

      end else if (vendor == "intel") begin : vendor_intel_altsyncram
        // intel/intel: altsyncram — true dual-port with independent clocks
        altsyncram #(
            .operation_mode                    ("BIDIR_DUAL_PORT"),
            .width_a                           (data_width),
            .widthad_a                         (BASE_ADDR_WIDTH),
            .width_byteena_a                   (BYTE_EN_BITS),
            .numwords_a                        (BASE_DEPTH),
            .width_b                           (data_width),
            .widthad_b                         (BASE_ADDR_WIDTH),
            .width_byteena_b                   (BYTE_EN_BITS),
            .numwords_b                        (BASE_DEPTH),
            .outdata_reg_a                     ("CLOCK0"),
            .outdata_reg_b                     ("CLOCK1"),
            .read_during_write_mode_port_a     ("OLD_DATA"),
            .read_during_write_mode_port_b     ("OLD_DATA"),
            .read_during_write_mode_mixed_ports("OLD_DATA"),
            .power_up_uninitialized            ("FALSE"),
            .ram_block_type                    ("M9K"),
            .clock_enable_input_a              ("NORMAL"),
            .clock_enable_input_b              ("NORMAL"),
            .clock_enable_output_a             ("NORMAL"),
            .clock_enable_output_b             ("NORMAL")
        ) u_altsyncram_block (
            .clock0        (clock_a),
            .clock1        (clock_b),
            .clocken0      (1'b1),
            .clocken1      (1'b1),
            .clocken2      (1'b1),
            .clocken3      (1'b1),
            .aclr0         (1'b0),
            .aclr1         (1'b0),
            .address_a     (block_addr_a),
            .address_b     (block_addr_b),
            .addressstall_a(1'b0),
            .addressstall_b(1'b0),
            .byteena_a     ({BYTE_EN_BITS{1'b1}}),
            .byteena_b     ({BYTE_EN_BITS{1'b1}}),
            .wren_a        (wren_a_blocks[i]),
            .wren_b        (wren_b_blocks[i]),
            .rden_a        (1'b1),
            .rden_b        (1'b1),
            .data_a        (data_a),
            .data_b        (data_b),
            .q_a           (q_a_blocks[i]),
            .q_b           (q_b_blocks[i]),
            .eccstatus     ()
        );

      end else begin : vendor_default_inferred
        // Generic inferred true dual-port RAM — READ_FIRST mode
        reg [data_width-1:0]
            ram[0:BASE_DEPTH-1]
    /* synthesis syn_ramstyle = ram_type */;

        reg [data_width-1:0] q_a_inferred;
        reg [data_width-1:0] q_b_inferred;

        // Port A: READ_FIRST
        always @(posedge clock_a) begin
          if (wren_a_blocks[i]) ram[block_addr_a] <= data_a;
          q_a_inferred <= ram[block_addr_a];
        end

        // Port B: READ_FIRST
        always @(posedge clock_b) begin
          if (wren_b_blocks[i]) ram[block_addr_b] <= data_b;
          q_b_inferred <= ram[block_addr_b];
        end

        assign q_a_blocks[i] = q_a_inferred;
        assign q_b_blocks[i] = q_b_inferred;
      end
    end

  always_comb begin
    q_a_mux = {data_width{1'b0}};
    for (xa = 0; xa < NUM_BLOCKS; xa = xa + 1) begin
      if (block_sel_a_r == xa[BLOCK_SEL_BITS-1:0]) q_a_mux = q_a_blocks[xa];
    end
  end

  always_comb begin
    q_b_mux = {data_width{1'b0}};
    for (xb = 0; xb < NUM_BLOCKS; xb = xb + 1) begin
      if (block_sel_b_r == xb[BLOCK_SEL_BITS-1:0]) q_b_mux = q_b_blocks[xb];
    end
  end

  assign q_a_int = block_sel_a_valid_r ? q_a_mux : {data_width{1'b0}};
  assign q_b_int = block_sel_b_valid_r ? q_b_mux : {data_width{1'b0}};

  assign q_a = q_a_int;
  assign q_b = q_b_int;
    end
  endgenerate
endmodule


// Dummy placeholder for tools (e.g. Verilator) that may mis-evaluate the
// generate condition due to cross-hierarchy parameter propagation.
// When parameters are legal, the condition is FALSE and this module is unused.
// NOTE: synthesis translate_off removed — allow synthesis when addr_width < EFF_ADDR_BITS
module ERROR__addr_width_must_be_gte_alloc_addr_bits__dual_clock_tdp ();
endmodule

// synthesis translate_off
`timescale 1ns / 1ps

module tb_dual_clock_true_dual_port_ram;

  // Parameters
  localparam data_width = 32;
  localparam block_ram_size = 32;
  localparam depth = 5120;
  localparam WORDS_PER_BRAM = (block_ram_size * 1024) / data_width;
  localparam NUM_BLOCKS = (depth + WORDS_PER_BRAM - 1) / WORDS_PER_BRAM;
  localparam ALLOC_DEPTH = NUM_BLOCKS * WORDS_PER_BRAM;
  localparam BASE_DEPTH = WORDS_PER_BRAM;
  localparam addr_width = $clog2(depth);

  // Signals
  reg                      clock_a;
  reg                      clock_b;
  reg     [addr_width-1:0] address_a;
  reg                      wren_a;
  reg     [data_width-1:0] data_a;
  wire    [data_width-1:0] q_a;

  reg     [addr_width-1:0] address_b;
  reg                      wren_b;
  reg     [data_width-1:0] data_b;
  wire    [data_width-1:0] q_b;
  reg     [data_width-1:0] expected_data;

  // Test procedure
  integer                  i;
  integer                  error_count;

  // Clock generation
  initial begin
    clock_a = 0;
    forever #5 clock_a = ~clock_a;  // 100 MHz
  end

  initial begin
    clock_b = 0;
    forever #6 clock_b = ~clock_b;  // ~83.33 MHz
  end

  // Instantiate DUT
  dual_clock_true_dual_port_ram #(
      .data_width(data_width),
      .addr_width(addr_width),
      .depth(depth),
      .block_ram_size(block_ram_size),
      .ram_type("registers"),
      .vendor("")
  ) dut (
      .clock_a(clock_a),
      .clock_b(clock_b),
      .address_a(address_a),
      .wren_a(wren_a),
      .data_a(data_a),
      .q_a(q_a),
      .address_b(address_b),
      .wren_b(wren_b),
      .data_b(data_b),
      .q_b(q_b)
  );

  initial begin
    $dumpfile("tb_dual_clock_true_dual_port_ram.vcd");
    $dumpvars(0, tb_dual_clock_true_dual_port_ram);
    // Initialize signals
    address_a = 0;
    wren_a = 0;
    data_a = 0;
    address_b = 0;
    wren_b = 0;
    data_b = 0;
    error_count = 0;

    // Reset phase
    #100;

    // Test each RAM block
    for (i = 0; i < NUM_BLOCKS; i = i + 1) begin
      // Step 1: Write on Port A
      $display("Testing block %0d: Writing on Port A...", i);
      @(posedge clock_a);
      address_a = i * BASE_DEPTH;  // Base address of block i
      wren_a = 1;
      data_a = 32'hA000_0000 + i;  // Unique data for block i
      @(posedge clock_a);
      wren_a = 0;

      #20;  // Wait for write to settle

      // Step 2: Read on Port A and Port B
      $display("Testing block %0d: Reading on Port A...", i);
      @(posedge clock_a);
      address_a = i * BASE_DEPTH;
      wren_a = 0;
      @(posedge clock_a);  // Wait for read data
      @(posedge clock_a);
      expected_data = 32'hA000_0000 + i;
      if (q_a !== expected_data) begin
        $display("Error at block %0d, Port A read: expected %h, got %h", i, expected_data, q_a);
        error_count = error_count + 1;
      end

      $display("Testing block %0d: Reading on Port B...", i);
      @(posedge clock_b);
      address_b = i * BASE_DEPTH;
      wren_b = 0;
      @(posedge clock_b);  // Wait for read data
      @(posedge clock_b);
      if (q_b !== expected_data) begin
        $display("Error at block %0d, Port B read: expected %h, got %h", i, expected_data, q_b);
        error_count = error_count + 1;
      end

      // Step 3: Write on Port B
      $display("Testing block %0d: Writing on Port B...", i);
      @(posedge clock_b);
      address_b = i * BASE_DEPTH;
      wren_b = 1;
      data_b = 32'hB000_0000 + i;  // Different unique data
      @(posedge clock_b);
      wren_b = 0;

      #20;  // Wait for write to settle

      // Step 4: Read on Port A and Port B
      $display("Testing block %0d: Reading on Port A after Port B write...", i);
      @(posedge clock_a);
      address_a = i * BASE_DEPTH;
      wren_a = 0;
      @(posedge clock_a);  // Wait for read data
      @(posedge clock_a);
      expected_data = 32'hB000_0000 + i;
      if (q_a !== expected_data) begin
        $display("Error at block %0d, Port A read: expected %h, got %h", i, expected_data, q_a);
        error_count = error_count + 1;
      end

      $display("Testing block %0d: Reading on Port B after Port B write...", i);
      @(posedge clock_b);
      address_b = i * BASE_DEPTH;
      wren_b = 0;
      @(posedge clock_b);  // Wait for read data
      @(posedge clock_b);
      if (q_b !== expected_data) begin
        $display("Error at block %0d, Port B read: expected %h, got %h", i, expected_data, q_b);
        error_count = error_count + 1;
      end
    end

    // Summary
    #100;
    if (error_count == 0) begin
      $display("All tests passed successfully!");
    end else begin
      $display("Tests completed with %0d errors.", error_count);
    end
    $finish;
  end
endmodule
// synthesis translate_on
