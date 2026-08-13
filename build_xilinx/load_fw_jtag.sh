#!/bin/bash
#===================================================================
# load_fw_jtag.sh — 通过 JTAG 上传固件（不用 UART，SW0 可一直 ON）
#
# 原理：用 updatemem 把固件 bake 进 BRAM INIT，生成 RiscV_WebSoC_fw.bit，
#       再 program 烧录。CPU 上电/复位后直接从 IRAM[0]（bootloader）跑起来。
#
# 依赖：
#   - bank0.mem .. bank15.mem  （16 bank × 256 词 = 4096 词 IRAM）
#   - RiscV_WebSoC.mmi          （BRAM 内存映射，write_mem_info 生成）
#   - RiscV_WebSoC.bit          （最新综合 bitstream，固件为空）
#
# 用法： bash load_fw_jtag.sh [--no-program]
#===================================================================
set -euo pipefail

BD="/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/build_xilinx"
cd "$BD"

VIVADO_SETTINGS="/home/zhihuiw/vivado/Vivado/2024.1/.settings64-Vivado.sh"
UPDATEMEM="/home/zhihuiw/vivado/Vivado/2024.1/bin/updatemem"

PROC_BASE="u_riscv/riscv_cpu_generation.u_riscv_cpu/u_instru_ram/gen_xilinx_xpm_tdpram.xpm_bank"

# ---- 1) 组装 16 个 -data/-proc 参数 ----
ARGS=()
for i in $(seq 0 15); do
  ARGS+=( -data "bank${i}.mem" )
  ARGS+=( -proc "${PROC_BASE}[${i}].u_xpm_memory_tdpram_bank/xpm_memory_base_inst" )
done

echo "===== updatemem: bake 固件进 bitstream ====="
source "$VIVADO_SETTINGS"

"$UPDATEMEM" \
  -meminfo "RiscV_WebSoC.mmi" \
  "${ARGS[@]}" \
  -bit "RiscV_WebSoC.bit" \
  -out "RiscV_WebSoC_fw.bit" \
  -force

echo ""
echo "===== 输出 bitstream ====="
ls -la RiscV_WebSoC_fw.bit

if [[ "${1:-}" == "--no-program" ]]; then
  echo "跳过烧录（--no-program）"
  exit 0
fi

echo ""
echo "===== program: 烧录 RiscV_WebSoC_fw.bit ====="
cat > "$BD/program_fw.tcl" <<'TCL'
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] > 0} {
  current_hw_target [lindex $targets 0]
  open_hw_target
  set dev [current_hw_device]
  puts "Device: $dev"
  set_property PROGRAM.FILE {/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/build_xilinx/RiscV_WebSoC_fw.bit} $dev
  program_hw_devices $dev
  puts "PROGRAMMING SUCCESS"
} else {
  puts "ERROR: No hardware targets found."
}
close_hw_manager
TCL

vivado -mode batch -source "$BD/program_fw.tcl"
echo "===== 完成 ====="
