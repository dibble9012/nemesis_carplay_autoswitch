#!/system/bin/sh
# HKMC CarPlay auto-switch: NEMESIS service, v2.5 (dAudio Gen5W / EV6).
# When CarPlay connects (wired OR wireless), bring CarPlay to the foreground.
# Requires NEMESIS "restart" mode (long-running monitor).
#
# Detection (validated on a 2022 Kia EV6 over adb):
#   The unit logs an iAP2/CarPlay connect event that fires for BOTH wired and
#   wireless and is NOT sticky:
#       I/CarPlay_: [ TimeStampManager ] setCarPlayConnected() isConnected = true
#   The service reads it via `logcat -d` (DUMP mode). NOTE: logcat FOLLOW mode
#   (`logcat -T`) does NOT work in the NEMESIS service context on this unit, but
#   dump mode does. Each poll dumps logcat with timestamps and fires once per
#   NEW connect line (timestamp-diffed), so repeated/old lines never re-fire.
#
#   Why not the obvious level signals (all tried and rejected on this unit):
#     - dumpsys usb: iPhone never appears there during CarPlay (iAP2 stack).
#     - sys.usb.state=carplay_connect: WIRED only.
#     - dumpsys wifi curState=TetheredState: SoftAP stays up after disconnect
#       (sticky) -> false positives; phone also stays Wi-Fi-associated.
#     - sys.launcher3.pp.dipo / CarPlayService binding / ARP: all sticky.
#
# Switch target confirmed on-device: com.daudio.app.dipo/.ui.DipoActivity
#
# This shell lacks tr/printf/head/tail/sed; only builtins + echo/cat/grep/
# date/am/pm/cmd/getprop/logcat are used.
#
# TEST WHILE PARKED.

export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin:$PATH
export LD_LIBRARY_PATH=/vendor/lib:/system/lib

STATE=${CP_STATE_DIR:-/data/nemesis/state/local.hkmc.carplay-autoswitch}
AM=${CP_AM_BIN:-/system/bin/am}
CMD=${CP_CMD_BIN:-/system/bin/cmd}
LOGCAT=${CP_LOGCAT_BIN:-/system/bin/logcat}

DETECT_MODE=${CP_DETECT_MODE:-logcat}           # logcat (default) | manualcmd
POLL=${CP_POLL_SECONDS:-3}
COOLDOWN_SECONDS=${CP_COOLDOWN_SECONDS:-8}
CONNECT_GRACE=${CP_CONNECT_GRACE_SECONDS:-2}
READY_WAIT_SECONDS=${CP_READY_WAIT_SECONDS:-15}

# grep -E pattern (parens escaped) that marks a CarPlay connect in logcat.
CONNECT_MARK=${CP_CONNECT_MARK:-setCarPlayConnected\\(\\) isConnected = true}

CARPLAY_COMPONENT=${CP_CARPLAY_COMPONENT:-com.daudio.app.dipo/.ui.DipoActivity}
CARPLAY_PACKAGE=${CP_CARPLAY_PACKAGE:-}
CARPLAY_ACTIVITY=${CP_CARPLAY_ACTIVITY:-}
DEFAULT_PACKAGES="com.daudio.app.dipo com.daudio.app.phoneprojection com.google.android.projection.sink"
SWITCH_CMD=${CP_SWITCH_CMD:-}
DETECT_CMD=${CP_DETECT_CMD:-}

log() { echo "carplay: $(date 2>/dev/null) $*"; }

uptime_seconds() {
    UP=0
    [ -r /proc/uptime ] && read -r UP _ < /proc/uptime 2>/dev/null
    UP=${UP%%.*}
    case "$UP" in ''|*[!0-9]*) UP=0 ;; esac
    echo "$UP"
}

read_setting() { _f="$STATE/$1"; [ -r "$_f" ] && { read -r _v < "$_f" 2>/dev/null; echo "$_v"; }; }
read_file()    { [ -r "$STATE/$1" ] && cat "$STATE/$1" 2>/dev/null; }
sanitize_num() { eval "_x=\$$1"; case "$_x" in ''|*[!0-9]*) eval "$1=$2" ;; esac; }

