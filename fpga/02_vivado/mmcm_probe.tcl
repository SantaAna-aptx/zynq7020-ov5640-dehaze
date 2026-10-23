open_checkpoint vivado/dehaze_vivado.runs/impl_1/system_wrapper_routed.dcp
set c [get_cells -hier -filter {REF_NAME =~ "MMCME2*"}]
foreach {x} $c {
  puts "CELL $x"
  foreach p {CLKFBOUT_MULT_F CLKOUT0_DIVIDE_F CLKIN1_PERIOD DIVCLK_DIVIDE CLKOUT0_DUTY_CYCLE} {
    puts "   $p = [get_property $p $x]"
  }
}
puts "--- clocks ---"
foreach clk [get_clocks] { puts [format "%-24s %8.3f MHz" [get_property NAME $clk] [get_property PERIOD $clk]] }
