############################################################################
##
## BSD 3-Clause License
##
## Copyright (c) 2019, James Cherry, Parallax Software, Inc.
## All rights reserved.
##
## Redistribution and use in source and binary forms, with or without
## modification, are permitted provided that the following conditions are met:
##
## * Redistributions of source code must retain the above copyright notice, this
##   list of conditions and the following disclaimer.
##
## * Redistributions in binary form must reproduce the above copyright notice,
##   this list of conditions and the following disclaimer in the documentation
##   and/or other materials provided with the distribution.
##
## * Neither the name of the copyright holder nor the names of its
##   contributors may be used to endorse or promote products derived from
##   this software without specific prior written permission.
##
## THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
## AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
## IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
## ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
## LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
## CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
## SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
## INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
## CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
## ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
## POSSIBILITY OF SUCH DAMAGE.
##
############################################################################

namespace eval sta {

define_cmd_args "set_wire_rc" {[-layer layer_name]\
				 [-resistance res ][-capacitance cap]\
				 [-corner corner_name]}

proc set_wire_rc { args } {
   parse_key_args "set_wire_rc" args \
    keys {-layer -resistance -capacitance -corner} flags {}

  set wire_res 0.0
  set wire_cap 0.0

  if { [info exists keys(-layer)] } {
    if { [info exists keys(-resistance)] \
	   || [info exists keys(-capacitance)] } {
      ord::error "Use -layer or -resistance/-capacitance but not both."
    }
    set layer_name $keys(-layer)
    set layer [[[ord::get_db] getTech] findLayer $layer_name]
    if { $layer == "NULL" } {
      ord::error "layer $layer_name not found."
    }
    set layer_width_dbu [$layer getWidth]
    set layer_width_micron [ord::dbu_to_microns $layer_width_dbu]
    set res_ohm_per_sq [$layer getResistance]
    set res_ohm_per_micron [expr $res_ohm_per_sq / $layer_width_micron]
    set cap_area_pf_per_sq_micron [$layer getCapacitance]
    set cap_edge_pf_per_micron [$layer getEdgeCapacitance]
    set cap_pf_per_micron [expr 1 * $layer_width_micron * $cap_area_pf_per_sq_micron \
			     + $cap_edge_pf_per_micron * 2]
    # ohms/meter
    set wire_res [expr $res_ohm_per_micron * 1e+6]
    # farads/meter
    set wire_cap [expr $cap_pf_per_micron * 1e-12 * 1e+6]
    
    if { $wire_res == 0.0 } {
      ord::warn "layer resistance is 0.0"
    }
    if { $wire_cap == 0.0 } {
      ord::warn "layer capacitance is 0.0"
    }
  } else {
    ord::ensure_units_initialized
    if { [info exists keys(-resistance)] } {
      set res $keys(-resistance)
      check_positive_float "-resistance" $res
      set wire_res [expr [resistance_ui_sta $res] / [distance_ui_sta 1.0]]
    }
    
    if { [info exists keys(-capacitance)] } {
      set cap $keys(-capacitance)
      check_positive_float "-capacitance" $cap
      set wire_cap [expr [capacitance_ui_sta $cap] / [distance_ui_sta 1.0]]
    }
  }
  
  set corner [parse_corner keys]
  check_argc_eq0 "set_wire_rc" $args
  
  set_wire_rc_cmd $wire_res $wire_cap $corner
  estimate_wire_parasitics
}

define_cmd_args "set_dont_use" {lib_cells}

proc set_dont_use { args } {
  check_argc_eq1 "set_dont_use" $args
  set_dont_use_cmd [get_lib_cells_arg "-dont_use" [lindex $args 0] ord::warn]
}

define_cmd_args "resize" {[-libraries resize_libs]\
			    [-max_utilization util]}

proc resize { args } {
  parse_key_args "resize" args \
    keys {-libraries -dont_use} flags {}
  
  if { [info exists keys(-libraries)] } {
    set resize_libs [get_liberty_error "-libraries" $keys(-libraries)]
  } else {
    set resize_libs [get_libs *]
    if { $resize_libs == {} } {
      ord::error "No liberty libraries found."
    }
  }
  
  if { [info exists keys(-dont_use)] } {
    ord::warn "resize -dont_use is deprecated. Use the set_dont_use commands instead."
    set dont_use [get_lib_cells_arg "-dont_use" $keys(-dont_use) ord::warn]
    set_dont_use $dont_use
  }
  
  check_argc_eq0 "resize" $args
  
  resizer_preamble $resize_libs
  resize_to_target_slew
}

proc parse_max_util { keys_var } {
  upvar 1 $keys_var keys
  set max_util 0.0
  if { [info exists keys(-max_utilization)] } {
    set max_util $keys(-max_utilization)
    if {!([string is double $max_util] && $max_util >= 0.0 && $max_util <= 100)} {
      ord::error "-max_utilization must be between 0 and 100%."
    }
    set max_util [expr $max_util / 100.0]
  }
  return $max_util
}

proc parse_buffer_cell { keys_var required } {
  upvar 1 $keys_var keys
  set buffer_cell "NULL"
  if { [info exists keys(-buffer_cell)] } {
    set buffer_cell_name $keys(-buffer_cell)
    # check for -buffer_cell [get_lib_cell arg] return ""
    if { $buffer_cell_name != "" } {
      set buffer_cell [get_lib_cell_error "-buffer_cell" $buffer_cell_name]
      if { $buffer_cell != "NULL" } {
	if { ![get_property $buffer_cell is_buffer] } {
	  ord::error "[get_name $buffer_cell] is not a buffer."
	}
      }
    }
  } elseif { $required } {
    ord::error "-buffer_cell required for buffer insertion."
  }
  if { $buffer_cell == "NULL" && $required } {
    ord::error "-buffer_cell required for buffer insertion."    
  }
  return $buffer_cell
}

define_cmd_args "buffer_ports" {[-inputs] [-outputs]\
				  -buffer_cell buffer_cell\
				  [-max_utilization util]}

proc buffer_ports { args } {
  parse_key_args "buffer_ports" args \
    keys {-buffer_cell -max_utilization} \
    flags {-inputs -outputs}
  
  set buffer_inputs [info exists flags(-inputs)]
  set buffer_outputs [info exists flags(-outputs)]
  if { !$buffer_inputs && !$buffer_outputs } {
    set buffer_inputs 1
    set buffer_outputs 1
  }
  set buffer_cell [parse_buffer_cell keys 1]
  
  check_argc_eq0 "buffer_ports" $args
  
  set_max_utilization [parse_max_util keys]
  if { $buffer_inputs } {
    buffer_inputs $buffer_cell
  }
  if { $buffer_outputs } {
    buffer_outputs $buffer_cell
  }
}

define_cmd_args "repair_max_cap" {-buffer_cell buffer_cell\
				    [-max_utilization util]}

proc repair_max_cap { args } {
  parse_key_args "repair_max_cap" args \
    keys {-buffer_cell -max_utilization} \
    flags {}
  
  set buffer_cell [parse_buffer_cell keys 1]
  set_max_utilization [parse_max_util keys]
  
  check_argc_eq0 "repair_max_cap" $args
  
  resizer_preamble [get_libs *]
  repair_max_cap_cmd $buffer_cell
}

define_cmd_args "repair_max_slew" {-buffer_cell buffer_cell\
				     [-max_utilization util]}

proc repair_max_slew { args } {
  parse_key_args "repair_max_slew" args \
    keys {-buffer_cell -max_utilization} \
    flags {}
  
  set buffer_cell [parse_buffer_cell keys 1]
  set_max_utilization [parse_max_util keys]
  
  check_argc_eq0 "repair_max_slew" $args
  
  resizer_preamble [get_libs *]
  repair_max_slew_cmd $buffer_cell
}

define_cmd_args "repair_max_fanout" {-buffer_cell buffer_cell\
				       [-max_utilization util]}

proc repair_max_fanout { args } {
  parse_key_args "repair_max_fanout" args \
    keys {-max_fanout -buffer_cell -max_utilization} \
    flags {}
  
  if { [info exists keys(-max_fanout)] } {
    ord::warn "-max_fanout is deprecated. Use set_max_fanout fanout [current_design]."
    set max_fanout $keys(-max_fanout)
    check_positive_integer "-max_fanout" $max_fanout
    set_max_fanout $max_fanout [current_design]
  }
  
  set buffer_cell [parse_buffer_cell keys 1]
  set_max_utilization [parse_max_util keys]
  
  check_argc_eq0 "repair_max_fanout" $args
  
  repair_max_fanout_cmd $buffer_cell
}

define_cmd_args "repair_long_wires" {[-max_length max_length|-max_slew max_slew]\
				       -buffer_cell buffer_cell}

proc repair_long_wires { args } {
  parse_key_args "repair_long_wires" args \
    keys {-max_length -max_slew -buffer_cell} \
    flags {}
  
  set buffer_cell [parse_buffer_cell keys 1]
  if { [info exists keys(-max_length)] } {
    set max_length $keys(-max_length)
    check_positive_float "-max_length" $max_length
    set max_length [sta::distance_ui_sta $max_length]
    if { $max_length == 0.0 } {
      ord::warn "max wire length is zero."
    }
  } elseif { [info exists keys(-max_slew)] } {
    set max_slew $keys(-max_slew)
    check_positive_float "-max_slew" $max_slew
    set max_slew [sta::time_ui_sta $max_slew]
    set max_length [find_max_slew_wire_length $max_slew $buffer_cell]
    if { $max_length != 0.0 } {
      puts "Using max wire length [sta::format_distance $max_length 0]."
    }
  } else {
    set max_slew [default_max_slew]
    set max_length [find_max_slew_wire_length $max_slew $buffer_cell]
    puts "Using max slew [sta::format_time $max_slew 3]."
    if { $max_length != 0.0 } {
      puts "Using max wire length [sta::format_distance $max_length 0]."
    }
  }
  
  check_argc_eq0 "repair_long_wires" $args
  if { $max_length > 0.0 } {
    repair_long_wires_cmd $max_length $buffer_cell
  } else {
    ord::warn "max wire length is 0. Skipping wire repair"
  }
}

define_cmd_args "repair_tie_fanout" {lib_port [-separation dist] [-verbose]}

proc repair_tie_fanout { args } {
  parse_key_args "repair_tie_fanout" args keys {-separation -max_fanout} \
    flags {-verbose}
  
  if { [info exists keys(-max_fanout)] } {
    ord::warn "-max_fanout is deprecated."
  }
  
  set separation 0
  if { [info exists keys(-separation)] } {
    set separation $keys(-separation)
    check_positive_float "-separation" $separation
    set separation [sta::distance_ui_sta $separation]
  }
  set verbose [info exists flags(-verbose)]
  
  check_argc_eq1 "repair_tie_fanout" $args
  set lib_port [lindex $args 0]
  if { ![is_object $lib_port] } {
    set lib_port [get_lib_pins [lindex $args 0]]
  }
  if { $lib_port != "NULL" } {
    repair_tie_fanout_cmd $lib_port $separation $verbose
  }
}

define_cmd_args "repair_hold_violations" {-buffer_cell buffer_cell\
					    [-max_utilization util]}

proc repair_hold_violations { args } {
  parse_key_args "repair_hold_violations" args \
    keys {-buffer_cell -max_utilization} \
    flags {}
  
  set buffer_cell [parse_buffer_cell keys 1]
  set_max_utilization [parse_max_util keys]
  
  check_argc_eq0 "repair_hold_violations" $args
  
  repair_hold_violations_cmd $buffer_cell
}

define_cmd_args "report_design_area" {}

proc report_design_area {} {
  set util [format %.0f [expr [utilization] * 100]]
  set area [format_area [design_area] 0]
  puts "Design area ${area} u^2 ${util}% utilization."
}

define_cmd_args "report_floating_nets" {[-verbose]}

proc report_floating_nets { args } {
  parse_key_args "report_floating_nets" args keys {} flags {-verbose}
  
  set verbose [info exists flags(-verbose)]
  set floating_nets [find_floating_nets]
  set floating_net_count [llength $floating_nets]
  if { $floating_net_count > 0 } {
    ord::warn "found $floating_net_count floatiing nets."
    if { $verbose } {
      foreach net $floating_nets {
	puts " [get_full_name $net]"
      }
    }
  }
}

define_cmd_args "report_long_wires" {count}

proc_redirect report_long_wires {
  global sta_report_default_digits

  parse_key_args "report_long_wires" args keys {-digits} flags {}
  
  set digits $sta_report_default_digits
  if { [info exists keys(-digits)] } {
    set digits $keys(-digits)
  }

  sta::check_argc_eq1 "report_long_wires" $args
  set count [lindex $args 0]
  report_long_wires_cmd $count $digits
}

# sta namespace end
}
