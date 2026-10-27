#!/system/bin/sh
# NEMESIS stops the registered monitor before running preuninstall.
export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
rm -f /data/nemesis/state/local.hkmc.carplay-autoswitch/last_attempt.txt
echo 'carplay: auto-switch monitor removed; automatic source switching stopped'
echo 'carplay: user config under /data/nemesis/state/local.hkmc.carplay-autoswitch left in place'
exit 0
