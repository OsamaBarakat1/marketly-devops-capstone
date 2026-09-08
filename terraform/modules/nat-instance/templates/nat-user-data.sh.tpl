#!/bin/bash
# Turns a plain EC2 instance into a NAT device.
#
# Two things are required: the kernel must forward packets between
# interfaces, and outbound packets must be rewritten to carry this
# instance's address so replies come back here to be forwarded on.
set -euxo pipefail

# Forwarding survives reboots only if written to sysctl config, not just set
# at runtime.
cat > /etc/sysctl.d/99-nat.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
SYSCTL
sysctl -p /etc/sysctl.d/99-nat.conf

dnf install -y iptables-services
systemctl enable --now iptables

# Find the primary interface by name rather than assuming eth0, which
# differs across instance types and kernel versions.
PRIMARY_IF="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"

# Masquerade only traffic from inside the VPC. Without the source
# restriction this instance would happily forward for anyone who could route
# a packet to it.
iptables -t nat -A POSTROUTING -s ${vpc_cidr} -o "$PRIMARY_IF" -j MASQUERADE
iptables -A FORWARD -s ${vpc_cidr} -j ACCEPT
iptables -A FORWARD -d ${vpc_cidr} -m state --state ESTABLISHED,RELATED -j ACCEPT

service iptables save

echo "NAT instance ready, forwarding ${vpc_cidr} out via $PRIMARY_IF"
