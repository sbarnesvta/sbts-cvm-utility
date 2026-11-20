# SBTS CVM Utility

A native macOS app for controlling a Stewart Filmscreen CVM masking/screen controller over Telnet (IP).

> **Use at your own risk.** This app moves motorised screens and masking directly — make sure the
> screen and masking are clear before operating. Not affiliated with or endorsed by Stewart Filmscreen
> or Converging Systems.

## Features
- IP address, port (default 23), and Telnet login (auto-sent when prompted); settings are remembered
- Keepalive while idle and automatic reconnect if the CVM drops the session
- Per-channel motor control (A–B or A–D): Up / Stop / Down, or go directly to a position (%)
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

## Telnet login
The CVM asks for a login on port 23 (`User:` then `Password:`). The factory defaults are
**User `Telnet 1` / Password `Password 1`** (also `Telnet 2`–`4` / `Password 2`–`4`), and the app
fills these in by default. Both are case-sensitive and include the space. You can change them in the
CVM's web page (`http://<CVM IP>` → TELNET); if you do, enter the new ones in the app. The ↺ button
next to the password field restores the defaults.

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
| `#1.1.N.MOTOR=GOTO,P;` | Move channel N to P % (0–100) — *not in the manual; verified on a CVM* |

## License
[MIT](LICENSE). Provided "as is", without warranty of any kind; the authors accept no liability for
its use.
