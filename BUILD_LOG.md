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

**Action item: buy a console cable and a USB keyboard before arming the
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

```
default via 192.168.1.1  dev eth0   metric 101
default via 10.254.0.1   dev wlan0  metric 600
```

Lower metric wins, so wired takes priority. Worth verifying rather than
assuming, because if wifi had won, every throughput number below would have
been measured against a 90 Mbps path instead of an 885 one.

### Throughput through the router

First comparison was against a baseline taken days earlier on different test
servers, which made the numbers suspect. Reran both sides minutes apart against
the same server (KamaTera, Seattle) to get a controlled A/B.

Laptop plugged straight into the wall jack:

```
867.2 / 739.1    885.3 / 739.5    883.7 / 729.9   Mbps
Mean: ~879 down / 736 up
```

Laptop behind the Pi:

```
823.2 / 726.6    827.4 / 747.1    815.4 / 723.5   Mbps
Mean: ~822 down / 732 up
```

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

### Security state after NAT: not done

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

---

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

```
-rw------- 1 psaliba psaliba 0 Jun 17 17:27 authorized_keys
```

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

```
PasswordAuthentication no
PermitRootLogin no
```

Restarted `ssh` and confirmed a fresh login still worked before closing the
original session. Did all of this while `eth0` was unplugged, so the Pi was only
reachable over the direct LAN cable and there was nothing exposed to lock myself
out of.

This closes the largest of the three security gaps. sshd still listens on all
interfaces including the WAN, but a key is now the only way in. Restricting the
listener to the LAN side comes with the default-drop INPUT rules.

**Follow-up, 09-19:** this did not stick. See the sshd_config.d ordering entry
below.

### Made firewall.sh idempotent

The script used `-A` to append rules, so running it twice produced duplicates.
Added `iptables -F` and `iptables -t nat -F` at the top so it always starts from
a clean state. A config script that cannot be safely re-run is a trap.

### Persistence confirmed

Ran `netfilter-persistent save`, rebooted, and checked the NAT table with
nothing run manually:

```
Chain POSTROUTING (policy ACCEPT)
 pkts bytes target      prot opt in   out    source     destination
    0     0 MASQUERADE  all  --  *    eth0   0.0.0.0/0  0.0.0.0/0
```

Rules now load from `/etc/iptables/rules.v4` at boot. The router survives a
power cut without intervention, which is the difference between a demo and
something that actually runs.

Zero packets on the counter is expected. Nothing had been forwarded yet since
boot.

### FORWARD counters stayed at zero

Ran `ping google.com` from the Pi to check the FORWARD counters were moving.
They stayed at zero, which looked like the rules were not matching.

They were fine. Traffic the router generates itself goes through OUTPUT, not
FORWARD. FORWARD only sees packets that arrive on one interface and leave
through another. Pinging from the Pi never touches it.

The NAT counter did move, because POSTROUTING catches locally generated traffic
as well as forwarded traffic.

Reran the same ping from a LAN client:

```
42811  36M   ACCEPT  all  --  *     *     state RELATED,ESTABLISHED
  491  110K  ACCEPT  all  --  eth1  eth0
```

36 MB matched on the established rule against 110 KB on the LAN-to-WAN rule. A
small number of outbound packets open connections, and everything that comes
back matches on state. That ratio is what working NAT looks like.

Testing a router from the router itself does not test the thing you care about.

### SSH unreachable briefly after reboot

Could not SSH to `192.168.50.1` immediately after the reboot. "Unknown error"
from the Windows client, which usually means no network path rather than a
refused connection.

Resolved on its own shortly after. Most likely dnsmasq and the LAN interface
racing at boot, or the laptop holding a stale lease. Worth watching.

Also a reminder that the WAN-side SSH exposure is still open. Had the LAN side
stayed down, `ssh psaliba@192.168.1.149` from another wall jack would have
worked, because INPUT policy is still ACCEPT with no rules. Convenient today,
still a gap.

---

## 2026-09-13 — Boot delay, WAN profile, case assembly

### bind-dynamic did not fix the startup race

Swapped `bind-interfaces` for `bind-dynamic` in dnsmasq.conf, rebooted, and got
the same behaviour:

```
13:34:38  dnsmasq started
13:34:43  DHCP packet received on eth1 which has no address
13:36:35  DHCP packet received on eth1 which has no address
13:36:42  DHCPACK  192.168.50.165
```

Two minutes before a LAN client could get an address. Confirmed with `grep` that
the config change had applied, so the setting took effect and simply did not
address the problem.

Wrong layer. `bind-dynamic` changes how dnsmasq binds sockets to interfaces. The
error message says `eth1` had no IPv4 address at all, and dnsmasq cannot serve a
DHCP range on an interface with no address no matter how it binds. The delay is
not in dnsmasq's startup order. It is `eth1` taking two minutes to get its
static address from NetworkManager.

Kept `bind-dynamic`, since it is the safer setting either way, and moved the
investigation to NetworkManager and USB enumeration timing.

Worth recording as a reasoning error: I matched "service starts before interface
is ready" to a known fix without checking that the fix addressed the specific
failure. The log message named the actual condition, no address on the
interface, and that pointed somewhere else the whole time.

### The real cause: a stale profile competing for eth1

`journalctl -u NetworkManager` showed the actual sequence:

```
13:33:25  eth1 appears, carrier connected
13:33:26  starting connection 'netplan-eth0'
13:33:26  dhcp4 (eth1): beginning transaction (timeout in 45 seconds)
13:34:24  failed (reason 'ip-config-unavailable')
13:34:24  starting connection 'netplan-eth0'   <- retry
13:35:09  failed
13:35:54  failed
13:36:39  failed
13:36:39  starting connection 'lan'
13:36:39  Activation: successful
```

The USB adapter was never slow. `dmesg` shows it registering at 5.2 seconds and
NetworkManager had carrier a second later.

`netplan-eth0` is a leftover profile from the original setup, configured for
DHCP, with a `match: {}` block that matches any Ethernet device. It claims
`eth1` at every boot and asks for a DHCP lease. Nothing on the LAN side answers,
because the Pi *is* the DHCP server on that segment. Forty-five second timeout,
retry, four rounds, then NetworkManager finally falls through to `lan`, which
activates in 0.24 seconds because it is a static address.

`systemd-analyze blame` corroborated it: `NetworkManager-wait-online.service`
at 1min 71ms, by far the largest entry.

Fixed by disabling autoconnect on the stale profile and raising the priority of
mine:

```
sudo nmcli con modify "netplan-eth0" connection.autoconnect no
sudo nmcli con modify lan connection.autoconnect-priority 100
```

