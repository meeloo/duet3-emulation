; config.g for the Renode emulator - not a real machine.
;
; Its main job is the M575 on the next line. Without it there is no console at all: RepRapFirmware
; only calls AuxDevice::SetMode (and so uart->begin) when M575 runs, so the aux port stays shut and
; nothing can be sent in. P3 is Aux2, which is USART2 on this board - the one Renode models.
; S2 is raw mode with no checksum required, i.e. a plain serial console.
M575 P3 S2 B57600

; Three Cartesian axes on the first three drivers. Values are arbitrary but sane; nothing here is
; claiming to describe real hardware.
M569 P0 S1
M569 P1 S1
M569 P2 S1
M584 X0 Y1 Z2
M350 X16 Y16 Z16 I1
M92 X80 Y80 Z400
M203 X6000 Y6000 Z1000
M201 X1000 Y1000 Z250
M566 X600 Y600 Z60
M208 X-200:200 Y-200:200 Z0:200

; No endstops are modelled, so allow movement before homing. This is what makes it possible to jog
; straight after boot without pretending to home first.
M564 H0 S0
