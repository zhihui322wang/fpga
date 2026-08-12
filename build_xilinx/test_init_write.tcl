open_project RiscV_WebSoC.xpr
open_run impl_1

# Bank 0 column 1 cell
set b0c1 [get_cells -hier "*xpm_bank\[0\].*mem_cols\[1\].mem_reg"]
puts "Cell: $b0c1"

# 读取完整 INIT_00
set init00 [get_property INIT_00 $b0c1]
puts "INIT_00 len=[string length $init00]"
puts "INIT_00 = $init00"

# 尝试写入全零值
set zero_val "256'h0000000000000000000000000000000000000000000000000000000000000000"
catch { set_property INIT_00 $zero_val $b0c1 } err
puts "Write result: $err"

set new_init [get_property INIT_00 $b0c1]
puts "After write: $new_init"
puts "Writable: [expr {$new_init eq $zero_val}]"

close_design
close_project