Two wrong guesses before this one. First I assumed dnsmasq was starting too
early, and changed `bind-interfaces` to `bind-dynamic`. Then I assumed USB
enumeration was slow. Both were plausible and both were wrong, because I was
reasoning from the shape of the symptom instead of reading the logs for the
component that was actually stalling. The NetworkManager journal named the
culprit outright on the first read.

Also worth recording: back on 09-06 I noticed `netplan-eth0` bound to `eth1` and
assumed adding my own profile would push it back to `eth0`. It never did. Its
`match: {}` means it matches any Ethernet device, and nothing in that assumption
was ever verified.

### Confirmed

After disabling autoconnect on the stale profile:

```
13:53:01  eth1 appears
13:53:02  carrier: link connected
13:53:02  starting connection 'lan'
13:53:02  Activation: successful
```

Under one second, and `netplan-eth0` does not appear in the log at all.

`NetworkManager-wait-online.service` dropped from 1min 71ms to 4.068s. Boot no
longer stalls waiting for a DHCP lease that was never coming.

### Fixing the boot delay broke the WAN

Disabling autoconnect on `netplan-eth0` cost me internet for LAN clients. `eth0`
had no address at all.

That profile's `match: {}` meant it matched every Ethernet device, not just
`eth1`. It was simultaneously the thing wrongly claiming the LAN adapter and the
only profile giving `eth0` a DHCP lease from the wall jack. Disabling it stopped
both.

The LAN kept working throughout, which made it confusing. Clients still got
addresses from dnsmasq and could reach the Pi. There was simply no uplink behind
it for NAT to translate to.

Fixed with a dedicated WAN profile bound explicitly by interface name:

```
sudo nmcli con add type ethernet ifname eth0 con-name wan ipv4.method auto
sudo nmcli con modify wan connection.autoconnect-priority 100
```

Both interfaces now have their own profile bound to one specific device. No
wildcard match, nothing to compete over. Deleted `netplan-eth0` once the
replacement was confirmed working.

The lesson is about `match: {}`. I treated that profile as "the thing wrongly
claiming eth1" without asking what else it was doing. A wildcard profile is
doing its job on every interface, so disabling it has effects everywhere, not
just where the problem was visible.

### Ruled out thermal throttling

Before measuring nftables against iptables, checked whether heat was part of the
57 Mbps NAT gap. A throttling Pi would make any software comparison meaningless.

```
Idle:        ~45°C
Under load:  peaked 54°C
throttled=0x0 on every check
```

Throttling begins at 80°C, so there is 26°C of headroom. No thermal component to
the throughput loss.

A negative result, but worth having: the gap is software, and the nftables
measurement will be measuring what I think it is.

### Argon ONE M.2 case

Installed the case. No M.2 drive, enclosure and cooling only. Adding a boot
device migration on top of unfinished firewall and AP work would mean not
knowing which change caused the next problem.

Two decisions worth recording:

- **Jumper set to pin 2-3 (Always ON).** Default pin 1-2 requires a button press
  to power on after an outage. For a router that would undo the persistence work,
  since rules that survive a reboot are useless if the device waits for a human.
- **Skipped the USB 3 bridge.** That connector links the M.2 board to one of the
  Pi's USB 3.0 ports. With no drive installed there is nothing to bridge, which
  leaves both blue ports free for the LAN adapter.

Also note the expansion board takes **M.2 SATA only**, Key B or B+M. Not NVMe.
Easy thing to get wrong when buying, since NVMe is the more common form now.

Installed the fan control script from Argon. Default curve is 10% at 55°C, 55% at
60°C, 100% at 65°C, so at a 54°C peak the fan will rarely spin. The manual's
references to desktop icons do not apply on Pi OS Lite; `argonone-config` and
`argonone-uninstall` work from the terminal.

Verified nothing regressed after reassembly:

```
sudo ethtool eth1 | grep -i speed   -> Speed: 1000Mb/s
lsusb -t                            -> cdc_ncm on a 5000M bus
```

The case routes both micro-HDMI ports to a single full-size HDMI on the back, so
the console cable I need is standard HDMI, not micro.

### SD card backup

Imaged the card to a file before further changes, using Win32 Disk Imager's Read
function. Raspberry Pi Imager only writes images, it cannot read a card back.

Windows offers to format the card when it is inserted, because it cannot read the
ext4 root partition and assumes damage. Cancelling that is important.

What is on the card and not in the repo: the OS install, installed packages, SSH
keys and `authorized_keys`, the NetworkManager profiles, and the saved wifi PSK.
The image stays off GitHub, both for size and because it contains a private key.

---

## Checkpoint: state as of 2026-09-13

| | |
|---|---|
| WAN | `eth0`, DHCP from the fast wall jack, profile `wan` |
| LAN | `eth1` (USB adapter), static `192.168.50.1`, profile `lan` |
| Wifi | `wlan0` on the amenity network, MAC-registered, internet only |
| DHCP/DNS | dnsmasq on `eth1`, pool `.100`-`.200`, upstream 1.1.1.1 / 8.8.8.8 |
| NAT | iptables MASQUERADE on `eth0`, persisted via `netfilter-persistent` |
| SSH | key-only, passwords disabled, still listening on all interfaces |
| Throughput | ~822 / 732 Mbps through the Pi, ~879 / 736 at the wall |
| Boot | ~4s to network-online |

---

## 2026-09-15 to 09-16: nftables flow offload

### Goal

Measure whether an nftables flowtable wins back the ~57 Mbps download lost to
routing through the Pi. With a ceiling that small, this was always going to be
optimization, so the real question was whether the gain would be measurable
at all.

A flowtable lets the kernel recognize a connection it has already approved and
send the rest of that connection's packets through a shortcut at the ingress
hook. They skip the FORWARD chain and most of the regular netfilter path.

### Setup

Checked the environment first:

```
iptables v1.8.11 (nf_tables)
nft_flow_offload       12288  0
nf_flow_table          49152  1 nft_flow_offload
```

iptables here is the nf_tables backend, and the flow offload modules load on
the stock Raspberry Pi kernel.

I added the flowtable as its own separate nftables table and left the existing
iptables NAT and FORWARD rules untouched. That keeps the test to one variable,
and removing it is a single command. It also disappears on reboot, which is
what I wanted for an experiment.

```
sudo nft -f - <<'EOF'
table inet fastpath {
  flowtable ft {
    hook ingress priority 0
    devices = { eth0, eth1 }
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
    meta l4proto { tcp, udp } flow add @ft
  }
}
EOF
```

The `policy accept` in this table is safe. In nftables, an accept in one table
does not override a drop in another, so this table permits nothing new. It only
adds the shortcut.

Removal:

```
sudo nft delete table inet fastpath
```