load_config() {
    _v=$(read_setting detect_mode);           [ -n "$_v" ] && DETECT_MODE=$_v
    _v=$(read_setting poll_seconds);          [ -n "$_v" ] && POLL=$_v
    _v=$(read_setting cooldown_seconds);      [ -n "$_v" ] && COOLDOWN_SECONDS=$_v
    _v=$(read_setting connect_grace_seconds); [ -n "$_v" ] && CONNECT_GRACE=$_v
    _v=$(read_setting ready_wait_seconds);    [ -n "$_v" ] && READY_WAIT_SECONDS=$_v
    _v=$(read_setting carplay_package);       [ -n "$_v" ] && CARPLAY_PACKAGE=$_v
    _v=$(read_setting carplay_activity);      [ -n "$_v" ] && CARPLAY_ACTIVITY=$_v
    _v=$(read_setting carplay_component);     [ -n "$_v" ] && CARPLAY_COMPONENT=$_v
    _v=$(read_file connect_mark);             [ -n "$_v" ] && CONNECT_MARK=$_v
    _v=$(read_file switch_cmd);               [ -n "$_v" ] && SWITCH_CMD=$_v
    _v=$(read_file detect_cmd);               [ -n "$_v" ] && DETECT_CMD=$_v
    sanitize_num POLL 3
    sanitize_num COOLDOWN_SECONDS 8
    sanitize_num CONNECT_GRACE 2
    sanitize_num READY_WAIT_SECONDS 15
    [ "$POLL" -lt 1 ] 2>/dev/null && POLL=1
}

# --- detection: newest CarPlay-connect line in logcat (dump mode) -----------

# Echo the most recent logcat line matching CONNECT_MARK (with timestamp, so
# each real connect is a unique string). Empty if none in the buffer.
latest_connect_line() {
    _hits=$($LOGCAT -d -v time 2>/dev/null | grep -E "$CONNECT_MARK" 2>/dev/null)
    _cur=""
    while IFS= read -r _l; do [ -n "$_l" ] && _cur=$_l; done <<EOF
$_hits
EOF
    echo "$_cur"
}

# --- target + switch --------------------------------------------------------

