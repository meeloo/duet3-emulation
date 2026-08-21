; config.g for the Renode emulator.
;
; A deliberately ordinary Cartesian printer, so that DWC and AxisControl have something realistic to
; display. Nothing here describes hardware that exists; the sensor readings come from the AFEC channel
; values in platforms/duet3_mb6hc.repl.

M111 S0

; --- Communications -----------------------------------------------------------------------------
; This M575 is what gives us a console at all. RepRapFirmware only opens an aux port when M575 runs,
; so without it nothing can be sent in. P3 is Aux2 = USART2, which Renode models. S2 is raw mode.
M575 P3 S2 B57600

M550 P"DuetEmulator"
M552 P192.168.100.50 S1
M586 P0 S1 C"*"                          ; HTTP on, CORS open so DWC can be served from elsewhere

; --- Drives -------------------------------------------------------------------------------------
M569 P0 S1                               ; X
M569 P1 S1                               ; Y
M569 P2 S1                               ; Z
M569 P3 S1                               ; E
M569 P4 S1                               ; U (dust shoe)
M584 X0 Y1 Z2 U4 E3
M350 X16 Y16 Z16 U16 E16 I1
M92 X80 Y80 Z400 U400 E420
M203 X6000 Y6000 Z1000 U1000 E1200
M201 X1000 Y1000 Z250 U250 E250
M566 X600 Y600 Z60 U60 E300
M906 X1200 Y1200 Z1200 E800 I30
M208 X0:200 Y0:200 Z0:200 U0:60   ; U is the dust shoe; its lower limit is what makes the shoe rest on the work

; --- Heaters and sensors ------------------------------------------------------------------------
M308 S0 P"temp0" Y"thermistor" T100000 B4725 C7.06e-8 A"Bed"
M308 S1 P"temp1" Y"thermistor" T100000 B4725 C7.06e-8 A"Hotend"
M950 H0 C"out0" T0
M950 H1 C"out1" T1
M140 H0
M143 H0 S120
M143 H1 S300

; --- Fans ---------------------------------------------------------------------------------------
M950 F0 C"out4" Q500
M950 F1 C"out5" Q500
M106 P0 S0
M106 P1 S1 H1 T45

; --- Tool ---------------------------------------------------------------------------------------
M563 P0 S"Hotend" D0 H1 F0
G10 P0 X0 Y0 Z0 R0 S0
T0

; No endstops are modelled, so allow movement before homing - this is what lets jogging work straight
; after boot without pretending to home first.
M564 H0 S0