**Gotcha:** my first attempt named the table `offload`. That is a reserved word
in nftables (a flowtable flag for hardware offload), and the parser failed on
it with a wall of syntax errors. Every error after the first was fallout from
that one word. Renaming the table fixed it.

### Method

Same laptop, same Speedtest server (KamaTera, Seattle), A-B-A order so that
ISP variance between runs would show up instead of getting credited to the
router. While tests ran, I watched per-core CPU in `top` (press `1`) from a
second SSH session.

### Results

| Setup | Download avg (Mbps) | Upload avg (Mbps) | Runs |
|---|---|---|---|
| Wall jack (earlier baseline) | ~879 | ~736 | 3 |
| iptables only, 9/15 | ~834 | ~711 | 3 |
| Flowtable loaded, 9/16 | ~889 | ~729 | 4 down, 3 up |
| Flowtable removed, 9/16 | ~833 | ~698 | 3 |

Raw runs:

```
iptables only:     827.5 / 702.3    830.2 / 725.3    843.2 / 704.8
Flowtable loaded:  893.5 / --       881.5 / 729.6    888.4 / 731.2    892.2 / 727.5
Flowtable removed: 835.3 / 685.3    837.2 / 718.8    825.4 / 689.4
```

**Download went from ~834 to ~889 Mbps.** That recovers essentially all of the
routing loss. The flowtable average sits slightly above the wall baseline, but
that baseline was taken on a different day, so I read it as "at line speed"
and not as the Pi beating the wall.

**The removed runs match the iptables-only runs from the day before.** ~833
today versus ~834 yesterday. That is the check that rules out the ISP simply
being faster during the flowtable runs.

**Upload gained less.** About 20 to 30 Mbps depending on which no-flowtable
group I compare against. Upload was already close to line speed.

### Verification

Throughput alone does not prove the shortcut is being used, so I counted
offloaded connections in conntrack during a test:

```
sudo conntrack -L 2>/dev/null | grep -c OFFLOAD
24    (flowtable loaded)
0     (after removal)
```

My first try ran without `sudo`. conntrack printed a permission error and grep
reported 0, which looks like "offload is not working" if you don't read the
error. Worth remembering.

### CPU: the actual bottleneck

`top` showed the real story. Nearly all packet handling lands on **core 0**,
visible as `ksoftirqd/0`. During downloads Cpu0 sat at 94 to 100% `si`
(softirq) while cores 1 to 3 stayed idle.

| | Cpu0 si, download | Cpu0 si, upload |
|---|---|---|
| iptables only | 94 to 100% | 90 to 94% |
| Flowtable loaded | 92 to 99% | 24 to 37% |

So the Pi was never short on total CPU. It was maxing out one core.

On upload, the flowtable cut softirq load by roughly two thirds. On download,
`si` barely moved, but that same saturated core was now pushing ~55 Mbps more
traffic, so each packet got cheaper to handle.

My hypothesis for the difference: on downloads, a large share of the remaining
per-packet work happens outside netfilter, receiving on the built-in port and
transmitting out over the USB adapter. The flowtable only removes the netfilter
part. I haven't verified this, and `top` snapshots taken mid-test are rough,
so I'm treating it as a lead rather than a conclusion.

Follow-up idea: spread packet processing across cores with RPS (Receive Packet
Steering) and see whether core 0 stops being the ceiling.

### Decision

Keeping the flowtable, but not persisting it yet. Current firewall rules live
in iptables-persistent, and Debian's `nftables.service` config starts with
`flush ruleset`, which could wipe the NAT rules depending on boot order. The
clean path is to rewrite the whole firewall as one native nftables file with
the flowtable inside it. That happens as part of the default-drop firewall
step.

Note for that step: once a flow is offloaded, its packets skip the FORWARD
chain. Firewall counters will only show the first few packets of each
connection. That is expected and does not mean rules are being bypassed.

## 2026-09-16: Roadmap review

Reviewed every resource in the project before picking the next steps:
RaspAP docs, geerlingguy/pi-router (OpenWrt build), the pi-hole/pi-hole
installer, and the pidiylab guide.

- **RaspAP:** reference only. Its installer sets up its own dnsmasq and
  hostapd configs, which would collide with my hand-built setup and with
  Pi-hole. The AX55 covers WiFi anyway.
- **OpenWrt:** saved for a v2 rebuild on the same Pi, with a performance
  comparison against this build. My flowtable is essentially what OpenWrt's
  software flow offloading toggle does, so the results carry over.
- **Pi-hole:** still the ad blocker. Its v6 engine takes over DNS and DHCP
  from dnsmasq, so it's a replacement, not an add-on.
- **VPN:** eth0 has a private address (192.168.1.x), so I'm behind the
  building's NAT. Plain WireGuard can't be reached from outside. Plan is a
  Tailscale subnet router, which runs WireGuard underneath.
- **vnstat:** worth adding. Tiny and almost no SD card writes.
- **Grafana:** deferred until the SATA SSD goes in the Argon case. Steady
  disk writes on an SD card aren't worth it yet.

## 2026-09-16: Native nftables firewall

### Why

Until now, NAT lived in iptables-persistent and the flowtable experiment
lived in a separate nftables table that vanished on reboot. Debian's
`nftables.service` starts with `flush ruleset`, so the two could fight at
boot. Rewrote everything as one file: `/etc/nftables.conf`.

### Design

- Default drop on INPUT and FORWARD
- SSH, DNS, DHCP and ping accepted only from eth1 (LAN)
- wlan0 (amenity WiFi) treated as a second untrusted WAN, with NAT so it
  still works as backup internet
- Flowtable built in, offloading only `ct state established` connections,
  so a connection has already passed the rules before it gets the shortcut
- Interface names written out directly, no variables

### Gotcha: long heredoc paste over SSH

My first attempt pasted the whole config as one `sudo tee <<'EOF'` block.
The terminal dropped characters and jumbled lines together, and the `EOF`
ended up inside the masquerade line. `tee` only writes the file, so nothing
was applied. Fixed by deleting the file, opening it in nano, and pasting in
three smaller chunks. I also split the longest icmpv6 line in two.

Checked it came through clean before touching anything:

```
wc -l /etc/nftables.conf       # 63 lines
tail -8 /etc/nftables.conf     # ends with masquerade + closing braces
sudo nft -c -f /etc/nftables.conf   # no output = valid
```

### Applying it

Took a rollback copy first (`iptables-save` to a file, copy of the original
nftables.conf), then applied with `sudo nft -f /etc/nftables.conf`. The load
is atomic, so there's never a moment with no firewall.

Tests from Shrek, all passed:

