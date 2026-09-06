# Build Log

## Setup
- Flashed Raspberry Pi OS Lite 64-bit, enabled SSH, set hostname to pirouter.
- Confirmed interfaces: eth0 = built-in (WAN), eth1 = USB adapter (LAN), wlan0 = wifi.

## 2026-09-05 — WAN baseline
Troubleshooting
Fast jack, laptop direct, NordVPN removed.
Peak hours (8:53pm Sat), three runs:
  882.9 / 734.9   894.6 / 738.3   878.4 / 730.9  Mbps
  Ping 1ms, jitter 0-1ms
Mean: ~885 down / 735 up
Jack hands out 192.168.1.150, gw 192.168.1.1, /24, DNS OpenDNS
Living room jack is a separate network: 10.254.2.115, gw 10.254.0.1, /16,
  captive portal, ~90 Mbps. That's the FastMesh amenity side, fed by the
  PAX1800 AP mounted above it.
LAN subnet chosen: 192.168.50.0/24 (avoids both 192.168.1.0/24 and 10.254.0.0/16)
