# led_ctrl.tcl — JTAG 直写 LED 寄存器
# LED 寄存器地址: 0x10 (写低 4 位控制 4 个 LED)
# 用法: vivado -mode batch -source led_ctrl.tcl
#
# LED 值示例:
#   0x0F — 全亮    0x00 — 全灭
#   0x01 — LED0    0x02 — LED1
#   0x04 — LED2    0x08 — LED3
#   0x05 — LED0+2  0x0A — LED1+3

set led_value 0x05    ;# ← 改这里设不同 LED 组合

open_hw_manager
connect_hw_server
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

# 查找 JTAG-AXI 实例
set hw_axis [get_hw_axis -quiet]
if {[llength $hw_axis] == 0} {
    puts "ERROR: 未找到 JTAG-AXI 实例，请确认比特流已烧录"
    close_hw_manager
    exit 1
}
puts "Found HW AXI: $hw_axis"

# 写 LED 寄存器 (地址 0x10)
set txn [create_hw_axi_txn -quiet -type write -address 0x00000010 -data [format 0x%08X $led_value] -len 1 [lindex $hw_axis 0]]
if {$txn == ""} {
    puts "ERROR: 创建 AXI 事务失败"
} else {
    run_hw_axi $txn
    puts "LED 寄存器写入成功: 0x[format %02X $led_value]"
}

close_hw_manager