1. New SSH session to 192.168.50.1 connected
2. Web pages loaded
3. `ipconfig /release` + `/renew` got 192.168.50.165 back from dnsmasq
4. Speed test hit 875 / 732 Mbps, with `OFFLOAD` counts of 52 to 64

## 2026-09-16: eth1 hang under full load

### What happened

Ran a second speed test. Download reached about 900 Mbps, then partway
through the upload everything stopped. SSH to 192.168.50.1 timed out. The
HDMI console was already plugged in, so I diagnosed from there instead of
rebooting (a reboot would have wiped the evidence).

### Ruling things out

| Check | Result | Meaning |
|---|---|---|
| `ip -br addr` | eth1 UP with 192.168.50.1 | Interface looked fine |
| `vcgencmd get_throttled` | `0x0` | No undervoltage, power ruled out |
| `ping -c 3 1.1.1.1` | Replies | Pi still had internet over eth0 |
| `dmesg` | Nothing from the adapter | Driver hung without logging |

So the Pi was healthy and the problem was between Shrek and the Pi.

### Finding the actual failure

With Shrek running `ping -t 192.168.50.1`, I checked eth1 repeatedly:

- **RX packets frozen at 25268194** across every check
- **RX errors climbing**, about 822k to 979k while stuck
- **TX packets frozen** too
- `ip neigh show dev eth1` showed Shrek as **FAILED**
- The firewall's `input dropped` counter **stayed at 498**

Shrek showed "Destination host unreachable" coming from its own address,
which is Windows saying it can't resolve the Pi's MAC address.

Frames were arriving at the adapter and getting rejected before reaching
the system, and nothing was going out. The firewall never saw any of it.
**Firewall ruled out. The USB adapter was hung while still reporting UP.**

### The adapter

```
lsusb:       0b95:1790 ASIX Electronics Corp. AX88179 Gigabit Ethernet
ethtool -i:  driver: cdc_ncm
```

I'd assumed a Realtek RTL8153. It's an ASIX AX88179 running on the generic
CDC NCM driver. That matters for OpenWrt later, since it needs a different
driver package than the Realtek one.

### Recovery

- `ip link set eth1 down` / `up` plus `nmcli con up lan`: **did not work.**
  Counters stayed frozen.
- Physical unplug and replug: **worked instantly.** The interface came back
  as a new device (index 4 changed to 5, counters reset).
- The flowtable had to be reloaded afterward, since it was attached to the
  old eth1 that disappeared.

A software replug does the same thing as pulling the cable:

```
echo 0 | sudo tee /sys/bus/usb/devices/2-2/authorized
echo 1 | sudo tee /sys/bus/usb/devices/2-2/authorized
sudo nft -f /etc/nftables.conf
```

### Trying to reproduce it

Ran speed tests back to back under the same conditions, with `top` open in
two sessions. Hit 903 / 724 Mbps. No hang. The problem is intermittent, so
chasing it with speed tests could take days. Decided to build automatic
recovery instead and let the logs show how often it happens.

### Lesson on testing

Shrek's WiFi was also connected to the amenity network, so Windows had two
default gateways. Speeds proved the tests went through the Pi, but WiFi goes
off during testing from now on so every result is clean.

## 2026-09-16: Making the firewall permanent

Retired the old iptables setup:

```
sudo systemctl disable netfilter-persistent
sudo apt remove iptables-persistent netfilter-persistent
```

### Boot-order drop-in

The flowtable needs eth0 and eth1 to exist when the file loads, and
nftables starts very early in boot. If the USB adapter shows up late, the
whole file fails, and the Pi boots with no firewall and no NAT. Added a
drop-in so the service waits for both interfaces:

`/etc/systemd/system/nftables.service.d/wait-for-nics.conf`

```
[Unit]
Wants=sys-subsystem-net-devices-eth0.device sys-subsystem-net-devices-eth1.device
After=sys-subsystem-net-devices-eth0.device sys-subsystem-net-devices-eth1.device
```

### Reboot test, passed

- `systemctl status nftables`: active, drop-in listed, exit status 0
- `nft list ruleset`: full ruleset with the flowtable on both ports
- `systemd-analyze`: 21.5s total boot, so the wait costs nothing noticeable
- `OFFLOAD` count climbed to 66 during a speed test after a cold boot

Side note: `systemctl status` opens a pager and redraws on every window
resize, which filled my terminal with repeats. `q` exits it, or use
`--no-pager`.

## 2026-09-16: eth1 watchdog

### What it does

`/usr/local/sbin/eth1-watchdog.sh`, run as `eth1-watchdog.service`.

Every 20 seconds it reads eth1's counters from
`/sys/class/net/eth1/statistics`. The hang signature is RX packets not
moving while RX errors or drops keep climbing. Two strikes in a row (about
40 seconds) triggers recovery:

1. Find the adapter's USB address from the interface itself, so it still
   works if the adapter moves ports
2. Software replug through `authorized` 0 then 1
3. Wait up to 30 seconds for eth1 to come back
4. `nmcli con up lan`
5. `nft -f /etc/nftables.conf` to reattach the flowtable
6. Log both the detection and the recovery under the `eth1-watchdog` tag

Requiring errors to climb, not just packets to stop, keeps it from firing
when the LAN is simply idle.

### Testing it

Can't make the adapter hang on demand, so the script has a
`--test-recover` flag that runs the recovery step by itself. With Shrek
pinging the Pi, ran it from the console. Shrek dropped briefly and came
back, both log lines showed in `journalctl -t eth1-watchdog`, and `OFFLOAD`
was above zero on the next speed test, so the firewall reload worked.

To see if it ever fires for real:

```
journalctl -t eth1-watchdog --no-pager
```

## 2026-09-16: Pi-hole replaces dnsmasq

### Why

Pi-hole v6 runs its own DNS and DHCP engine (pihole-FTL, which has dnsmasq
built in). Running both would fight over ports 53 and 67, so Pi-hole takes
over both jobs and the standalone dnsmasq service is retired.

### Before the switch

Recorded what dnsmasq was doing so nothing got lost:

```
interface=eth1
bind-dynamic
dhcp-range=192.168.50.100,192.168.50.200,24h
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1
server=1.1.1.1
server=8.8.8.8
no-resolv
cache-size=1000
stop-dns-rebind
rebind-localhost-ok
```

Backed it up to the repo as `dnsmasq.conf.pre-pihole`.

Other checks before starting:

- `/etc/resolv.conf` points at the building's DNS servers, not 127.0.0.1.
  The Pi doesn't depend on its own DNS, so stopping dnsmasq couldn't break
  the installer's downloads. Keeping it this way on purpose: if Pi-hole
  breaks, the Pi can still reach the internet to fix itself.
