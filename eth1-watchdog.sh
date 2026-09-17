#!/bin/bash
# eth1 watchdog: recovers the AX88179 USB adapter if it hangs.
# Hang signature: rx_packets frozen while rx errors keep climbing.

IF=eth1
INTERVAL=20
STAT=/sys/class/net/$IF/statistics

log() { logger -t eth1-watchdog "$*"; }

bad() { echo $(( $(cat $STAT/rx_errors) + $(cat $STAT/rx_dropped) )); }

recover() {
  usbdev=$(basename "$(dirname "$(readlink -f /sys/class/net/$IF/device)")")
  log "hang detected on $IF (usb $usbdev), resetting adapter"
  echo 0 > /sys/bus/usb/devices/$usbdev/authorized
  sleep 3
  echo 1 > /sys/bus/usb/devices/$usbdev/authorized
  for i in $(seq 30); do
    [ -e /sys/class/net/$IF ] && break
    sleep 1
  done
  sleep 2
  nmcli con up lan >/dev/null 2>&1
  nft -f /etc/nftables.conf
  log "recovery finished, $IF is back"
}

if [ "$1" = "--test-recover" ]; then recover; exit 0; fi

strikes=0
last_pk=$(cat $STAT/rx_packets 2>/dev/null || echo 0)
last_bad=$(bad 2>/dev/null || echo 0)

while true; do
  sleep $INTERVAL
  [ -e $STAT/rx_packets ] || { strikes=0; continue; }
  pk=$(cat $STAT/rx_packets)
  b=$(bad)
  if [ "$pk" -eq "$last_pk" ] && [ "$b" -gt "$last_bad" ]; then
    strikes=$((strikes+1))
  else
    strikes=0
  fi
  if [ $strikes -ge 2 ]; then
    recover
    strikes=0
    sleep 10
    pk=$(cat $STAT/rx_packets 2>/dev/null || echo 0)
    b=$(bad 2>/dev/null || echo 0)
  fi
  last_pk=$pk
  last_bad=$b
done
