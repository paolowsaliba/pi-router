#!/bin/bash
# NAT and forwarding rules for the Pi router.
# Interface names are variables so switching uplinks is a one-line change.

WAN_IF="eth0"
LAN_IF="eth1"

# Rewrite outbound LAN traffic to look like it came from the Pi.
sudo iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE

# Let replies to connections we started come back in.
sudo iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# Let LAN clients reach the internet.
sudo iptables -A FORWARD -i $LAN_IF -o $WAN_IF -j ACCEPT
