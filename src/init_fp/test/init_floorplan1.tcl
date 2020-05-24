# init_floorplan
source "helpers.tcl"
read_lef Nangate45/Nangate45.lef
read_liberty Nangate45/Nangate45_typ.lib
read_def reg1.def
initialize_floorplan -die_area "0 0 1000 1000" \
  -core_area "100 100 900 900" \
  -site FreePDK45_38x28_10R_NP_162NW_34O
auto_place_pins metal1

set def_file [make_result_file init_floorplan1.def]
write_def $def_file
diff_files init_floorplan1.defok $def_file
