# Raspberry Pi Router

A working home router built from a Raspberry Pi 4 running Raspberry Pi OS Lite.
It handles DHCP, DNS, ad blocking, NAT, firewalling, and remote access for an
apartment network that sits behind a building-provided internet connection.

The interesting part of this project is not that a Pi can route packets. It is
the constraints: an apartment with two unrelated networks in the walls, a
captive portal, a gigabit uplink that outruns the hardware doing the routing,
no public IP to forward ports to, and no console access for most of the build.

**Status:** in daily use. Every device in the apartment, wired and wireless,
gets its address, DNS, and ad filtering from this Pi, and the whole LAN is
reachable from outside over Tailscale.

---

## Hardware

- Raspberry Pi 4 Model B (4GB)
- Built-in Gigabit Ethernet (`eth0`), WAN
- UGREEN USB 3.0 to Gigabit Ethernet adapter (`eth1`), LAN
  - ASIX AX88179 on the `cdc_ncm` driver, confirmed with `lsusb`
- Built-in wifi (`wlan0`), backup internet path only
- TP-Link Archer AX55 in access point mode, WiFi 6 radio and 4-port switch
- Argon ONE M.2 case
- Samsung Pro Endurance 32GB microSD

---

## Topology

```
  Building uplink
        |
  [ wall jack ]                        ~885 Mbps down / 735 up
        |
   eth0 (WAN, 192.168.1.x from the building)
        |
  +-----------------------------+
  |  Raspberry Pi 4             |
  |  nftables firewall + NAT    |     wlan0 --- amenity wifi
  |  Pi-hole: DHCP, DNS, ads    |              (internet only,
  |  Tailscale subnet router    |               client isolated)
  |  LAN gateway 192.168.50.1   |
  +-----------------------------+
        |
   eth1 (LAN, USB adapter)
        |
  [ Archer AX55 ]  192.168.50.2, access point mode, its DHCP off
     |        |
  LAN ports   WiFi (split 2.4 / 5 GHz SSIDs)
        |
    my devices                          192.168.50.100 - .200
```

---

## What it does

| Function | How |
|---|---|
| Routing and NAT | nftables, single `/etc/nftables.conf`, default drop on INPUT and FORWARD |
| Throughput | nftables flowtable (software flow offload) on eth0 and eth1 |
| DHCP and DNS | Pi-hole v6 (pihole-FTL), pool .100 to .200, 24h leases, `home.arpa` |
| Ad blocking | Pi-hole with StevenBlack Unified Hosts, plus a DNS redirect rule so hardcoded resolvers can't escape it |
| Upstream DNS | Cloudflare and Quad9 |
| WiFi and switching | Archer AX55 in AP mode on the LAN side |
| Remote access | Tailscale subnet router advertising 192.168.50.0/24 |
| Traffic history | vnstat on eth0 |
| Reliability | systemd watchdog that recovers the USB LAN adapter when it hangs |

---

## The environment

The apartment has three Ethernet jacks and they are not all on the same network.

**Fast jack.** Hands out addresses in `192.168.1.0/24` behind gateway
`192.168.1.1`, no captive portal, roughly 885 Mbps down and 735 up measured at
peak hours with a 1ms ping. This is the WAN uplink.

**Living room jack.** Hands out addresses in `10.254.0.0/16` behind gateway
`10.254.0.1`, runs a captive portal, roughly 90 Mbps. This is the building's
amenity network, fed through a provider-owned access point mounted on the wall
above the jack. That hardware is left alone.

The two are entirely separate. Diagnosing that took a while, because the obvious
first guess for the slow jack was a bad cable. The captive portal was the clue
that ruled it out.

**LAN subnet is `192.168.50.0/24`** specifically to avoid colliding with either
`192.168.1.0/24` upstream or `10.254.0.0/16` on the amenity side.

### The captive portal

`wlan0` stays joined to the amenity wifi as a secondary internet path. Getting
through the portal from a headless machine was solved by registering the Pi's
wifi MAC in the portal's own MAC authentication profile, which skips the login
page entirely. Verified with:

```
curl -s -o /dev/null -w "%{http_code}\n" http://connectivitycheck.gstatic.com/generate_204
```

A `204` means authenticated and clear. Anything else means the walled garden is
still in the way.

### Why the wifi is not a management path

The amenity network runs client isolation. Both the Pi and a laptop can sit on
`10.254.0.0/16` and still not reach each other. It is an internet path for the
Pi and nothing more, which is why an HDMI console and USB keyboard were bought
before arming a default-drop firewall.

### No public IP

`eth0` gets a private address from the building, so there is nothing to forward
a port to. That ruled out a plain WireGuard server and pointed at Tailscale,
which runs WireGuard underneath and traverses the NAT without port forwarding.

