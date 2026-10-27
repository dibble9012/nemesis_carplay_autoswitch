# HKMC CarPlay Auto-Switch — NEMESIS v2.5 (dAudio Gen5W / EV6)

Brings **Apple CarPlay to the foreground as soon as it connects — wired or
wireless** — using the unit's own iAP2/CarPlay connect event. Built on the
`local.hkmc.factory82` NEMESIS structure (`mode=restart` service, state dir,
root diagnostics). Auto-starts on boot.

> Test changes while parked.

## How it works

A root service polls `logcat -d` (dump mode) every `poll_seconds` (default 3)
and watches for the unit's CarPlay-connect log line:

```
I/CarPlay_: [ TimeStampManager ] setCarPlayConnected() isConnected = true
```

Lines are read with timestamps (`logcat -d -v time`), and the service fires
only when a **new** connect line appears (timestamp-diffed) — so it triggers
once per real connect and never on stale/repeat lines. On a connect it runs
`am start -n com.daudio.app.dipo/.ui.DipoActivity`, which foregrounds CarPlay.

This one event fires for **both wired and wireless** CarPlay, so there's no
transport-specific logic.

### Why this approach (the dead ends, so you don't repeat them)

On this unit every *level* signal is sticky or absent, which is why detection
had to key on the log event:
- `dumpsys usb` — the iPhone never appears there during CarPlay (iAP2 stack).
- `sys.usb.state=carplay_connect` — wired only.
- `dumpsys wifi curState=TetheredState` — SoftAP stays up after disconnect, and
  the phone stays Wi-Fi-associated, so it never clears. False positives.
- `sys.launcher3.pp.dipo`, the DiPO `CarPlayService` binding, SoftAP ARP entry —
  all remain set after disconnect.
- logcat **follow** mode (`logcat -T`) does **not** work in the NEMESIS service
  context — but logcat **dump** mode (`logcat -d`) does, which is what this uses.

## Install (over adb)

```sh
adb push hkmc.carplay-autoswitch-v2.5.nemesis.zip /data/local/tmp/
adb shell nemesis install --update /data/local/tmp/hkmc.carplay-autoswitch-v2.5.nemesis.zip
adb shell nemesis service status local.hkmc.carplay-autoswitch/apply   # shows v2.5
```
Or via USB: extract `hkmc.carplay-autoswitch-v2.5.USB.zip` to a FAT32/exFAT
drive root, insert into the parked vehicle, approve.

## Verify

```sh
adb shell nemesis log service local.hkmc.carplay-autoswitch/apply | grep -E 'v2.5|connect line|am |probe'
```
Expect at start `probe: logcat readable (dump mode)` and a `baseline connect
line`, then on a connect: `new connect line: ...` → `am start -n
com.daudio.app.dipo/.ui.DipoActivity` → `am exit=0`. (Use `grep`, never `tail`
— this unit's shell has no `tail`.)

## Settings

Files in `/data/nemesis/state/local.hkmc.carplay-autoswitch/`:
```sh
S=/data/nemesis/state/local.hkmc.carplay-autoswitch
nemesis root -c "echo 3 > $S/poll_seconds"
nemesis root -c "echo 2 > $S/connect_grace_seconds"   # delay before switching
nemesis root -c "echo 8 > $S/cooldown_seconds"
# The log line matched (grep -E; escape parens). Change only if firmware wording differs:
nemesis root -c 'echo "setCarPlayConnected\(\) isConnected = true" > $S/connect_mark'
# Overrides (normally unneeded):
nemesis root -c "echo com.daudio.app.dipo/.ui.DipoActivity > $S/carplay_component"
nemesis root -c "printf 'am start -n com.daudio.app.dipo/.ui.DipoActivity' > $S/switch_cmd"
```
Settings are read at service start; after a change:
```sh
nemesis service stop  local.hkmc.carplay-autoswitch/apply
nemesis service start local.hkmc.carplay-autoswitch/apply
```

## Diagnostics / uninstall

```sh
nemesis pkg-launch local.hkmc.carplay-autoswitch      # read-only discovery dump
nemesis uninstall  local.hkmc.carplay-autoswitch      # stop auto-switching
```

## Version history

- **v2.5** — logcat iAP2-connect detection (`setCarPlayConnected()=true` via
  `logcat -d`, timestamp-diffed). One signal for wired + wireless; replaces the
  sticky level-signal detectors.
- **v2.2–2.4** — `sys.usb.state` (wired) + Wi-Fi `TetheredState` (wireless).
  Wired worked; wireless `TetheredState` turned out sticky (false positives).
- **v2.0–2.1** — logcat-follow / dumpsys-usb attempts (follow dead in service;
  iPhone absent from `dumpsys usb`).
- **v1.x** — USB-sysfs / BT / Wi-Fi-P2P detection; wrong for this firmware and
  used tools absent from the unit's shell (`tr`, etc.).