resolve_target() {
    [ -n "$CARPLAY_COMPONENT" ] && { echo "$CARPLAY_COMPONENT"; return; }
    _pkgs=$CARPLAY_PACKAGE; [ -n "$_pkgs" ] || _pkgs=$DEFAULT_PACKAGES
    for _pkg in $_pkgs; do
        if [ -n "$CARPLAY_ACTIVITY" ]; then
            case "$CARPLAY_ACTIVITY" in */*) echo "$CARPLAY_ACTIVITY" ;; *) echo "$_pkg/$CARPLAY_ACTIVITY" ;; esac
            return
        fi
        _out=$($CMD package resolve-activity --brief "$_pkg" 2>/dev/null)
        _res=""
        for _tok in $_out; do case "$_tok" in "$_pkg"/*) _res=$_tok ;; esac; done
        [ -n "$_res" ] && { echo "$_res"; return; }
    done
    echo ""
}

record_attempt() {
    { echo "reason=$1"; echo "target=$2"; echo "am_exit=$3"; echo "date=$(date 2>/dev/null)"
      echo "trigger=$4"; } > "$STATE/last_attempt.txt" 2>/dev/null
    chmod 600 "$STATE/last_attempt.txt" 2>/dev/null
}

do_switch() {
    WHY=$1
    NOW=$(uptime_seconds)
    if [ "$LAST_SWITCH" -gt 0 ]; then
        _el=$((NOW - LAST_SWITCH))
        if [ "$_el" -ge 0 ] && [ "$_el" -lt "$COOLDOWN_SECONDS" ]; then
            log "coalesced ($WHY; ${_el}s < ${COOLDOWN_SECONDS}s cooldown)"; return
        fi
    fi
    log "CarPlay connect detected ($WHY); switching to foreground; uptime=$NOW"
    [ "$CONNECT_GRACE" -gt 0 ] 2>/dev/null && sleep "$CONNECT_GRACE"

    if [ -n "$SWITCH_CMD" ]; then
        log "running switch_cmd"; eval "$SWITCH_CMD"; _rc=$?
        log "switch_cmd exit=$_rc"; LAST_SWITCH=$(uptime_seconds)
        record_attempt "$WHY" switch_cmd "$_rc" "$TRIGGER_LINE"; return
    fi

    TGT=""; _w=0
    while [ "$_w" -le "$READY_WAIT_SECONDS" ]; do
        TGT=$(resolve_target); [ -n "$TGT" ] && break
        sleep 1; _w=$((_w + 1))
    done
    if [ -z "$TGT" ]; then
        log "no CarPlay target resolved; set carplay_component or switch_cmd. Not switching."
        record_attempt "$WHY" unresolved 1 "$TRIGGER_LINE"; LAST_SWITCH=$(uptime_seconds); return
    fi
    log "am start -n $TGT"
    RESP=$($AM start --user 0 -n "$TGT" 2>&1); _rc=$?
    if [ "$_rc" -ne 0 ]; then
        RESP2=$($AM start -n "$TGT" 2>&1); _rc2=$?
        log "am(--user 0) exit=$_rc: $RESP"; log "am(retry) exit=$_rc2: $RESP2"
        RESP=$RESP2; _rc=$_rc2
    else
        log "am exit=$_rc: $RESP"
    fi
    LAST_SWITCH=$(uptime_seconds); record_attempt "$WHY" "$TGT" "$_rc" "$TRIGGER_LINE"
    log "switch issued (am exit $_rc is not proof the screen changed; verify)"
}

# --- main -------------------------------------------------------------------

mkdir -p "$STATE" || { log 'cannot create state directory; aborting'; exit 1; }
chmod 700 "$STATE" 2>/dev/null
load_config
LAST_SWITCH=0
TRIGGER_LINE=""

log "carplay auto-switch v2.5 started (dAudio Gen5W; logcat iAP2-connect; wired + wireless)"
log "detect_mode=$DETECT_MODE; poll=${POLL}s; cooldown=${COOLDOWN_SECONDS}s; grace=${CONNECT_GRACE}s"
log "connect_mark=[$CONNECT_MARK]; target=${CARPLAY_COMPONENT:-auto}"

# Probe logcat readability in this context.
if [ -n "$($LOGCAT -d -t 1 2>/dev/null)" ]; then
    log "probe: logcat readable (dump mode)"
else
    log "probe: logcat EMPTY/blocked in service context -- detection will not work; check CONNECT_MARK/perms"
fi

if [ "$DETECT_MODE" = manualcmd ]; then
    # Alternate: a custom detect_cmd that exits 0 on connect (edge-triggered).
    LAST_STATE=disconnected
    log "manualcmd mode"
    while :; do
        if [ -n "$DETECT_CMD" ] && eval "$DETECT_CMD" >/dev/null 2>&1; then ST=connected; else ST=disconnected; fi
        if [ "$ST" = connected ] && [ "$LAST_STATE" != connected ]; then do_switch manualcmd; fi
        LAST_STATE=$ST
        sleep "$POLL"
    done
fi

# logcat mode (default): baseline the current newest connect line WITHOUT
# firing (ignores any stale line already in the buffer), then fire on a new one.
LAST_LINE=$(latest_connect_line)
log "baseline connect line: [${LAST_LINE:-none}]"

while :; do
    CUR=$(latest_connect_line)
    if [ -n "$CUR" ] && [ "$CUR" != "$LAST_LINE" ]; then
        LAST_LINE=$CUR
        TRIGGER_LINE=$CUR
        log "new connect line: $CUR"
        do_switch logcat-iap2
    fi
    sleep "$POLL"
done
