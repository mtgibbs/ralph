#!/usr/bin/env bash
set -euo pipefail
#
# Builder firewall: whitelist only Claude API, Statsig, and npm registry.
# Everything else is denied. Must run as root (called via sudo).
#

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true
iptables -F INPUT 2>/dev/null || true

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Allow established/related connections (responses to our outbound requests)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (needed to resolve hostnames before we can whitelist IPs)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Resolve and allow each whitelisted domain
ALLOWED_DOMAINS=(
    "api.anthropic.com"
    "statsig.anthropic.com"
    "registry.npmjs.org"
)

for domain in "${ALLOWED_DOMAINS[@]}"; do
    # Resolve all IPs for the domain
    ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
    for ip in $ips; do
        iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
        echo "[firewall] Allowed: $domain -> $ip:443"
    done

    # Also resolve CNAME targets (CDNs etc)
    cnames=$(dig +short "$domain" 2>/dev/null | grep -v -E '^[0-9]+\.' || true)
    for cname in $cnames; do
        cname_ips=$(dig +short "$cname" 2>/dev/null | grep -E '^[0-9]+\.' || true)
        for ip in $cname_ips; do
            iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
            echo "[firewall] Allowed: $domain (via $cname) -> $ip:443"
        done
    done
done

# Default deny all other outbound traffic
iptables -A OUTPUT -j DROP

echo "[firewall] Builder firewall initialized. Only API + npm registry allowed."
