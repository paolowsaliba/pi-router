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

## 2026-09-10 — NAT, first traffic through the router, throughput measured

### IP forwarding: sysctl.conf no longer exists

The guide says to uncomment `net.ipv4.ip_forward=1` in `/etc/sysctl.conf`. That
file is not present on this OS. Newer Debian replaced the single config file
with drop-ins under `/etc/sysctl.d/`, which already held `98-rpi.conf` and
`README.sysctl`.

Created `/etc/sysctl.d/99-router.conf` instead. The `99` prefix loads after the
existing files so it takes precedence. Applied with `sudo sysctl --system` and
confirmed it survived a reboot.

Second time a tutorial has pointed at a file this OS no longer uses, after
`/etc/dhcpcd.conf`. Nano opens a blank buffer for a path that never existed,
which makes a failed edit look like a successful one.

### NAT rules

Three iptables rules, with interface names as variables at the top of
`firewall.sh`:

- `POSTROUTING -o $WAN_IF -j MASQUERADE` — rewrites outbound LAN traffic to
  appear to come from the Pi, and reverses it on the way back.
- `FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT` — lets replies to
  connections we started come back through.
- `FORWARD -i $LAN_IF -o $WAN_IF -j ACCEPT` — lets LAN clients out.

### Checked the default route before measuring

With `eth0` on the fast jack, the Pi had two default routes:

default via 192.168.1.1 dev eth0 metric 101
default via 10.254.0.1 dev wlan0 metric 600


Lower metric wins, so wired takes priority. Worth verifying rather than
assuming, because if wifi had won, every throughput number below would have
been measured against a 90 Mbps path instead of an 885 one.

### Throughput through the router

First comparison was against a baseline taken days earlier on different test
servers, which made the numbers suspect. Reran both sides minutes apart against
the same server (KamaTera, Seattle) to get a controlled A/B.

Laptop plugged straight into the wall jack:

867.2 / 739.1 885.3 / 739.5 883.7 / 729.9 Mbps
Mean: ~879 down / 736 up


Laptop behind the Pi:

823.2 / 726.6 827.4 / 747.1 815.4 / 723.5 Mbps
Mean: ~822 down / 732 up


**Cost of routing through the Pi: ~57 Mbps down (6.5%), ~4 Mbps up (0.5%).**

The asymmetry is the interesting part. Download loses 6.5% while upload is
effectively unchanged. Most likely because download is where the packet volume
is: bulk data arriving inbound means far more packets per second to evaluate
against the FORWARD chain and rewrite through NAT. Upload on a speed test is
smaller in raw packet count, so the per-packet CPU cost barely registers.

Better than I expected going in. The usual figure quoted for a Pi 4 doing
iptables NAT is 600-800 Mbps, and this held 93% of the line.

This reframes the planned nftables flow offload work. I had it down as
recovering a large loss. The actual ceiling is about 57 Mbps, so it is
optimization rather than rescue. Still worth doing and worth measuring, but
worth being honest that the headline number will be small.

Lesson on methodology: the first comparison used different test servers on
different nights and would have let me attribute server variance to the router.
Controlling the variable took ten minutes and turned a guess into a measurement.

### Security state after Step 8: not done

The router forwards traffic correctly and filters almost nothing.

- `INPUT` policy is still ACCEPT and has no rules, so `sshd` is reachable from
  the WAN side at `192.168.1.149`. Since I still do not know who owns
  `192.168.1.1`, other residents may be on that subnet.
- `FORWARD` policy is still ACCEPT. The three rules permit traffic; nothing
  denies any.
- Rules live in memory only. A reboot drops NAT and LAN clients lose internet.

Fix order: SSH keys and disable password auth first (biggest exposure, no
lockout risk), then `netfilter-persistent save`, then default-drop policies once
console gear is on hand.


## 2026-09-11 — SSH hardening

### The reboot proved the persistence gap

Rebooted the Pi before running `netfilter-persistent save`. Everything came back
except the firewall. The LAN interface, dnsmasq, and IP forwarding all survived,
because those live in config files that load at boot. The iptables rules were
gone, because they only ever existed in kernel memory.

The failure is quiet: NAT stops, LAN clients lose internet, and nothing in the
logs points at the cause.

### SSH key install failed silently

Generated an ed25519 keypair on the laptop, installed the public key to the Pi,
and passwordless login still prompted for a password.

`ssh -v` showed the laptop offering the correct key, then the server replying
"Authentications that can continue: publickey,password" and falling through to a
password prompt. That is a server-side rejection, not a client problem.

Checked on the Pi:

-rw------- 1 psaliba psaliba 0 Jun 17 17:27 authorized_keys


Zero bytes. The key was never written. The install one-liner piped the public
key from PowerShell into `ssh`, and PowerShell can encode piped output as
UTF-16, so the remote `cat` received nothing usable. Neither end raised an
error.

Installed it by pasting into `nano` instead, then verified with `wc -l` that it
landed as a single unwrapped line. A key split across lines fails exactly the
same way an empty file does, with no useful error either way.

Worth remembering: `ssh -v` tells you which side rejected the auth. "Offering
public key" followed by "Authentications that can continue" means the server
said no.

### Password authentication disabled

Verified passwordless login worked in a separate session first, then set in
`/etc/ssh/sshd_config`:

PasswordAuthentication no
PermitRootLogin no


Restarted `ssh` and confirmed a fresh login still worked before closing the
original session. Did all of this while `eth0` was unplugged, so the Pi was only
reachable over the direct LAN cable and there was nothing exposed to lock myself
out of.

This closes the largest of the three security gaps from yesterday. sshd still
listens on all interfaces including the WAN, but a key is now the only way in.
Restricting the listener to the LAN side comes with the default-drop INPUT
rules.

### Made firewall.sh idempotent

The script used `-A` to append rules, so running it twice produced duplicates.
Added `iptables -F` and `iptables -t nat -F` at the top so it always starts from
a clean state. A config script that cannot be safely re-run is a trap.

### Remaining security gaps

1. `FORWARD` policy is still ACCEPT. The rules permit traffic; nothing denies
   any, so the default is wide open.
2. `INPUT` policy is still ACCEPT with no rules.
3. Rules still not persisted across reboot.

Next: `netfilter-persistent save`, then default-drop policies once console gear
is on hand.
