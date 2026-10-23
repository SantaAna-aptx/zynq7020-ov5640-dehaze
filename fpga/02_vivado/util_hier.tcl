open_project ./vivado/dehaze_vivado.xpr
open_run synth_1
set f [open "./hier_util.rpt" w]
puts $f [report_utilization -hierarchical -return_string]
close $f
close_project
exit 0
