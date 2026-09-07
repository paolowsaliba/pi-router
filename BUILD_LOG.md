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
there isn't one. The building provides a 100 Mbps amenity wifi service through a
captive portal. Capped at 100 unless I pay for a higher tier.

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

The first round of speed tests had a VPN client active, which showed up as a
tunnel adapter in `ipconfig`. Removed it entirely to get a clean measurement:

- Restored the app folder from the Recycle Bin so the uninstaller could run
- Uninstalled through Settings > Apps
- Removed leftover virtual adapters in Device Manager with "Show hidden devices"
  enabled

Retested at 8:53pm on a Saturday, close to worst case for a residential
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
| Address range | 192.168.1.x | 10.254.x.x |
| Gateway | 192.168.1.1 | 10.254.0.1 |
| Mask | /24 | /16 |
| DNS | OpenDNS | 10.254.0.1 |
| Captive portal | No | Yes |
| Speed | ~885 Mbps | ~90 Mbps |
| Lease | ~3 hours | ~16 minutes |

The living room jack is the amenity side. Found a wall-mounted access point
directly above it, provider-owned, carrying a tamper-monitoring sticker. It has
two Ethernet ports with two cables: one is the PoE uplink, the other almost
certainly passes through to the jack below. That explains the portal and the
90 Mbps completely.

That hardware belongs to the provider under section 5 of the customer agreement.
Not touching it.

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
whether that jack is meant to be mine.

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
bus path is the UGREEN adapter. My original notes were right. Lesson: interface
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
it creates. The real config lives in `/etc/NetworkManager/system-connections/`.

No conflict. Reading the file beat assuming from the filename.

One of those files held a saved PSK for an old network in plain text, which is
worth knowing about before copying any config file into a repo.

Deleted two stale wifi profiles left over from the previous place.

### Captive portal solved

The portal has an "Automatic Login / MAC Address Profile" section that accepts a
manually entered MAC address. Got the Pi's wifi MAC with `ip link show wlan0`,
registered it in the portal under my own account, named it `pi-router`.
Confirmed:

```
curl -s -o /dev/null -w "%{http_code}\n" http://connectivitycheck.gstatic.com/generate_204
204
```

204 means authenticated with no portal in the way. Solved by registering the
device through a feature the provider built for it, rather than scripting a
login against the portal's challenge parameter, which was the fallback plan.

### The amenity wifi is not a management path

The plan was to keep `wlan0` on the amenity network as a rescue route in case I
broke the wired side. It does not work that way.

Laptop and Pi both had addresses inside `10.254.0.0/16`, so on paper they should
reach each other. SSH timed out instead. That is **client isolation**, which
amenity and guest networks run so residents cannot see each other's devices.
Every client gets a lane to the internet and no path sideways.

So `wlan0` is a working internet path for the Pi but useless for reaching it.
Better to learn this now than during the firewall step.

**Action item: buy a micro-HDMI cable and a USB keyboard before arming the
firewall.** Local console is the only real backstop left.

### LAN interface up

The guide I was following says to edit `/etc/dhcpcd.conf`. That file is from an
older Raspberry Pi OS. This version uses NetworkManager, so that edit does
nothing at all. Used `nmcli` instead.

Since my only way in was the cable I was about to reconfigure, chained both
commands so they would complete even if the session dropped mid-way:

```
sudo nmcli con add type ethernet ifname eth1 con-name lan ip4 192.168.50.1/24 && sudo nmcli con up lan
```

The session dropped as expected. Bootstrapped back in by giving the laptop a
temporary static address, since dnsmasq was not running yet to hand one out:

```
netsh interface ip set address name="Ethernet" static 192.168.50.2 255.255.255.0 192.168.50.1
ssh psaliba@192.168.50.1
```

Also stopped using `pirouter.local`. mDNS was unreliable all evening, especially
once the Pi had two active networks. A fixed address does not depend on name
resolution working.

### DHCP and DNS with dnsmasq

Backed up the stock config and wrote my own. What each part does:

- `interface=eth1` + `bind-interfaces` — listen on the LAN side only. Without
  this, dnsmasq would offer DHCP on every interface including the WAN. Handing
  out addresses on the building's network is a good way to get noticed.
- `dhcp-range=192.168.50.100,192.168.50.200,24h` — the pool. Pi is at .1,
  clients get .100 to .200, and .2 to .99 stays free for manual assignments.
