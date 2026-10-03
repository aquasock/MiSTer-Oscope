# Project-specific constraints for the ported scope.
#
# Clock definitions live in sys/sys_top.sdc (FPGA_CLK2_50 = 50 MHz is the
# scope's system clock and CLK_VIDEO). What follows is carried over from
# upstream oscilloscope.sdc, with the board-port false paths dropped: those
# named MAX 10 top-level pins (KEY, SW8/SW9, HEX*, VGA_R*, UART_*, GEN_GPIO*)
# that no longer exist as ports now that sys_top is the top entity. The
# framework's own sys_top.sdc already covers the board-level asynchronous
# inputs.

# The VGA coordinate/scaling pipeline and its destination registers all use the
# alternating 25 MHz pixel enable, so they have two 50 MHz clock periods
# between active captures even though they sit in one clock domain.
set_multicycle_path 2 -setup -to [get_registers {*vga_display|current_wave_y[*]}]
set_multicycle_path 2 -setup -to [get_registers {*vga_display|current_channel_y*}]
set_multicycle_path 2 -setup -to [get_registers {*vga_display|current_channel_min_y*}]
set_multicycle_path 2 -setup -to [get_registers {*vga_display|current_channel_max_y*}]
set_multicycle_path 2 -setup -to [get_registers {*vga_display|current_min_y[*]}]
set_multicycle_path 2 -setup -to [get_registers {*vga_display|current_max_y[*]}]
set_multicycle_path 2 -setup -to [get_registers {*vga_display|trigger_wave_y[*]}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|current_wave_y[*]}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|current_channel_y*}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|current_channel_min_y*}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|current_channel_max_y*}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|current_min_y[*]}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|current_max_y[*]}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|trigger_wave_y[*]}]

# The MiSTer additions to scope_vga.v (VGA_DE/VGA_CE) are generated in the same
# alternating-pixel pipeline as the colour outputs they accompany.
set_multicycle_path 2 -setup -to [get_registers {*vga_display|pixel_valid_pipe[*]}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|pixel_valid_pipe[*]}]

# Capture packet serialization uses constant divide/modulo decoding, but its
# index only changes after a UART byte is accepted (hundreds of clocks apart).
set_multicycle_path 3 -setup -to [get_registers {*u_scope_capture|packet_byte[*]}]
set_multicycle_path 2 -hold  -to [get_registers {*u_scope_capture|packet_byte[*]}]
