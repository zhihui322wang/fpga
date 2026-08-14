# finish_build.tcl — 只做 build.tcl 的收尾步骤（impl_1 已完成，不重新综合/实现）
# open_run impl_1 -> 拷贝 bitstream -> report_timing -> report_utilization -> write_mem_info
set script_dir [file dirname [file normalize [info script]]]
set proj_name "RiscV_WebSoC"
set proj_dir  $script_dir

open_project [file join $proj_dir ${proj_name}.xpr]
open_run impl_1

# 1) 拷贝最新 bitstream 到顶层
set bit_src "$proj_dir/${proj_name}.runs/impl_1/webserver_cpu_top.bit"
set bit_dst "$proj_dir/${proj_name}.bit"
if {[file exists $bit_src]} {
    file copy -force $bit_src $bit_dst
    puts "Bitstream: $bit_dst"
} else {
    puts "\[ERROR\] bitstream not found: $bit_src"
    exit 1
}

# 2) 时序/资源报告
report_timing_summary -file "$proj_dir/timing_summary.rpt"
report_utilization    -file "$proj_dir/utilization.rpt"

# 3) BRAM 内存映射（updatemem 固件合并依赖，必须用新布局重新生成）
write_mem_info -force "$proj_dir/${proj_name}.mmi"

close_design
close_project
puts "BUILD COMPLETE"
