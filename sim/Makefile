# Makefile — iverilog 仿真
RTL = ../rtl
SIM = .

# 所有 RTL 源文件
RTL_SRCS = $(RTL)/webserver_cpu_top.v      \
           $(RTL)/define.sv                 \
           $(RTL)/rgmii_gmii_bridge.v       \
           $(RTL)/rgmii_to_gmii.v           \
           $(RTL)/gmii_to_rgmii.v           \
           $(RTL)/gmii2mac.v                \
           $(RTL)/mac_top.v                 \
           $(RTL)/mac_rx.v                  \
           $(RTL)/mac_tx.v                  \
           $(RTL)/eth_presemble.v            \
           $(RTL)/crc.v                     \
           $(RTL)/sop_eop_gen.v             \
           $(RTL)/cpu_channel.v             \
           $(RTL)/package_fifo_v2.v         \
           $(RTL)/pktfifo2ram_int_v2.v       \
           $(RTL)/ram2pktfifo_int.v          \
           $(RTL)/ramintf.v                 \
           $(RTL)/dual_clock_fifo.v          \
           $(RTL)/dual_clock_simple_dual_port_ram.v \
           $(RTL)/single_clock_fifo.v        \
           $(RTL)/single_clock_simple_dual_port_ram.v \
           $(RTL)/single_clock_true_dual_port_ram.v \
           $(RTL)/lcpu_riscv_wrapper.v       \
           $(RTL)/lcpu_top.v                \
           $(RTL)/lcpu_merge.v              \
           $(RTL)/lcpu_fpga_test.v           \
           $(RTL)/riscv32_top.v             \
           $(RTL)/riscv32_localbus.v         \
           $(RTL)/riscv32intfbridge.v        \
           $(RTL)/picorv32.v                \
           $(RTL)/riscv_reg.v               \
           $(RTL)/jtag_cpu_xilinx.v          \
           $(RTL)/axi2lcpu.v                \
           $(RTL)/uart_lcpu_top.v           \
           $(RTL)/uart_lcpu.v               \
           $(RTL)/uart.v                    \
           $(RTL)/uart_rx.v                 \
           $(RTL)/uart_tx.v                 \
           $(RTL)/fpga_build_time.v          \
           $(RTL)/fix_delay.v               \
           $(RTL)/clock_frequency_divider.v  \
           $(RTL)/pulse_clock_region_pass.v

# 仿真辅助文件
SIM_SRCS = $(SIM)/vendor_stubs.v    \
           $(SIM)/xilinx_stubs.v     \
           $(SIM)/lcpu_bfm.v         \
           $(SIM)/tb.v

# 输出
VVP  = sim.vvp
VCD  = tb.vcd

# iverilog 选项: -g2012 支持 SystemVerilog
IVL  = iverilog
IVFLAGS = -g2012 -Wall -DIVL_SIM -I$(RTL) -I$(SIM) -o $(VVP)

all: $(VVP)

$(VVP): $(RTL_SRCS) $(SIM_SRCS)
	@echo "=== Compiling with iverilog ==="
	$(IVL) $(IVFLAGS) $(SIM_SRCS) $(RTL_SRCS)
	@echo "=== Done: $(VVP) ==="

# 从 TCL 生成 firmware.hex
FW_HEX     = firmware.hex
FW_TCL     = ../tcl/InstructRAM.tcl

$(FW_HEX): $(FW_TCL)
	python3 ../c_build/tcl2hex.py $(FW_TCL) $@

run: $(VVP) $(FW_HEX)
	@echo "=== Running simulation ==="
	vvp $(VVP)

wave: run
	gtkwave $(VCD) &

clean:
	rm -f $(VVP) $(VCD) firmware.hex

.PHONY: all run wave clean
