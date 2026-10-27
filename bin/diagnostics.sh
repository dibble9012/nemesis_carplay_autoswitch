#!/system/bin/sh
# HKMC CarPlay auto-switch: read-only discovery, v2.0.
# Written for dAudio Gen5W shells that lack tr/printf/head/tail/sed:
# uses only echo/cat/grep + raw dumpsys/pm/logcat redirects. No switch issued.
#
# BEST USE: connect CarPlay (wired or wireless), tap INTO CarPlay so it is on
# screen, THEN run this. The resumed-activity line then shows the exact
# component to pin as carplay_component.

export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin:$PATH
STATE=/data/nemesis/state/local.hkmc.carplay-autoswitch
LOG=/data/nemesis/logs/local.hkmc.carplay-autoswitch/apply.log
PM=/system/bin/pm
CMD=/system/bin/cmd
DUMPSYS=/system/bin/dumpsys
LOGCAT=/system/bin/logcat

echo "===== HKMC CarPlay auto-switch v2.0 discovery ====="
echo "date: $(date 2>/dev/null)"
echo "boot_completed: $(/system/bin/getprop sys.boot_completed 2>/dev/null)"

echo; echo "--- RESUMED / FOCUSED activity (pin this as carplay_component if it is CarPlay) ---"
$DUMPSYS activity activities 2>/dev/null | grep -iE 'mResumedActivity|topResumedActivity|mFocusedApp|mCurrentFocus'

echo; echo "--- CarPlay projection packages present ---"
$PM list packages 2>/dev/null | grep -iE 'daudio|dipo|phoneprojection|projection|carplay|iap2|ipod|mediagate'

echo; echo "--- resolve-activity for likely CarPlay packages ---"
for p in com.daudio.app.dipo com.daudio.app.phoneprojection com.google.android.projection.sink; do
    echo "  $p ->"
    $CMD package resolve-activity --brief "$p" 2>/dev/null
done

echo; echo "--- recent CarPlay / iAP2 connect events in logcat ---"
$LOGCAT -d -v brief 2>/dev/null | grep -iE 'setCarPlayConnected|ACTION_IAP2_CONNECTED|iAP2 connected|DipoService|AAProjection' | grep -ivE 'not found'

echo; echo "--- current config in $STATE ---"
if [ -d "$STATE" ]; then
    for f in "$STATE"/*; do [ -f "$f" ] && echo "  ${f##*/} = $(cat "$f" 2>/dev/null)"; done
fi
[ -f "$STATE/last_attempt.txt" ] && { echo; echo "--- last_attempt.txt ---"; cat "$STATE/last_attempt.txt"; }

# Save full raw dumps to USB if one is writable (these are the useful artifacts).
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null)
for ROOT in /storage/usb0 /storage/usb1 /storage/usb2 /mnt/media_rw/usb0 /mnt/media_rw/usb1; do
    [ -d "$ROOT" ] || continue
    DEST="$ROOT/NEMESIS-carplay-autoswitch-diagnostics/$TS"
    mkdir -p "$DEST" 2>/dev/null || continue
    cp "$LOG" "$DEST/service.log" 2>/dev/null
    $DUMPSYS activity activities > "$DEST/dumpsys-activities.txt" 2>&1
    $DUMPSYS usb               > "$DEST/dumpsys-usb.txt" 2>&1
    $PM list packages          > "$DEST/packages.txt" 2>&1
    $LOGCAT -d -v threadtime   > "$DEST/logcat-tail.txt" 2>&1
    echo; echo "carplay: saved raw dumps to $DEST"
    echo "carplay: reports may contain private identifiers; inspect before sharing"
    exit 0
done
echo; echo "carplay: no writable USB. Read on-screen output above, or: nemesis log service local.hkmc.carplay-autoswitch/apply"
exit 0
