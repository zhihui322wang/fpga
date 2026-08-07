# 从已有综合 checkpoint 重跑实现 + 生成 bitstream
# (pin 约束改变后不需要重跑综合)
set script_dir [file dirname [file normalize [info script]]]
set proj_dir $script_dir

open_project [file join $proj_dir RiscV_WebSoC.xpr]

# 更新约束文件 (重新读取)
reset_run impl_1

puts "Running Implementation + Bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set proj_name "RiscV_WebSoC"
set bit_src "$proj_dir/${proj_name}.runs/impl_1/webserver_cpu_top.bit"
set bit_dst "$proj_dir/${proj_name}.bit"
if {[file exists $bit_src]} {
    file copy -force $bit_src $bit_dst
    puts "SUCCESS: Bitstream generated at $bit_dst"
} else {
    puts "ERROR: Bitstream NOT generated!"
}

open_run impl_1
report_timing_summary -file "$proj_dir/timing_summary.rpt"
report_utilization    -file "$proj_dir/utilization.rpt"
close_design
puts "DONE"
