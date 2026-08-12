open_project RiscV_WebSoC.xpr
open_run impl_1

# 列出 bank[0] 的所有 RAMB36 子 cell
set bank0_cells [get_cells -hier -filter {REF_NAME =~ "RAMB36*" && NAME =~ "*bank\[0\]*"}]
puts "Bank 0 RAMB36 cells: [llength $bank0_cells]"
foreach b $bank0_cells {
    puts "  $b"
    # 列出该 cell 的 INIT 属性
    set init_props [list]
    foreach p [list_property $b] {
        if {[string match "INIT*" $p] && ![string match "INIT_FILE*" $p]} {
            lappend init_props $p
        }
    }
    puts "    INIT props ([llength $init_props]): [join [lsort $init_props] ", "]"
}

close_design
close_project
