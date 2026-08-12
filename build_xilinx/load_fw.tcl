open_hw_manager
connect_hw_server
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

# Load firmware via JTAG using InstructRAM.tcl
source /home/haitaoz/work/FPGA_Prj/RiscV_webSoC2/tcl/InstructRAM.tcl

puts "=== FIRMWARE LOADED ==="
close_hw_manager
