# Vivado 编程脚本 — RiscV_WebSoC_3
# 用法: vivado -mode batch -source program.tcl
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
puts "Found [llength $targets] target(s)"
if {[llength $targets] > 0} {
  current_hw_target [lindex $targets 0]
  open_hw_target
  set dev [current_hw_device]
  puts "Device: $dev"
  set_property PROGRAM.FILE {/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/build_xilinx/RiscV_WebSoC_hw.bit} $dev
  program_hw_devices $dev
  puts "PROGRAMMING SUCCESS"
} else {
  puts "ERROR: No hardware targets found. Please check:"
  puts "  1. FPGA board is powered on"
  puts "  2. JTAG USB cable is connected (FT232H/FT2232 port)"
  puts "  3. USB permissions: check /etc/udev/rules.d/52-xilinx-*.rules"
}
close_hw_manager
