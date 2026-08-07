# Detect hardware and program FPGA
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
puts "Found [llength $targets] target(s)"
if {[llength $targets] > 0} {
  current_hw_target [lindex $targets 0]
  open_hw_target
  set devices [get_hw_devices]
  puts "Found [llength $devices] device(s)"
  if {[llength $devices] > 0} {
    set dev [lindex $devices 0]
    puts "Device: $dev"
    set_property PROGRAM.FILE {/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/build_xilinx/RiscV_WebSoC.bit} $dev
    program_hw_devices $dev
    puts "PROGRAMMING SUCCESS"
  }
} else {
  puts "ERROR: No hardware targets found"
  puts "Check: 1) Board powered on  2) USB cable connected  3) FTDI drivers installed"
}
close_hw_manager
