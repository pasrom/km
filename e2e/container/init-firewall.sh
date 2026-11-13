#!/bin/bash
# Default-deny egress for a role session, after Claude Code's reference devcontainer, tighter:
# - outbound only tcp/443 to an allowlist (ipset): GitHub's web, api and git ranges and the addresses of
#   the allowed names, both given by the driver, once per run (/opt/km-e2e/net/github-cidrs, from
#   api.github.com/meta; /opt/km-e2e/net/hosts, `address name` lines), each checked to be public;
# - those names pinned in /etc/hosts and DNS closed (port 53 rejected everywhere, no resolver): a lookup
#   cannot carry data out, and a name not pinned does not resolve;
# - nothing to the host network, the Docker gateway, private, link-local or metadata addresses; no SSH;
#   no IPv6 at all.
# Runs as root in the entrypoint; the session user has no capability to change it afterwards.
set -euo pipefail
IFS=$'\n\t'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # never the session's (the plugin's bin)
NET=/opt/km-e2e/net
SET=km-e2e-allow

ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
# no part of a public range may fall in these: this host, private, carrier-grade NAT, loopback, link-local
# (metadata), IETF, benchmarking, multicast and reserved
BLOCKED=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16
         198.18.0.0/15 224.0.0.0/3)
span() {   # $1: a CIDR; prints its first and last address as integers
  local net=${1%/*} len=${1#*/} mask
  mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
  local start=$(( $(ip2int "$net") & mask ))
  echo "$start $(( start | (~mask & 0xFFFFFFFF) ))"
}
public_v4() {   # $1: an address or CIDR; refuses everything that is not wholly a public IPv4 range
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]] || return 1
  local o len=${BASH_REMATCH[6]:-32} lo hi blo bhi
  for o in 1 2 3 4; do (( BASH_REMATCH[o] <= 255 )) || return 1; done
  (( len >= 8 && len <= 32 )) || return 1
  IFS=' ' read -r lo hi <<< "$(span "${1%/*}/$len")"
  for r in "${BLOCKED[@]}"; do
    IFS=' ' read -r blo bhi <<< "$(span "$r")"
    (( lo > bhi || hi < blo )) || return 1
  done
  return 0
}

declare -a pins=()
ipset create "$SET" hash:net
while IFS=' ' read -r ip host; do
  [ -n "$ip" ] || continue
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || { echo "firewall: bad host name '$host'" >&2; exit 1; }
  public_v4 "$ip" || { echo "firewall: $host at $ip, not a public address" >&2; exit 1; }
  ipset add -exist "$SET" "$ip"
  pins+=("$ip $host")
done < "$NET/hosts"
(( ${#pins[@]} > 0 )) || { echo "firewall: no allowed names" >&2; exit 1; }
n=0
while read -r cidr; do
  [ -n "$cidr" ] || continue
  public_v4 "$cidr" || { echo "firewall: '$cidr' is not a public IPv4 range" >&2; exit 1; }
  ipset add -exist "$SET" "$cidr"; n=$((n + 1))
done < "$NET/github-cidrs"
(( n > 0 )) || { echo "firewall: no GitHub ranges" >&2; exit 1; }

iptables -N KM_REJECT                  # every refusal passes here: its counter is the session's (Launcher.rejected)
iptables -A KM_REJECT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j KM_REJECT
iptables -A OUTPUT -p tcp --dport 53 -j KM_REJECT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set "$SET" dst -j ACCEPT
iptables -A OUTPUT -j KM_REJECT
if ip6tables -L >/dev/null 2>&1; then
  ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT DROP
  ip6tables -A INPUT -i lo -j ACCEPT; ip6tables -A OUTPUT -o lo -j ACCEPT
elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != 1 ]; then
  echo "firewall: no ip6tables and IPv6 is on" >&2; exit 1
fi

# the pinned names; nothing else resolves once port 53 is closed
printf '%s\n' "${pins[@]}" >> /etc/hosts
: > /etc/resolv.conf

# self-check: a public address off the list is refused at once
if curl -sS --connect-timeout 3 -o /dev/null https://1.1.1.1 2>/dev/null; then
  echo "firewall: 1.1.1.1 is reachable" >&2; exit 1
fi
iptables -Z                            # every counter (KM_REJECT's too) starts with the session
echo "firewall: ${#pins[@]} names, $n GitHub ranges; everything else refused"
