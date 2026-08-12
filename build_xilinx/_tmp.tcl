open_project RiscV_WebSoC.xpr
open_run impl_1
set brams [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]
puts "BRAM_count: [llength $brams]"
foreach b [lrange $brams 0 2] {
    puts "Example_BRAM: $b"
    catch { puts "  INIT_00 = [get_property INIT_00 $b]" }
}
catch { write_bmm RiscV_WebSoC.bmm } result
puts "write_bmm: $result"
close_design
close_project
