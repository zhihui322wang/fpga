set nfacs [ gtkwave::getNumFacs ]
set found 0
for {set i 0} {$i < $nfacs} {incr i} {
    set name [ gtkwave::getFacName $i ]
    if {[string match "*led_o*" $name]} {
        gtkwave::addSignalsFromList "$name"
        puts "Added: $name"
        set found 1
    }
    if {[string match "*cpu_rd_empty*" $name]} {
        gtkwave::addSignalsFromList "$name"
        puts "Added: $name"
        set found 1
    }
    if {[string match "*cpu_wr_wpkt_push*" $name]} {
        gtkwave::addSignalsFromList "$name"
        puts "Added: $name"
        set found 1
    }
    if {[string match "*riscv_reset_l*" $name] || [string match "*reset*riscv*" $name]} {
        gtkwave::addSignalsFromList "$name"
        puts "Added: $name"
        set found 1
    }
    if {[string match "*gmii_rx_dv*" $name]} {
        gtkwave::addSignalsFromList "$name"
        puts "Added: $name"
        set found 1
    }
    if {[string match "*mac_rx_sop*" $name]} {
        gtkwave::addSignalsFromList "$name"
        puts "Added: $name"
        set found 1
    }
}
if {!$found} { puts "No signals found. Dumping first 50 facs:"; for {set i 0} {$i < 50 && $i < $nfacs} {incr i} { puts [ gtkwave::getFacName $i ] } }
