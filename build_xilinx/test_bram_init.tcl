# 快速验证: 能否在 impl 后读/写 BRAM INIT 属性
open_project RiscV_WebSoC.xpr
open_run impl_1

# 获取 bank 0 的 BRAM cell
set bank0 [get_cells -hier "*xpm_bank\[0\].*xpm_memory_base_inst"]
puts "Bank 0 cell: $bank0"

# 读取当前 INIT_00
set init00 [get_property INIT_00 $bank0]
puts "Current INIT_00 length: [string length $init00]"
puts "Current INIT_00: $init00"

# 尝试写入
set test_val "0000000000000000000000000000000000000000000000000000000000000000"
set_property INIT_00 $test_val $bank0
set new_init00 [get_property INIT_00 $bank0]
puts "After write INIT_00: $new_init00"
puts "INIT_00 writable: [expr {$new_init00 eq $test_val}]"

# 列出该 cell 的所有 INIT 属性
set props [list_property $bank0]
set init_props {}
foreach p $props {
    if {[string match "INIT*" $p]} {
        lappend init_props $p
    }
}
puts "INIT properties ([llength $init_props]): [join [lsort $init_props] ", "]"

close_design
close_project