- Ports 80 and 443 were free for Pi-hole's built-in web server.
- 24 GB free on the SD card.

### Install

1. Added a firewall rule so the dashboard is reachable from the LAN only:
   ```
   iifname "eth1" tcp dport { 80, 443 } accept
   ```
2. `sudo systemctl disable --now dnsmasq` to free port 53. Shrek's 24h
   lease covered the short gap with no DHCP server.
3. `curl -sSL https://install.pi-hole.net | bash`
   - Interface: eth1
   - Upstream: Cloudflare
   - Blocklist: StevenBlack's Unified Hosts (80,170 domains)
   - Web interface on, query logging on, privacy level 0

Installed Pi-hole v6.4.3, web v6.6.

**Installer quirk:** it printed 192.168.1.149 as the Pi-hole address even
though I picked eth1. That's eth0's address. The installer guesses from the
default route, which goes out eth0. It's only a display message, and every
real setting points at 192.168.50.1.

**Listening scope:** after install, pihole-FTL was answering on all
interfaces. The firewall already blocked DNS on eth0 and wlan0, but I locked
Pi-hole to eth1 as well so there are two layers.

### Configuration

Pi-hole v6 takes settings from the command line, so nothing was pasted
into config files.

```
# DNS on eth1 only
sudo pihole-FTL --config dns.interface eth1
sudo pihole-FTL --config dns.listeningMode SINGLE

# Upstream: Cloudflare + Quad9
sudo pihole-FTL --config dns.upstreams '["1.1.1.1","1.0.0.1","9.9.9.9","149.112.112.112"]'

# Local domain, rebind protection, shorter query history
sudo pihole-FTL --config dns.domain.name home.arpa
sudo pihole-FTL --config misc.dnsmasq_lines '["stop-dns-rebind","rebind-localhost-ok"]'
sudo pihole-FTL --config database.maxDBdays 30

# DHCP, same settings as the old dnsmasq
sudo pihole-FTL --config dhcp.start 192.168.50.100
sudo pihole-FTL --config dhcp.end 192.168.50.200
sudo pihole-FTL --config dhcp.router 192.168.50.1
sudo pihole-FTL --config dhcp.netmask 255.255.255.0
sudo pihole-FTL --config dhcp.leaseTime 24h
sudo pihole-FTL --config dhcp.ipv6 false
sudo pihole-FTL --config dhcp.active true
```

Why these choices:

- **Quad9** (9.9.9.9) replaced Google. It blocks known malware and phishing
  domains before Pi-hole's lists even run.
- **home.arpa** is the official standard name for home networks. DHCP
  clients now get it as their DNS suffix.
- **Rebind protection** carried over from dnsmasq. It stops a website from
  tricking a browser into attacking devices on the LAN.
- **30 days of query history** instead of 91 cuts down on SD card writes.
- **SINGLE mode instead of BIND:** SINGLE still opens sockets on 0.0.0.0 but
  only answers queries that arrive on eth1. BIND would lock the sockets to
  eth1's address, which can break when the interface disappears and comes
  back. The eth1 watchdog does exactly that when it replugs the adapter, so
  SINGLE is the safer fit.

Changed the admin password with `sudo pihole setpassword`, since the
installer's random one was printed to the terminal.

Side note: `pihole status` without sudo printed permission warnings about
`/etc/pihole/pihole.toml`. Harmless. Use `sudo pihole status`.

### DNS redirect for hardcoded DNS

Some devices ignore DHCP and query 8.8.8.8 or similar directly, which
would skip ad blocking. Added a prerouting chain to the nat table that
sends any DNS query from the LAN to Pi-hole, whatever address it was aimed
at:

```
chain prerouting {
  type nat hook prerouting priority dstnat; policy accept;
  iifname "eth1" ip daddr != 192.168.50.1 udp dport 53 redirect to :53
  iifname "eth1" ip daddr != 192.168.50.1 tcp dport 53 redirect to :53
}
```

My SSH session dropped right after reloading the firewall. This also
happened on the very first nftables apply. Reconnecting works fine, so it's
not a problem, but it's worth knowing that any `nft -f` reload (including
the one the watchdog runs) will kick existing SSH sessions.

### Verification

Pi side:

- `ss` shows pihole-FTL owning 53 (DNS) and 67 (DHCP), with 80 and 443 for
  the dashboard
- `pihole-FTL --config dhcp` matches the settings above

From Shrek, with WiFi off:

| Test | Result | Meaning |
|---|---|---|
| `ipconfig /renew` | 192.168.50.165, gateway and DNS 192.168.50.1 | Pi-hole DHCP works |
| DHCP Server field | 192.168.50.1, suffix `home.arpa` | Lease came from Pi-hole |
| `nslookup doubleclick.net` | `0.0.0.0` from pi.hole | Blocking works |
| `nslookup doubleclick.net 8.8.8.8` | `0.0.0.0` | Redirect caught a query aimed at Google |
| `nslookup google.com` | Real addresses | Normal lookups work |

The second test is the fun one. Windows reports asking `dns.google`, but the
Pi intercepted the query and Pi-hole answered with a block.

## 2026-09-17: AX55 access point, WiFi is live

### Why

The Pi has one LAN port, so it could only serve one wired device. The
TP-Link Archer AX55 fills two gaps at once: it's the WiFi radio and the
switch. In access point mode its WAN port gets bridged with its four LAN
ports, so everything behind it lands on 192.168.50.0/24 and gets addresses
and DNS from Pi-hole.

### Topology

```
wall jack -> [eth0] Pi [eth1] -> AX55 WAN port
                                 AX55 LAN ports -> Shrek, future wired gear
                                 AX55 WiFi      -> phone, laptops, TV
```

TP-Link's instructions for access point mode say to use the WAN port to
connect to the existing network, which feels backwards but is correct.
NAT, QoS, and parental controls turn off in this mode, which is the point:
the Pi does all of that.

### Setup order

Configured the AX55 by itself first, with nothing in its WAN port, so two
DHCP servers were never on the same wire.

1. Firmware check, then admin password
2. Advanced, then System, then Operation Mode, set to **Access Point**
3. Wireless settings (see below)
4. Network, then LAN, set to **Static IP**:
   - IP 192.168.50.2, mask 255.255.255.0
   - Gateway and Primary DNS both 192.168.50.1
5. **DHCP Server: Off**
6. Cabled Pi eth1 to the AX55 WAN port, moved Shrek to an AX55 LAN port

Static IP matters here. On DHCP, the management page would move around and
I'd have to hunt for it each time.

### Gotcha: Auto DHCP didn't step aside

