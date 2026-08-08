#!/bin/sh
IFACE=$1
EVENT=$2
LOG=/tmp/apfpv.log
# Timestamp with uptime: there is no RTC battery, so wall clock starts at epoch.
T=$(cut -d. -f1 /proc/uptime)
case "$EVENT" in
    CONNECTED)
        echo "[${T}s] apfpv: $IFACE associated, requesting DHCP" >> $LOG
        # By pid file, not killall: eth0 runs its own udhcpc now, and killing
        # that one leaves the management address unrenewed.
        [ -f /var/run/udhcpc.$IFACE.pid ] && kill "$(cat /var/run/udhcpc.$IFACE.pid)" 2>/dev/null
        udhcpc -i $IFACE -s /usr/share/udhcpc/apfpv.script \
               -p /var/run/udhcpc.$IFACE.pid -b -t 10 -A 5 >> $LOG 2>&1
        sleep 2
        ip=$(ifconfig $IFACE | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
        echo "[${T}s] apfpv: $IFACE address ${ip:-none}" >> $LOG
        # Keep the on-screen overlay honest across reconnects.
        sed -i 's/^state=.*/state=COMPLETED/; s/^note=.*/note=/' \
            /tmp/wifi-status 2>/dev/null
        ;;
    DISCONNECTED)
        echo "[${T}s] apfpv: $IFACE disconnected" >> $LOG
        [ -f /var/run/udhcpc.$IFACE.pid ] && kill "$(cat /var/run/udhcpc.$IFACE.pid)" 2>/dev/null
        ifconfig $IFACE 0.0.0.0
        sed -i 's/^state=.*/state=DISCONNECTED/; s/^note=.*/note=LINK LOST/' \
            /tmp/wifi-status 2>/dev/null
        fpv-stop
        ;;
esac
exit 0
