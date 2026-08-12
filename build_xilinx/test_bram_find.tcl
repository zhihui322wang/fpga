open_project RiscV_WebSoC.xpr
open_run impl_1

# 搜索 RAMB36 原语
set ramb [get_cells -hier -filter {REF_NAME =~ "RAMB36*"}]
puts "RAMB36 cells: [llength $ramb]"
foreach b $ramb {
    puts "  $b"
    set init00 [get_property INIT_00 $b]
    puts "    INIT_00 first16=[string range $init00 0 15]"
}
close_design
close_project