---

## Performance

The uplink outruns the router, which makes throughput a real part of this
project rather than an afterthought. Every number below was measured against the
same Speedtest server, in A-B-A order, so ISP variance would show up instead of
being credited to the router.

| Setup | Download | Upload |
|---|---|---|
| At the wall, no router | ~879 | ~736 |
| Through the Pi, iptables NAT | ~834 | ~711 |
| Through the Pi, nftables flowtable | ~889 | ~729 |
| Flowtable removed again | ~833 | ~698 |

**Routing through the Pi with plain iptables cost about 57 Mbps of download
(6.5%). The flowtable recovered essentially all of it.** The removed-again runs
matching the earlier iptables runs is what rules out the ISP simply being faster
that afternoon.

Verified that the shortcut was actually in use rather than inferring it from
throughput:

```
sudo conntrack -L 2>/dev/null | grep -c OFFLOAD
24    (flowtable loaded)
0     (after removal)
```

**The bottleneck is one core, not the CPU.** Per-core `top` showed nearly all
packet handling landing on core 0 as `ksoftirqd/0`, sitting at 94 to 100%
softirq during downloads while cores 1 to 3 stayed idle. The flowtable cut
upload softirq by about two thirds and let that same saturated core push ~55
Mbps more on download.

Adding the access point cost no measurable throughput: 882 to 891 down and 705
to 740 up wired through it.

---

## Files

| File | What it is |
|---|---|
| `nftables.conf` | The whole firewall: default drop, NAT, flowtable, DNS redirect |
| `wait-for-nics.conf` | systemd drop-in so nftables waits for both NICs at boot |
| `eth1-watchdog.sh` / `.service` | Detects and recovers the USB adapter hang |
| `99-router.conf` | sysctl drop-in enabling IP forwarding |
| `00-hardening.conf` | sshd: no passwords, no root login |
| `tailscale-gro.service` | Enables UDP GRO forwarding on eth0 at boot |
| `99-tailscale-nm.conf` | Tells NetworkManager not to manage `tailscale0` |
| `lan-setup.sh` | The nmcli commands that create the LAN profile |
| `dnsmasq.conf.pre-pihole` | The old dnsmasq config, kept for reference |
| `firewall.sh` | The original iptables script, superseded by nftables |
| `BUILD_LOG.md` | The full record: what broke, what I tried, what worked |

---

## Things worth knowing if you build one of these

**Tutorials point at files this OS no longer uses.** Both `/etc/dhcpcd.conf`
and `/etc/sysctl.conf` are gone on current Raspberry Pi OS, replaced by
NetworkManager and `/etc/sysctl.d/`. Nano happily opens a blank buffer for a
path that never existed, which makes a failed edit look like a successful one.

**Do not trust interface names.** `ethtool -i <iface>` and its `bus-info` line
are the ground truth. A platform address means built-in, a USB path means an
adapter.

**Drop-in load order is not the same everywhere.** In `/etc/sysctl.d/` a `99-`
prefix wins because it loads last. In `/etc/ssh/sshd_config.d/` the *first*
value wins, so a `99-` file loses to cloud-init's `50-` file. That silently
undid my SSH hardening after an OS upgrade.

**Two things managing one interface will bite you twice.** A leftover
NetworkManager profile with `match: {}` added two minutes to every boot, and
disabling it also killed the WAN, because it was quietly the only profile
giving eth0 an address. Later, NetworkManager tried to manage `tailscale0`,
which tailscaled owns. Same shape of problem.

**"Auto" DHCP detection does not work.** The access point's DHCP server was set
to Auto, which is supposed to stand down when it sees another DHCP server. It
did not, and clients were getting leases from the wrong device. Turn it off by
hand and verify from a client.

**When you reconfigure the interface you are connected over, chain the
commands.** `nmcli con add ... && nmcli con up lan` completes even after the
session drops.

**Read the logs instead of pattern-matching the symptom.** The two-minute boot
delay got two confident wrong diagnoses before the NetworkManager journal named
the cause on the first read.

---

## Remaining work

- [ ] Move 2.4 GHz off channel 9 onto 1, 6, or 11
- [ ] Try 5 GHz on a DFS channel (100 or 104), where the band is nearly empty
- [ ] Install the M.2 SATA SSD, move the root filesystem off the SD card
- [ ] Grafana dashboards once the SSD is in and disk writes are cheap
- [ ] RPS test, to see whether spreading packet handling across cores lifts the
      core-0 ceiling
- [ ] OpenWrt v2 rebuild on the same hardware, with a performance comparison
- [ ] Confirm who owns gateway `192.168.1.1`