The AX55's DHCP server was set to **Auto**, which is supposed to detect
another DHCP server and disable itself. It didn't. Shrek was holding
192.168.50.87 with a 2-hour lease, while Pi-hole hands out .100 to .200
with 24-hour leases, so that address came from the AX55.

With two DHCP servers on one network, devices get settings from whichever
answers first, and anything served by the AX55 skips Pi-hole entirely.
Setting DHCP to **Off** explicitly fixed it. After a release and renew,
Shrek came back on 192.168.50.165 with DHCP server 192.168.50.1.

Lesson: don't trust "Auto" to detect another DHCP server. Turn it off by
hand and verify with `ipconfig /all` on a client.

### Wireless settings and why

| Setting | Value | Reason |
|---|---|---|
| Smart Connect | On | One network name, router picks the band per device |
| Security | WPA3-Personal + WPA2-PSK | New devices get WPA3, old ones still connect |
| Password | Long passphrase | WPA2 handshakes can be cracked offline, so length matters more than symbols |
| 2.4 GHz width | 20 MHz | Apartment building. 40 MHz overlaps more neighbors and loses to interference |
| 5 GHz width | 20/40/80 MHz | Plenty of room up there |
| OFDMA | On | WiFi 6 feature, talks to several devices in one transmission |
| WMM | On | Traffic prioritization, needed for full throughput |
| AP Isolation | Off | Devices need to see each other for printing and casting |
| TWT | Off | Battery saving for IoT, can add latency, nothing here benefits yet |
| WPS | Off | Push-button pairing has known weaknesses |
| Flow Control | Left at default | The router's own note warns it can cause drops |
| Access Control | Off | MAC filtering is trivial to bypass and annoying to maintain |

If a 2.4 GHz-only smart device ever refuses to pair, turn Smart Connect off
during setup and back on after.

**Follow-up, 09-19:** Smart Connect turned out to be the cause of a bad WiFi
speed result. See the band split entry below.

## 2026-09-17: Two Pi-hole warnings cleared

The Pi-hole diagnosis page had two messages. Both were harmless, and one
was a security feature working as intended.

### "interface eth1 does not currently exist"

A startup race. pihole-FTL started before the USB adapter finished coming
up. SINGLE listening mode recovers on its own once the interface appears,
which is why DNS worked anyway. Fixed permanently with the same trick used
for the firewall:

`/etc/systemd/system/pihole-FTL.service.d/wait-for-eth1.conf`

```
[Unit]
Wants=sys-subsystem-net-devices-eth1.device
After=sys-subsystem-net-devices-eth1.device
```

### "possible DNS-rebind attack detected: dns.msftncsi.com"

This was `stop-dns-rebind` doing its job. It rejects DNS answers that point
at private addresses, since that's how a website can trick a browser into
reaching devices inside the LAN. The domain involved is what Windows uses
to check whether it has internet, and the timing matched Shrek reconnecting
after the AP change.

The only symptom is Windows sometimes showing "no internet" while
everything works. Allowed those two Microsoft domains while keeping rebind
protection everywhere else:

```
sudo pihole-FTL --config misc.dnsmasq_lines '["stop-dns-rebind","rebind-localhost-ok","rebind-domain-ok=/msftncsi.com/msftconnecttest.com/"]'
sudo systemctl restart pihole-FTL
```

Both messages cleared and haven't come back.

### Verification

From Shrek, wired through the AX55:

- 192.168.50.165, gateway and DNS 192.168.50.1, 24-hour lease, `home.arpa`
  suffix
- `nslookup doubleclick.net` returns `0.0.0.0`, so blocking works through
  the AP

Three speed tests back to back:

| Run | Down | Up | Ping |
|---|---|---|---|
| 1 | 891.3 | 705.5 | 3 ms |
| 2 | 882.2 | 725.6 | 3 ms |
| 3 | 885.0 | 740.2 | 3 ms |

No measurable loss from adding the AP to the path, and no adapter hang
across all three.

From the Pi-hole dashboard:

- Shrek, the iPhone, and 192.168.50.2 (the AX55 itself) all appear as DNS
  clients, so even the access point uses Pi-hole
- The iPhone had 113 blocked queries within its first session on WiFi

## 2026-09-18: Security audit

Went through the repo and the running system looking for anything exposed.

- **Repo is clean.** `git ls-files` shows only config files, scripts, and
  docs. No passwords, keys, or tokens in any file or in git history. My
  offline cruise guide (which has a password in it) was never committed.
- **`.gitignore` extended** with `pihole.toml` and `*.img`, so a Pi-hole
  config or an SD image can't get committed by accident.
- **avahi-daemon disabled** (service and socket). Nothing on the network
  needs mDNS from the router.
- **Pi-hole NTP (port 123) disabled.** It only helps if clients get DHCP
  option 42, and most devices ignore that anyway.

## 2026-09-19: SSH password login was back on

### What I found

`sudo sshd -T` showed `passwordauthentication yes`. I disabled password
login back on 09-11, so something reverted it, most likely the Trixie
upgrade. With a short console password, that meant anyone on the WiFi could
try to brute-force SSH.

### First fix didn't work

