# Build Log

A running record of what I did, what broke, and how I fixed it.

---

## Setup (pre-move)

- Flashed Raspberry Pi OS Lite 64-bit, enabled SSH, set hostname to `pirouter`.
- Installed and cached packages while I still had reliable internet: `dnsmasq`,
  `hostapd`, `iptables-persistent`, `vnstat`, `git`, `dnsutils`, `tcpdump`.
- Confirmed interfaces: `eth0` = built-in Ethernet, `eth1` = UGREEN USB adapter,
  `wlan0` = built-in wifi.
- Original plan: `eth0` as WAN into a cable modem, `eth1` as LAN.

---

## 2026-09-05 — New apartment, new problem

Moved into a new place. The original WAN plan assumed a modem to plug into, and
there isn't one. Building provides "Astound FastMesh 100 - Amenity WiFi" through
a captive portal at `cp.fastmesh.com`. Capped at 100 Mbps unless I pay for more.

First instinct was to make `wlan0` the WAN and join the amenity wifi. Wrote up
that plan, then found something better.

### The wall jacks

Three Ethernet jacks in the unit. Tested one by installing a game on the Xbox
and watched it pull 551 to 854 Mbps. That is roughly 8x the amenity wifi cap, so
the wired side is clearly not on the same connection.

The Xbox also got through with no captive portal, which was the tell. Consoles
handle portal pages badly, so if it had needed to authenticate I would have
noticed.

### Clean speed baseline

First round of speed tests had NordVPN active (`10.5.0.2` on the NordLynx
tunnel). Removed NordVPN entirely to get a clean measurement:

- Restored the app folder from the Recycle Bin so the uninstaller could run
- Uninstalled through Settings > Apps
- Removed leftover adapters in Device Manager with "Show hidden devices" on:
  NordLynx Tunnel, TAP-NordVPN Windows Adapter V9, OpenVPN Data Channel Offload

Retested at 8:53pm on a Saturday, which is close to worst case for a residential
building. Laptop plugged direct into the fast jack, no VPN:

```
882.9 / 734.9    894.6 / 738.3    878.4 / 730.9   Mbps down/up
Ping 1ms, jitter 0-1ms
Mean: ~885 down / 735 up
```

Held within 2% of the afternoon numbers. **885 down / 735 up is the WAN baseline.**
Every throughput measurement from here gets compared against this.

### Two separate networks in the apartment

| | Fast jack | Living room jack |
|---|---|---|
| Address | 192.168.1.150 | 10.254.2.115 |
| Gateway | 192.168.1.1 | 10.254.0.1 |
| Mask | /24 | /16 |
| DNS | OpenDNS (208.67.222.222) | 10.254.0.1 |
| Captive portal | No | Yes |
| Speed | ~885 Mbps | ~90 Mbps |
| Lease | ~3 hours | ~16 minutes |

The living room jack is the amenity side. Found a Plasma Cloud PAX1800 access
point mounted on the wall directly above it, with an Astound "DO NOT TAMPER,
actively monitored" sticker and the Astound WA support number. It has two
Ethernet ports with two cables: port 1 is the PoE uplink, port 2 almost
certainly passes through to the jack below. That explains the portal and the
90 Mbps completely.

Astound owns that hardware under section 5 of the customer agreement. Not
touching it.

I initially blamed a bad cable for the slow living room reading. Wrong. Same
laptop, same adapter, entirely different network. The portal was the giveaway,
because a bad cable can slow a link but cannot redirect you to a login page.

### Subnet decision

Fast jack is `192.168.1.0/24`. Amenity side is `10.254.0.0/16`. Picked
**192.168.50.0/24** for the LAN so it collides with neither.

### Open question

`192.168.1.1` does not respond on port 80. No login page at all. Combined with
OpenDNS being configured deliberately, that looks more like managed property
equipment than a leftover consumer router. Still need to confirm who owns it and
whether that jack is meant to be mine. Asked the leasing office.

---

## 2026-09-06 — Interfaces, portal, LAN, DHCP

### Verified interface roles properly

The connection list showed a profile called `netplan-eth0` bound to a device
called `eth1`, which made me doubt the names in my notes. Rather than trust
either, checked the hardware directly:

```
sudo ethtool -i eth0   -> driver bcmgenet, bus-info fd580000.ethernet
sudo ethtool -i eth1   -> driver cdc_ncm,  bus-info usb-0000:01:00.0-2
```

`bcmgenet` on a platform bus address is the Pi 4's built-in controller. A USB
bus path is the UGREEN adapter. Original notes were right. Lesson: interface
names are a label, bus-info is the fact.

**eth0 = WAN (built-in), eth1 = LAN (USB adapter), wlan0 = wifi.**

### USB adapter check

```
sudo ethtool eth1  -> Speed: 1000Mb/s, Duplex: Unknown! (255)
lsusb -t           -> cdc_ncm on a 5000M bus
```

Gigabit on a USB 3.0 port, so no bottleneck there. The `Duplex: Unknown!` is a
reporting quirk of the `cdc_ncm` driver rather than a fault. USB Ethernet
adapters commonly show it.

### The netplan scare

Found two files in `/etc/netplan/` and worried netplan was competing with
NetworkManager for the same interfaces. Read them instead of guessing:

```
sudo cat /etc/netplan/*.yaml
```

