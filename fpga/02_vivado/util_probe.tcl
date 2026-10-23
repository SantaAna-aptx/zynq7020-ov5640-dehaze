open_project ./vivado/dehaze_vivado.xpr
open_run synth_1
set f [open "./synth_util.rpt" w]
puts $f [report_utilization -return_string]
close $f
close_project
exit 0
