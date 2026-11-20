# SBTS CVM Utility

A native macOS app for controlling a Stewart Filmscreen CVM masking/screen controller over Telnet (IP).

## Features
- IP address, port (default 23), and optional Telnet login (auto-sent when prompted); settings are remembered
- Per-channel motor control (A–B or A–D): Up / Stop / Down
- Stop All and Retract All (Home)
- Recall and Store presets 1–24 (store asks for confirmation)
- Position queries per channel or all at once, with optional 2-second auto-refresh
- Console showing all traffic, plus a raw command field
- Selectable line ending after each command (CR / CR+LF / None)

## Build
Requires macOS 14+ and Xcode / Swift command-line tools.

```sh
./build-app.sh
open "CVM Control.app"
```

On first connect, allow local network access when macOS asks.

## Command reference
From the Stewart CVM Owners Manual, page 14:

| Command | Function |
|---|---|
| `#1.1.N.MOTOR=UP;` | Channel N up (1=A … 4=D) |
| `#1.1.N.MOTOR=DOWN;` | Channel N down |
| `#1.1.N.MOTOR=STOP;` | Channel N stop |
| `#1.1.0.MOTOR=STOP;` | Stop all motors |
| `#1.1.0.MOTOR=RECALL,X;` | Recall preset X (1–24) |
| `#1.1.0.MOTOR=STORE,X;` | Store current position as preset X (1–24) |
| `#1.1.0.MOTOR=RETRACT;` | All motors to Home |
| `#1.1.N.MOTOR.POSITION=?;` | Query channel N position (%) |
