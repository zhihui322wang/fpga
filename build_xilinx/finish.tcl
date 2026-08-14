# finish.tcl — 完成 build.tcl 未跑完的收尾(原 master 被杀, bit 已生成但未复制/mmi 未重写)
#   1) 复制 impl_1 生成的 bit -> RiscV_WebSoC.bit
#   2) 打开实现后设计, 重写 RiscV_WebSoC.mmi (updatemem 依赖, ILA 加宽后 BRAM 布局变了, 必须重写)
set bd "/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/build_xilinx"
set bit_src "$bd/RiscV_WebSoC.runs/impl_1/webserver_cpu_top.bit"
set bit_dst "$bd/RiscV_WebSoC.bit"
set mmi     "$bd/RiscV_WebSoC.mmi"

if {[file exists $bit_src]} {
  file copy -force $bit_src $bit_dst
  puts "\[OK\] Bitstream copied -> $bit_dst"
} else {
  puts "\[ERROR\] bit not found: $bit_src"; exit 1
}

open_project "$bd/RiscV_WebSoC.xpr"
open_run impl_1
write_mem_info -force $mmi
puts "\[OK\] MMI written -> $mmi"
close_design
close_project
puts "FINISH COMPLETE"
