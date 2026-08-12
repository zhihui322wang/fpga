set script_dir [file dirname [file normalize [info script]]]
set proj_name "RiscV_WebSoC"
set proj_dir  $script_dir
set rtl_dir   [file normalize [file join $script_dir ../rtl]]

# fpga_ila IP 路径 (通过 symlink 避免路径含空格)
set fpga_ila_home "/home/zhihuiw/fpga_work/ip_copy"
set fpga_ila_rtl  [file join $fpga_ila_home rtl]

create_project -force $proj_name $proj_dir -part xc7a35tfgg484-2
puts "\[OK\] Project created"

# ---- 项目 RTL 文件 ----
foreach f [lsort [glob -nocomplain ${rtl_dir}/*.v ${rtl_dir}/*.sv]] {
    add_files -norecurse $f
}
puts "\[OK\] Added [llength [glob -nocomplain ${rtl_dir}/*.v ${rtl_dir}/*.sv]] project RTL files"

# ---- fpga_ila RTL 文件 ----
if {[file exists $fpga_ila_rtl]} {
    foreach f [lsort [glob -nocomplain ${fpga_ila_rtl}/*.v]] {
        add_files -norecurse $f
    }
    # .vh 头文件 (Vivado 依赖追踪)
    foreach f [lsort [glob -nocomplain ${fpga_ila_rtl}/*.vh]] {
        add_files -norecurse $f
    }
    puts "\[OK\] Added fpga_ila RTL files from $fpga_ila_rtl"
} else {
    puts "\[ERROR\] fpga_ila not found: $fpga_ila_rtl"
    exit 1
}

# ---- 全局设置 ----
set_property FILE_TYPE SYSTEMVERILOG [get_files -filter {FILE_TYPE == Verilog}]
set_property top webserver_cpu_top [current_fileset]

# Include 路径: 项目 rtl (define.sv) + fpga_ila rtl (ila_pkg.vh, crc_func.vh, ila_version.vh)
set_property include_dirs [list $rtl_dir $fpga_ila_rtl] [current_fileset]

update_compile_order -fileset sources_1

add_files -fileset constrs_1 -norecurse [file join $script_dir pins.xdc]
add_files -fileset constrs_1 -norecurse [file join $script_dir timing.xdc]

puts "Running Synthesis..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

puts "Running Implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set bit_src "$proj_dir/${proj_name}.runs/impl_1/webserver_cpu_top.bit"
set bit_dst "$proj_dir/${proj_name}.bit"
if {[file exists $bit_src]} { file copy -force $bit_src $bit_dst; puts "Bitstream: $bit_dst" }

open_run impl_1
report_timing_summary -file "$proj_dir/timing_summary.rpt"
report_utilization    -file "$proj_dir/utilization.rpt"
# 生成 BRAM 内存映射文件 (用于 updatemem 合并固件)
write_mem_info -force "$proj_dir/${proj_name}.mmi"
close_design
puts "BUILD COMPLETE"
