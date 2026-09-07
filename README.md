# Raspberry Pi Router

A working home router built from a Raspberry Pi 4 running Raspberry Pi OS Lite.
It handles DHCP, DNS caching, NAT, and firewalling for an apartment network that
sits behind a building-provided internet connection.

The interesting part of this project is not that a Pi can route packets. It is
the constraints: an apartment with two unrelated networks in the walls, a
captive portal, a gigabit uplink that outruns the hardware doing the routing,
and no console access for most of the build.

**Status:** LAN interface, DHCP, and DNS working and tested against real
hardware. NAT, WAN cutover, and firewall in progress.

---

## Hardware

- Raspberry Pi 4 Model B (4GB)
- Built-in Gigabit Ethernet (`eth0`) — WAN
- UGREEN USB 3.0 to Gigabit Ethernet adapter (`eth1`) — LAN
- Built-in wifi (`wlan0`) — internet fallback only, see below
- Argon ONE M.2 case
- Samsung Pro Endurance 32GB microSD

---

## Topology

```
  Building uplink
        |
  [ wall jack ]                        ~885 Mbps down / 735 up
        |
   eth0 (WAN)
        |
  +-----------------------------+
  |  Raspberry Pi 4             |
  |  NAT, DHCP, DNS, firewall   |     wlan0 --- amenity wifi
  |  LAN gateway 192.168.50.1   |              (internet only,
  +-----------------------------+               client isolated)
        |
   eth1 (LAN, USB adapter)
        |
  [ access point ]  <- planned, Wi-Fi 6
        |
    my devices                          192.168.50.100 - .200
```

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

The amenity network runs client isolation. Two devices with addresses in the
same `/16` cannot reach each other, only the internet. So `wlan0` gives the Pi a
route out, but it cannot be used to SSH in when the wired side is down. Local
console is the only real recovery path for the firewall step.

---

## Config files

| File | What it does |
|---|---|
| `lan-setup.sh` | The `nmcli` command that gives `eth1` its static `192.168.50.1` |
| `dnsmasq.conf` | DHCP server and caching DNS resolver for the LAN |
| `firewall.sh` | NAT masquerade and iptables rules. Interface names are variables at the top |
| `.gitignore` | Keeps NetworkManager profiles and keys out of the repo |

### dnsmasq notes

`interface=eth1` with `bind-interfaces` keeps DHCP on the LAN side only. Without
it, dnsmasq would offer addresses on the WAN interface too, which would mean
handing out leases on the building's network.

`no-resolv` is there for a specific reason. Without it, dnsmasq reads
`/etc/resolv.conf` on startup and picks up whatever DNS server `wlan0` got from
the amenity network's DHCP, adding it as a third upstream. Some queries would
then leave through the building's resolver. `no-resolv` restricts it to the
servers named in the config.

### firewall.sh notes

Interface names are variables:

```bash
WAN_IF="eth0"
LAN_IF="eth1"
```

This matters because the WAN has already moved once during this build, from a
planned wifi uplink to a wired jack. Keeping the names in one place means
switching uplinks is a one-line change instead of a rewrite.

---

## Things worth knowing if you rebuild this

**The `dhcpcd.conf` instructions in most Pi router tutorials are dead.** Current
Raspberry Pi OS uses NetworkManager. Editing that file silently does nothing.
Use `nmcli` instead.

**Files in `/etc/netplan/` are not necessarily netplan config.** On this OS,
NetworkManager exports a YAML alongside each connection it creates. They carry
`renderer: NetworkManager` and the NM UUID. The real config lives in
`/etc/NetworkManager/system-connections/`, and those files contain wifi PSKs in
plain text, so keep them out of version control.

**Do not trust interface names.** `ethtool -i <iface>` and its `bus-info` line
is the ground truth. A platform address means built-in, a USB path means an
adapter.

**When you reconfigure the interface you are connected over, chain the
commands.** `nmcli con add ... && nmcli con up lan` completes even after the
session drops. Then bootstrap back in with a temporary static address on the
client, since DHCP is not running yet.

**Use the fixed address, not mDNS.** `pirouter.local` was unreliable throughout,
especially once the Pi had two active networks.

---

## Performance

The uplink outruns the router, which makes throughput a real part of this
project rather than an afterthought.

Baseline measured at the wall with no VPN, at peak hours: **885 Mbps down,
735 up, 1ms ping.**

A Pi 4 doing NAT with standard iptables rules typically lands somewhere between
600 and 800 Mbps, because every packet is evaluated against the full rule chain.
The plan is to measure three ways and write down all three numbers: at the wall,
through the Pi with iptables, and through the Pi with nftables flow offload,
which lets the kernel shortcut established connections.

---

## Remaining work

- [ ] Enable IP forwarding and apply the NAT rule
- [ ] Cut `eth0` over to the fast jack and verify a LAN client reaches the internet
- [ ] Measure throughput through the router against the 885 baseline
- [ ] Convert to nftables with flow offload and re-measure
- [ ] Arm the default-drop firewall (requires console gear on hand)
- [ ] Add a Wi-Fi 6 access point on the LAN side
- [ ] Confirm who owns gateway `192.168.1.1` and whether that jack is mine

Later ideas: Pi-hole for network-wide ad blocking, Tailscale for remote access
(port forwarding is unavailable behind the building's NAT), and `vnstat` for
traffic history.