Created `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

After a restart, `PermitRootLogin` and `KbdInteractiveAuthentication` took
effect, but `PasswordAuthentication` was still `yes`.

### Why

Files in `sshd_config.d/` load in alphabetical order, and **for sshd the
first value it sees wins**. Raspberry Pi Imager's `50-cloud-init.conf` sets
`PasswordAuthentication yes` and loads before anything named `99-`. So `99-`
is the weakest position, not the strongest. This is the opposite of how
`/etc/sysctl.d/` behaves, where I used a `99-` prefix on purpose so it would
load last and win.

Side note: `cat` on that file gave "Permission denied". SSH config files
are root-only, so it needs `sudo cat`.

### Fix

```
sudo mv /etc/ssh/sshd_config.d/99-hardening.conf /etc/ssh/sshd_config.d/00-hardening.conf
sudo sshd -t
sudo systemctl restart ssh
sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin|kbdinteractive'
```

```
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
```

Kept the working session open and confirmed a brand new SSH session still
got in with my key before closing it.

Lesson worth keeping: an OS upgrade can quietly undo hardening. Re-running
`sshd -T` after any major upgrade is now part of the routine.

## 2026-09-19: Power outage recovery

The power in my room went out overnight, so the Pi went through an
unplanned hard shutdown and cold boot. Good accidental test. Checked
everything came back:

| Check | Result |
|---|---|
| `systemctl --failed` | 0 units |
| `nft list ruleset` | Full ruleset loaded, flowtable on eth0 + eth1 |
| pihole-FTL, eth1-watchdog | Both active |
| `ip -br addr` | eth1 holding 192.168.50.1 |
| `journalctl -b -p err` | Only harmless alsa/bluetooth/wpa noise |
| DNS and ad blocking from Shrek | Working |

`dmesg` showed `EXT4-fs (mmcblk0p2): orphan cleanup on readonly fs`. That's
the filesystem journal replaying after the unclean shutdown. It means the
recovery worked and nothing was lost. The kernel command line already has
`fsck.repair=yes`, and I set `sudo touch /forcefsck` so the next reboot
runs a full check.

The Argon case jumper set to Always ON (09-13) did its job here. The Pi came
back on its own with no button press.

**Confusing timestamps:** `uptime` said about 3 hours, but systemd said the
services started 9 hours ago. The Pi has no real-time clock. At boot it
restores a saved time from fake-hwclock, services get stamped with that
stale time, then NTP jumps the clock forward. `uptime` uses a monotonic
counter, so it's the one to trust. Timestamps from the first seconds of a
boot are unreliable.

## 2026-09-19: vnstat

Turned out vnstat was already installed and collecting since 7/25, so
`sudo systemctl enable --now vnstat` just confirmed it. Already had about
159 GiB of September traffic on eth0.

```
vnstat -i eth0
```

## 2026-09-19: Tailscale subnet router

### Why Tailscale

eth0 has a private address behind the building's NAT, so a plain WireGuard
server can't be reached from outside. Tailscale runs WireGuard underneath
and gets through NAT without port forwarding. As a subnet router, it lets
me reach the whole 192.168.50.0/24 LAN from anywhere, not just the Pi.

### Install

```
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-routes=192.168.50.0/24 --accept-dns=false
```

Installed Tailscale 1.102.4 from the official Debian trixie repo.

`--accept-dns=false` matters here. Without it Tailscale would rewrite
`/etc/resolv.conf` to point at MagicDNS. The Pi should keep resolving
through upstream servers, not through itself or Tailscale, for the same
reason recorded during the Pi-hole install: if Pi-hole breaks, the Pi can
still reach the internet to fix itself.

In the Tailscale admin console:

- Approved the 192.168.50.0/24 subnet route. Advertising and approving are
  separate steps, and the route does nothing until it's approved.
- Disabled key expiry on pirouter, so remote access doesn't silently die
  in 180 days at the exact moment I can't walk over and fix it.

Left subnet route SNAT at its default. LAN devices don't know the 100.x
range exists, and SNAT makes remote traffic look like it comes from
192.168.50.1 so replies find their way back.

### Warnings from `tailscale up`

- **IPv6 forwarding disabled:** ignored. The LAN is IPv4 only and Pi-hole's
  DHCP has IPv6 off.
- **UDP GRO forwarding suboptimal on eth0:** fixed, see below.

### Firewall rules

My forward chain is policy drop. When more than one base chain sits on the
same hook, a packet has to survive all of them, so Tailscale's own accept
rules aren't enough on their own. Without my rules, remote traffic dies
quietly.

Backed up first (`/etc/nftables.conf.pre-tailscale`), then added:

Input chain:

```
iifname "tailscale0" tcp dport { 22, 80, 443 } accept
iifname "tailscale0" udp dport 53 accept
iifname "tailscale0" icmp type echo-request accept
iifname "eth0" udp dport 41641 accept
```

Forward chain:

```
iifname "tailscale0" oifname "eth1" accept
iifname "eth1" oifname "tailscale0" accept
```

UDP 41641 is Tailscale's direct connection port. Behind building NAT it
may not help, but if it does, traffic goes direct instead of relaying
through Tailscale's DERP servers.

**Placement gotcha:** I inserted the lines with `sed '/hook forward/r ...'`,
which put the forward rules right after the chain header, above
`ct state invalid drop`. That meant Tailscale traffic skipped the invalid
check. Moved them in nano to sit after the `ct state` lines, next to the
LAN-to-internet rule. The same sed also left one line with the wrong
indent, because my cleanup only matched lines starting with
`iifname "tailscale0"`. `sed ... r` inserts after the *matched* line, not
where the rule logically belongs.

Always `sudo nft -c -f /etc/nftables.conf` before the real reload. The
reload still kicks existing SSH sessions.

### NetworkManager was managing tailscale0

`nmcli connection show` listed `tailscale0`. tailscaled creates and owns
that interface, sets its addresses and installs its routes, so having
NetworkManager also manage it can cause fights on restart. Told NM to leave
it alone:

`/etc/NetworkManager/conf.d/99-tailscale.conf`

```
[keyfile]
unmanaged-devices=interface-name:tailscale0
```

After `sudo systemctl reload NetworkManager`, tailscale0 dropped off the
list. Same class of problem as `netplan-eth0` back on 09-13: two things
managing one interface.

### UDP GRO

Without GRO forwarding, forwarded UDP through the tunnel gets handled one
packet at a time instead of in batches, which costs real throughput on a
Pi 4. The ethtool setting doesn't survive a reboot, so it runs as a oneshot
unit before tailscaled:

`/etc/systemd/system/tailscale-gro.service`

```
[Unit]
Description=Set UDP GRO forwarding on eth0 for Tailscale
After=network-online.target
Wants=network-online.target
Before=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Verified with `systemctl status tailscale-gro` (active, exited, status 0)
and `ethtool -k eth0 | grep udp-gro-forwarding` (on).

### Phone access

Installed Tailscale and Termius on my iPhone. Since password login is off,
generated an ED25519 key in Termius and added its public key to
`~/.ssh/authorized_keys` on the Pi. Checked permissions: `.ssh` at 700,
`authorized_keys` at 600, both owned by psaliba. Wrong modes make sshd
ignore the file silently, which is the same failure shape as the empty
`authorized_keys` from 09-11.

`sudo ssh-keygen -lf ~/.ssh/authorized_keys` confirms every line is a real
key without printing the keys themselves. A valid ed25519 public key has 68
characters in its middle field, which is an easy way to spot a truncated
paste.

Accepted the host fingerprint on first connect after checking it against
`ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub` on the Pi.

### Testing, WiFi off, phone on cellular

| Test | Result | Proves |
|---|---|---|
| SSH to the Pi's tailnet address | Connected | Tunnel and key auth work |
| Safari to 192.168.50.1/admin | Pi-hole loaded | Subnet route works |
| Safari to 192.168.50.2 | AX55 loaded | Other LAN devices reachable |

The last two are the real proof. Reaching a 192.168.50.x address from
cellular means the subnet route is approved and the forward rules pass
traffic. SSH to the 100.x address alone would only prove the tunnel.

### iCloud Private Relay