Both had `renderer: NetworkManager` with embedded NM UUIDs matching the
connection list. These are NetworkManager's own exports, not a rival config
system. Current Raspberry Pi OS writes a netplan YAML alongside each connection
it creates. Real config lives in `/etc/NetworkManager/system-connections/`.

No conflict. Reading the file beat assuming from the filename.

Deleted two stale wifi profiles left over from the old place:
`netplan-wlan0-Bham` and `NEW FBI SURVEILLANCE VAN`.

### Captive portal solved

The FastMesh portal has an "Automatic Login / MAC Address Profile" section that
takes a manually entered MAC. Got the Pi's wifi MAC:

```
ip link show wlan0   -> 88:a2:9e:68:0c:39
```

Registered it in the portal as `pi-router`. Confirmed:

```
curl -s -o /dev/null -w "%{http_code}\n" http://connectivitycheck.gstatic.com/generate_204
204
```

204 means authenticated with no portal in the way. Solved this by registering
the MAC rather than scripting a login against the portal's challenge parameter,
which was the fallback plan.

### The amenity wifi is not a management path

Plan was to keep `wlan0` on FastMesh as a rescue route in case I broke the wired
side. It does not work that way.

Laptop at `10.254.2.0`, Pi at `10.254.3.107`, both inside `10.254.0.0/16`, so
they should reach each other. SSH times out instead. That is **client isolation**,
which amenity and guest networks run so residents cannot see each other's
devices. Every client gets a lane to the internet and no path sideways.

So `wlan0` is a working internet path for the Pi but useless for reaching it.
Better to learn this now than during the firewall step.

**Action item: buy a micro-HDMI cable and a USB keyboard before arming the
firewall.** Local console is the only real backstop left.

### LAN interface up

The guide I was following says to edit `/etc/dhcpcd.conf`. That file is from an
older Raspberry Pi OS. This version uses NetworkManager, so that edit does
nothing. Used `nmcli` instead.

Since my only way in was the cable I was about to reconfigure, chained both
commands so they would complete even if the session dropped mid-way:

```
sudo nmcli con add type ethernet ifname eth1 con-name lan ip4 192.168.50.1/24 && sudo nmcli con up lan
```

Session dropped as expected. Bootstrapped back in by giving the laptop a
temporary static address, since dnsmasq was not running yet to hand one out:

```
netsh interface ip set address name="Ethernet" static 192.168.50.2 255.255.255.0 192.168.50.1
ssh psaliba@192.168.50.1
```

Also stopped using `pirouter.local`. mDNS was unreliable all evening, especially
once the Pi had two networks. A fixed address does not depend on name
resolution.

### DHCP and DNS with dnsmasq

Backed up the stock config, wrote my own. What each part does:

- `interface=eth1` + `bind-interfaces` — listen on the LAN side only. Without
  this, dnsmasq would offer DHCP on every interface including the WAN. Handing
  out addresses to the building's network is a good way to get noticed.
- `dhcp-range=192.168.50.100,192.168.50.200,24h` — the pool. Pi is at .1,
  clients get .100 to .200, .2 to .99 stays free for manual assignments.
- `dhcp-option=3` — tells clients their gateway is the Pi.
- `dhcp-option=6` — tells clients their DNS server is the Pi. These two are what
  make devices actually route through the router.
- `server=1.1.1.1` / `server=8.8.8.8` — upstream resolvers for cache misses.
- `cache-size=1000` — repeat lookups answered locally.
- `stop-dns-rebind` — blocks upstream answers that map public names to private
  addresses.

### DNS leak caught in the startup log

First start looked fine but the log had three resolvers, not two:

```
using nameserver 1.1.1.1#53
using nameserver 8.8.8.8#53
using nameserver 10.254.0.1#53
```

dnsmasq had read `/etc/resolv.conf` and picked up the amenity network's DNS
server, handed to `wlan0` by DHCP. Some lookups would have gone out through
FastMesh. Not broken, but the point of running my own DNS is knowing where
queries go.

Fixed with `no-resolv`, which tells dnsmasq to use only the servers I specified.
Restarted and the log now shows just 1.1.1.1 and 8.8.8.8.

Worth noting I only caught this by reading the log rather than checking for
"active (running)" and moving on.

### DHCP handoff confirmed

Put the laptop back on DHCP:

```
netsh interface ip set address name="Ethernet" dhcp
```

Laptop got `192.168.50.165`, mask `255.255.255.0`, gateway `192.168.50.1`.
Ping to the Pi: 4 of 4, ~2ms. Lease on the Pi:

```
1788848008 9c:2d:cd:c0:ec:71 192.168.50.165 Shrek 01:9c:2d:cd:c0:ec:71
```

MAC matches the laptop's Realtek adapter. **The Pi is handing out addresses to
real hardware.**

No internet from the laptop yet, which is correct. IP forwarding is off and
there is no NAT rule, so traffic stops at the Pi.

---

## Next

1. Enable IP forwarding, write the NAT rule with `eth0` as WAN.
2. Plug `eth0` into the fast jack, confirm a LAN client reaches the internet.
3. **Measure throughput through the Pi and compare against the 885 baseline.**
   Expect a shortfall. A Pi 4 doing iptables NAT typically lands 600-800 Mbps
   because every packet costs CPU time.
4. Convert to nftables with flow offload and measure a third time. Target is
   recovering most of the gap.
5. Arm the firewall (needs console gear first).
6. Buy a Wi-Fi 6 access point for the LAN side. The Pi's own radio cannot serve
   885 Mbps and cannot run AP mode while `wlan0` is doing anything else.
