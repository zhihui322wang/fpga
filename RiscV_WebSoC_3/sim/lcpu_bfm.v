// lcpu_bfm.v — 仿真总线功能模型 (timer bug 已修复)
// 上电后通过 LCPU JTAG 总线将固件写入指令 RAM, 然后释放 RISC-V 复位

module lcpu_bfm #(
    parameter read_time_out = 2000,
    parameter delay_time    = 1000
) (
    input  clk,
    input  reset_l,

    output reg  OP_DONE,
    output reg [31:0] RD_DATA,
    output reg [31:0] ADDRESS,
    output reg [31:0] WR_DATA,
    output reg  RH_WL,
    output reg  EXEC
);
    reg [31:0] fw_addr [0:2047];
    reg [31:0] fw_data [0:2047];
    reg [11:0] fw_count, idx;
    reg [2:0]  state;
    reg [15:0] delay_timer;   // 独立延时计数器, 不与 OP_DONE 复用
    reg [15:0] op_timer;      // 独立 OP_DONE 超时计数器
    integer    i, fd, scan_ok;

    initial begin
        OP_DONE = 0; RD_DATA = 0; ADDRESS = 0; WR_DATA = 0;
        RH_WL = 0; EXEC = 0; state = 0; idx = 0; fw_count = 0;
        delay_timer = 0; op_timer = 0;
    end

    // 读取固件文件
    initial begin
        fd = $fopen("firmware.hex", "r");
        if (fd == 0) begin
            $display("BFM ERROR: Cannot open firmware.hex");
            fw_count = 0;
        end else begin
            i = 0;
            while (i < 2048 && !$feof(fd)) begin
                scan_ok = $fscanf(fd, "%x %x\n", fw_addr[i], fw_data[i]);
                if (scan_ok == 2) i = i + 1;
            end
            fw_count = i[11:0];
            $display("BFM: Loaded %d firmware words", fw_count);
            $fclose(fd);
        end
    end

    // 总线状态机
    always @(posedge clk) begin
        if (!reset_l) begin
            state <= 0; idx <= 0; EXEC <= 0;
            delay_timer <= 0; op_timer <= 0;
        end else begin
            case (state)
                0: begin  // 等复位稳定
                    if (delay_timer < delay_time)
                        delay_timer <= delay_timer + 1;
                    else
                        state <= 1;
                end

                1: begin  // 逐条写固件
                    if (idx < fw_count) begin
                        if (!EXEC) begin
                            ADDRESS <= fw_addr[idx];
                            WR_DATA <= fw_data[idx];
                            RH_WL   <= 1'b0;
                            EXEC    <= 1'b1;
                            op_timer <= 0;       // 重置超时计数器
                        end else if (op_timer < read_time_out) begin
                            op_timer <= op_timer + 1;
                        end else begin
                            EXEC     <= 1'b0;
                            idx      <= idx + 1;
                            op_timer <= 0;
                        end
                    end else begin
                        EXEC <= 1'b0;
                        state <= 2;
                    end
                end

                2: begin  // 写 0x100=0 (assert reset)
                    if (!EXEC) begin
                        ADDRESS <= 32'h100;
                        WR_DATA <= 32'h0;
                        RH_WL   <= 1'b0;
                        EXEC    <= 1'b1;
                        op_timer <= 0;
                    end else if (op_timer < read_time_out) begin
                        op_timer <= op_timer + 1;
                    end else begin
                        EXEC     <= 1'b0;
                        op_timer <= 0;
                        state    <= 3;
                    end
                end

                3: begin  // 写 0x100=1 (de-assert reset, 释放 CPU)
                    if (!EXEC) begin
                        ADDRESS <= 32'h100;
                        WR_DATA <= 32'h1;
                        RH_WL   <= 1'b0;
                        EXEC    <= 1'b1;
                        op_timer <= 0;
                    end else if (op_timer < read_time_out) begin
                        op_timer <= op_timer + 1;
                    end else begin
                        EXEC     <= 1'b0;
                        op_timer <= 0;
                        state    <= 4;
                        $display("BFM: CPU released from reset");
                    end
                end

                default: ;  // 空闲
            endcase
        end
    end

    // OP_DONE 反馈: EXEC 期间低, 超时后拉高一拍
    always @(posedge clk) begin
        if (!reset_l || !EXEC)
            OP_DONE <= 1'b0;
        else if (op_timer >= read_time_out - 1)
            OP_DONE <= 1'b1;
        else
            OP_DONE <= 1'b0;
    end

endmodule