- `dhcp-option=3` — tells clients their gateway is the Pi.
- `dhcp-option=6` — tells clients their DNS server is the Pi. These two are what
  make devices actually route through the router.
- `server=1.1.1.1` / `server=8.8.8.8` — upstream resolvers for cache misses.
- `no-resolv` — see below.
- `cache-size=1000` — repeat lookups answered locally.
- `stop-dns-rebind` — blocks upstream answers that map public names to private
  addresses.

### DNS leak caught in the startup log

The first start looked fine, but the log had three resolvers instead of two:

```
using nameserver 1.1.1.1#53
using nameserver 8.8.8.8#53
using nameserver 10.254.0.1#53
```

dnsmasq had read `/etc/resolv.conf` and picked up the amenity network's DNS
server, handed to `wlan0` by DHCP. Some lookups would have gone out through the
building's resolver. Not broken, but the point of running my own DNS is knowing
where queries go.

Fixed with `no-resolv`, which tells dnsmasq to use only the servers named in the
config. After a restart the log showed just 1.1.1.1 and 8.8.8.8.

Worth noting that I only caught this by reading the log rather than checking for
"active (running)" and moving on.

### DHCP handoff confirmed

Put the laptop back on DHCP:

```
netsh interface ip set address name="Ethernet" dhcp
```

Laptop got `192.168.50.165`, mask `255.255.255.0`, gateway `192.168.50.1`.
Ping to the Pi: 4 of 4, ~2ms. Lease on the Pi:

```
1788848008  9c:2d:cd:xx:xx:xx  192.168.50.165  Shrek
```

The MAC matches the laptop's Ethernet adapter. **The Pi is handing out addresses
to real hardware.**

No internet from the laptop yet, which is correct. IP forwarding is off and
there is no NAT rule, so traffic stops at the Pi.

### Git: divergent branches

Tried to push and got rejected with "fetch first." The remote had 6 commits I
did not have locally, from earlier edits made through the GitHub web interface,
while I had 3 commits on the Pi. Both histories had moved on from the same
point.

`git pull` then refused to run without being told how to reconcile:

- **merge** (`git config pull.rebase false`) — creates a merge commit joining
  both histories. Nothing gets rewritten and the split stays visible.
- **rebase** (`git config pull.rebase true`) — replays my local commits on top
  of the remote ones. Linear history, but it rewrites my commit hashes.

Chose merge. For a project log, the fact that the repo diverged is part of the
record, and rewriting history to hide it would defeat the point.

Hit conflicts in README.md and BUILD_LOG.md since I had just rewritten both.
Resolved by keeping my versions, removing the conflict markers, then
`git add`, `git commit`, `git push`.

Also worth separating clearly: `git commit` saves locally, `git push` sends to
GitHub. Several sessions of commits had never left the Pi.

New habit: `git pull` at the start of a session, `git push` right after
committing. The divergence only happened because I was editing in two places and
syncing in neither.

### Repo privacy pass

Reviewed what a public repo actually exposes to a stranger. Removed device MAC
addresses and anything naming the building or its network. Private IP ranges and
config files stayed, since RFC 1918 addresses are meaningless outside the LAN.

Wifi MACs are worth masking because mapping services harvest them into
geolocation databases, so a MAC alongside network details is a weak location
signal.

Added a `.gitignore` for `*.nmconnection` files, which hold wifi PSKs in plain
text, plus keys and `.env` files.

Also noted that editing a file does not remove its old content from git history.
Checked prior commits for secrets:

```
git log -p --all | grep -i -E "psk|password|key-management" | head
```

Nothing came back, so editing the current files was sufficient. If a real secret
had been in history, the fix would have been rewriting history and rotating the
credential, not just editing the file.

New habit: `git diff --cached` before every commit.

---

## Next

1. Enable IP forwarding, write the NAT rule with `eth0` as WAN.
2. Move the Pi to the fast jack, confirm a LAN client reaches the internet.
3. **Measure throughput through the Pi and compare against the 885 baseline.**
   Expect a shortfall. A Pi 4 doing iptables NAT typically lands 600-800 Mbps
   because every packet costs CPU time.
4. Convert to nftables with flow offload and measure a third time. Target is
   recovering most of the gap.
5. Arm the firewall (needs console gear on hand first).
6. Add a Wi-Fi 6 access point on the LAN side. The Pi's own radio cannot serve
   885 Mbps and cannot run AP mode while `wlan0` is doing anything else.