iOS warned that Private Relay doesn't work on my network. Expected. The
DNS redirect intercepts port 53, and Private Relay is built to skip the
local resolver. If Relay were on, the iPhone would bypass Pi-hole entirely
for Safari and its DNS, so no ad blocking, no query log, no local
`home.arpa` names. Decided to leave Private Relay off for this network.
iOS only allows one VPN at a time anyway, so Tailscale and Relay can't both
run.

### Repo

Committed and pushed:

- `nftables.conf` (Tailscale rules)
- `tailscale-gro.service`
- `99-tailscale-nm.conf` (renamed from `99-tailscale.conf` so it's obvious
  it's a NetworkManager file, not a systemd unit)
- `00-hardening.conf` (sshd)

Nothing from `/var/lib/tailscale/` goes in the repo. That's where the node
key lives.

## 2026-09-19 to 09-20: WiFi band split

### The slow speed test

Shrek on WiFi right next to the AX55 got 78.7 / 74.6 Mbps. Wired through
the AP gets ~885. `netsh wlan show interfaces` explained it:

```
Band            : 2.4 GHz
Channel         : 2
Receive rate    : 286.8
Rssi            : -15
```

Smart Connect had put Shrek on 2.4 GHz, which I limited to 20 MHz for
apartment interference. 286.8 Mbps is the ceiling for 2x2 802.11ax at
20 MHz, and 2.4 GHz usually delivers about a quarter of the link rate in
real throughput, because the band is half duplex and shares airtime with
every neighbor. Near-symmetric up and down was the other clue that the
wireless link was the bottleneck rather than the ISP.

Why it picked 2.4: Smart Connect steers, the client decides. At -15 dBm
both bands look perfect to the adapter, so there's no signal-quality reason
to prefer 5 GHz, and Windows keeps reaching for the BSSID it last used.

### Fix: separate SSIDs

Turned Smart Connect off and split into `5th Floor Wifi 2.4 GHz` and
`5th Floor Wifi 5 GHz`. Checked the Qualcomm adapter's Advanced properties
for a band preference setting first, but WiFiCx drivers expose far fewer
properties than older ones. Splitting the SSIDs is the fix that always
works, and it costs nothing but automatic band switching, which barely
matters in one apartment.

Keeping 2.4 GHz on. IoT devices, smart plugs and microcontrollers are often
2.4-only, some refuse to pair if the phone is on 5 GHz at the time, and the
lower frequency passes through walls better.

### The 5 GHz network disappeared

After the split, the 5 GHz SSID worked briefly, then stopped showing up at
all, while the AX55 UI reported the radio online on channel 149 (Auto).
Region was correctly set to United States.

Two theories, both wrong:

- **DFS:** 149 is not a DFS channel, so no radar avoidance involved.
- **Adapter can't see the upper UNII-3 channels:** a full scan showed Shrek
  seeing plenty of other networks on 149 through 161.

Also learned that `netsh wlan show networks` returns stale or partial
results while associated. The first scan showed exactly one network in an
apartment building, which can't be right. Disconnecting and scanning again
showed 31.

Pinning the channel to 36 fixed it. Most likely the 5 GHz radio wasn't
actually beaconing after the Smart Connect change, and setting the channel
forced a radio restart. Left it pinned rather than Auto, so it can't drift
back into whatever state that was.

### Tuning

- Channel width 20/40/80, so capable clients get 80 MHz and older ones fall
  back
- Airtime Fairness on, so one slow device can't drag the band down
- OFDMA on, TWT off, unchanged

Result on Shrek: 5 GHz, channel 36, 1201 Mbps link rate, 100% signal.

```
560.9 / 377.1 Mbps, 4 ms ping
629.96 / 423.08 Mbps, 6 ms ping
```

About half the link rate, which is normal for real WiFi once overhead,
retries and half-duplex airtime are accounted for. 1201 is the ceiling for
the AX55's 2x2 radio at 80 MHz, so there isn't much left on the table.

### Channel survey

The full scan is a good snapshot of the RF environment here:

- **36 to 48** (the block I'm in) is crowded. The building's own FastMesh
  APs have radios on 36, 40, 44 and 48, plus several neighbors and an
  xfinitywifi hotspot.
- **149 to 161** is also busy, with the mesh, two T-Mobile gateways and
  others.
- **100 to 128** is nearly empty. The few APs there report 1% channel
  utilization.

2.4 GHz is on channel 9, which overlaps both 6 and 11 rather than sitting
in one of the three non-overlapping slots. Moving it to 1, 6 or 11 is on
the list, low priority since that band only carries IoT.

## 2026-09-19: SD card image

New image after Tailscale was verified: `pirouter-2026-09-19-tailscale.img`.

## Current state

| Item | Status |
|---|---|
| WAN | eth0 on wall jack, private address behind building NAT |
| LAN | eth1 (ASIX AX88179, cdc_ncm), 192.168.50.1/24 |
| Switch and WiFi | AX55 in AP mode, static 192.168.50.2, DHCP off, cloud management off |
| WiFi bands | Split SSIDs: 2.4 GHz at 20 MHz, 5 GHz pinned to channel 36 at 20/40/80 |
| DHCP | Pi-hole, .100 to .200, 24h leases |
| DNS | Pi-hole on eth1, Cloudflare + Quad9 upstream, home.arpa |
| Ad blocking | StevenBlack Unified Hosts, 80,170 domains |
| DNS redirect | All LAN DNS forced through Pi-hole |
| Firewall | Native nftables, default drop, persistent, reboot tested |
| Flowtable | Persistent, verified after cold boot |
| Remote access | Tailscale subnet router, route approved, key expiry off |
| SSH | Key only, password and root login off via `00-hardening.conf` |
| Traffic stats | vnstat on eth0 |
| Throughput | ~885 / 740 wired through the AP, ~560 to 630 down on 5 GHz WiFi |
| Adapter hang | Intermittent, auto-recovered by eth1-watchdog |
| Power loss | Survived one unplanned outage with no intervention |
| Backup | `pirouter-2026-09-19-tailscale.img` |

The apartment runs entirely on this router. Wired and wireless clients get
addresses, DNS and ad blocking from the Pi, and the whole LAN is reachable
from outside over Tailscale.

## Next
1. Move 2.4 GHz off channel 9 to 1, 6 or 11
2. Try 5 GHz on a DFS channel (100 or 104) now that the radio is stable,
   and watch for the AP vacating the channel on a radar detection
3. M.2 SATA SSD ordered. Install it, move the root filesystem off the SD
   card, then revisit Grafana
4. Optional: RPS test to spread packet handling across cores
5. Later: OpenWrt v2 rebuild and comparison. OpenWrt has a Tailscale
   package, so remote access carries over. The LAN adapter needs the
   CDC NCM / AX88179 driver, not the Realtek one
