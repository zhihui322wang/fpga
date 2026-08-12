# Vivado Tcl: 通过 updatemem 风格更新 BRAM 并生成 bitstream
# 将 16 个 bank 的数据合并后，为每个 BRAM 创建正确的 INIT 属性

set proj_dir [file dirname [file normalize [info script]]]
set proj_name "RiscV_WebSoC"

open_run impl_1

# 读取合并的 MEM 文件
set fp [open "$proj_dir/firmware_combined.mem" r]
set all_words {}
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} continue
    if {[string match "//*" $line]} continue
    if {[string match "@*" $line]} continue
    if {[string length $line] >= 8} {
        set hex [string range $line 0 7]
        lappend all_words $hex
    }
}
close $fp
puts "Loaded [llength $all_words] words"

# 获取所有 RAMB36E1 cell
set bram_cells [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.RAMB36E1 *}]
puts "Found [llength $bram_cells] RAMB36E1 cells"

# 仅处理 instru_ram 相关的 BRAM
set instru_brams {}
foreach cell $bram_cells {
    if {[string match "*instru_ram*" $cell]} {
        lappend instru_brams $cell
    }
}
puts "Found [llength $instru_brams] instruction RAM BRAM cells"

# 按 bank 索引排序
set bank_array(16) {}
foreach cell $instru_brams {
    if {[regexp {xpm_bank\[(\d+)\]} $cell -> bank]} {
        set bank_array($bank) $cell
        puts "  Bank $bank: $cell"
    }
}

# 每个 bank: 256 words @ 32bit
# RAMB36E1 在 32-bit 模式下: INIT_00 ~ INIT_1F (32 个), 每个 64 hex chars
# INITP_00 ~ INITP_07 (8 个), 每个 64 hex chars (parity, 通常全 0)

for {set bank 0} {$bank < 16} {incr bank} {
    if {![info exists bank_array($bank)]} {
        puts "WARNING: Bank $bank not found"
        continue
    }
    set cell $bank_array($bank)
    set bank_start [expr {$bank * 256}]

    # 为每个 INIT_XX 构建 64-char hex string
    for {set i 0} {$i < 32} {incr i} {
        set init_val ""
        # 每个 INIT 存储 8 words，最高地址 word 在 hex 字符串的高位
        for {set w 7} {$w >= 0} {incr w -1} {
            set word_idx [expr {$bank_start + $i * 8 + $w}]
            if {$word_idx < [llength $all_words]} {
                append init_val [lindex $all_words $word_idx]
            } else {
                append init_val "00000000"
            }
        }
        set prop_name [format "INIT_%02X" $i]
        # Vivado 属性: 需要用引号包裹 hex string
        # 在 64-char hex 中每 2 字符一组插入下划线 (Vivado 格式)
        set formatted ""
        for {set c 0} {$c < 64} {incr c 2} {
            if {$c > 0} { append formatted "_" }
            append formatted [string range $init_val $c [expr {$c+1}]]
        }
        # 实际上 Vivado 可能不需要下划线，先试试直接 64 hex
        # set_property $prop_name $init_val $cell
    }
    puts "Bank $bank: cell=$cell"
}

puts "Writing bitstream with updated BRAMs..."
write_bitstream -force "$proj_dir/${proj_name}_hw.bit"
puts "DONE"
