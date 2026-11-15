#!/usr/bin/env bash
#
# CivSwitch Moonlight bridge — one-shot setup for Raspberry Pi OS Bookworm.
#
# Turns the Pi into the Switch's air-gapped Wi-Fi bridge for Moonlight:
#   * AP for the Switch (via NetworkManager)
#   * DHCP + catch-all DNS via dnsmasq (every name resolves to the Pi)
#   * HTTP server that mimics Nintendo's connectivity-check endpoints so the
#     Switch joins without a captive-portal popup
#   * IP forwarding ON, but locked down with nftables so the Switch can reach
#     ONLY the Sunshine host on the home LAN — and never the internet
#
# The Pi's Ethernet (ETH_IF) is the uplink to the home LAN / Sunshine PC.
#
# Usage:  sudo ./setup.sh
#
# NOTE: Untested on hardware — see README. Targets Raspberry Pi OS
# Bookworm (NetworkManager), not the older dhcpcd-based releases.

set -euo pipefail

# ── Config (edit these if you want) ────────────────────────────────
AP_SSID="Switch2Moonlight"
AP_PASSWORD=""               # empty = open network; set a WPA2 passphrase (8+ chars) to secure it
AP_BAND="bg"                 # "bg" = 2.4 GHz (any Pi); "a" = 5 GHz (Pi 4/5 — better for streaming)
AP_CHANNEL=6
AP_IP="192.168.4.1"          # Pi's address on the Switch's Wi-Fi network
AP_PREFIX=24
DHCP_START="192.168.4.2"     # Switch usually lands here
DHCP_END="192.168.4.50"
LAN_SUBNET="192.168.1.0/24"  # home-LAN subnet to allow — or a single Sunshine IP, e.g. 192.168.1.50
ETH_IF="eth0"                # uplink interface (home LAN, towards the Sunshine PC)
CON_NAME="Switch2Moonlight"
UPLINK_CON="Switch2Moonlight-uplink"
INSTALL_DIR="/opt/civswitch-moonlight"
SERVICE_NAME="civswitch-moonlight.service"
FW_SERVICE_NAME="civswitch-moonlight-firewall.service"
SYSCTL_FILE="/etc/sysctl.d/99-civswitch-moonlight.conf"
NFT_FILE="/etc/civswitch-moonlight.nft"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root:  sudo ./setup.sh" >&2
  exit 1
fi

if ! ip link show "$ETH_IF" >/dev/null 2>&1; then
  echo "ERROR: uplink interface '$ETH_IF' not found." >&2
  echo "List yours with 'ip link' (or 'nmcli device status'), then edit ETH_IF in setup.sh." >&2
  exit 1
fi

echo "== Installing packages (dnsmasq, python3, nftables) =="
apt-get update
apt-get install -y dnsmasq python3 nftables

PYTHON3="$(command -v python3)"
NFT="$(command -v nft)"

# Derive the AP subnet CIDR + netmask from AP_IP/AP_PREFIX (python3 is installed).
read -r AP_SUBNET NETMASK < <(python3 - "$AP_IP" "$AP_PREFIX" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False)
print(net.with_prefixlen)
print(net.netmask)
PY
)

echo "== Creating the AP in NetworkManager =="
nmcli con del "$CON_NAME" 2>/dev/null || true
nmcli con add type wifi ifname wlan0 con-name "$CON_NAME" ssid "$AP_SSID"
nmcli con modify "$CON_NAME" \
  802-11-wireless.mode ap \
  802-11-wireless.band "$AP_BAND" \
  802-11-wireless.channel "$AP_CHANNEL" \
  ipv4.method manual \
  ipv4.addresses "$AP_IP/$AP_PREFIX" \
  ipv6.method disabled \
  connection.autoconnect yes

if [[ -n "$AP_PASSWORD" ]]; then
  nmcli con modify "$CON_NAME" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$AP_PASSWORD"
fi
# (No password -> no 802-11-wireless-security settings -> open network.)

echo "== Uplink: $ETH_IF to the home LAN (DHCP) =="
ip link set "$ETH_IF" up
# Give the uplink a DHCP connection if it doesn't already have an IPv4 address
# (idempotent: leaves an existing/active connection alone).
if ! ip -4 addr show dev "$ETH_IF" | grep -q 'inet '; then
  nmcli con del "$UPLINK_CON" 2>/dev/null || true
  nmcli con add type ethernet ifname "$ETH_IF" con-name "$UPLINK_CON" \
    ipv4.method auto ipv6.method auto connection.autoconnect yes >/dev/null
  nmcli con up "$UPLINK_CON" || true
fi

echo "== Enabling IP forwarding (the Pi routes Switch -> home LAN) =="
sysctl -w net.ipv4.ip_forward=1 >/dev/null
printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=0\n' > "$SYSCTL_FILE"
sysctl -p "$SYSCTL_FILE" >/dev/null

if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
  echo "ERROR: could not set net.ipv4.ip_forward=1 — aborting." >&2
  exit 1
fi

echo "== Writing /etc/dnsmasq.conf (DHCP + catch-all DNS) =="
if [[ -f /etc/dnsmasq.conf && ! -f /etc/dnsmasq.conf.civswitch-moonlight.bak ]]; then
  cp /etc/dnsmasq.conf /etc/dnsmasq.conf.civswitch-moonlight.bak
fi
cat > /etc/dnsmasq.conf <<EOF
# CivSwitch Moonlight bridge — DHCP + catch-all DNS for the Switch's AP.
interface=wlan0
bind-dynamic

# Never forward upstream; answer everything ourselves.
no-resolv
no-hosts

dhcp-range=${DHCP_START},${DHCP_END},${NETMASK},24h

# Resolve every name to the Pi (mirrors the ESP32's catch-all DNS).
address=/#/${AP_IP}
EOF

echo "== Writing the nftables air-gap firewall =="
cat > "$NFT_FILE" <<EOF
#!/usr/sbin/nft -f

# CivSwitch Moonlight bridge — enforces the air-gap.
#
# The Pi routes between the Switch's AP and the home LAN (${ETH_IF}), but only
# so the Switch can reach the Sunshine host. The FORWARD policy is DROP, so
# the Switch can never reach the internet.

table ip moonlight_bridge {
    chain forward {
        type filter hook forward priority filter; policy drop;

        # Let the Sunshine host's replies flow back to the Switch.
        ct state established,related accept

        # The Switch may reach ONLY the allowed home-LAN subnet / Sunshine host.
        ip saddr ${AP_SUBNET} ip daddr ${LAN_SUBNET} accept
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # Masquerade the Switch's traffic as it leaves ${ETH_IF}, so the
        # Sunshine host replies to the Pi (no router/PC config needed).
        ip saddr ${AP_SUBNET} oifname "${ETH_IF}" masquerade
    }
}
EOF

cat > "/etc/systemd/system/$FW_SERVICE_NAME" <<EOF
[Unit]
Description=CivSwitch Moonlight bridge firewall (enforces the air-gap)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-$NFT delete table ip moonlight_bridge
ExecStart=$NFT -f $NFT_FILE
ExecReload=$NFT -f $NFT_FILE
ExecStop=-$NFT delete table ip moonlight_bridge

[Install]
WantedBy=multi-user.target
EOF

echo "== Installing the HTTP spoof server =="
mkdir -p "$INSTALL_DIR"
install -m 0755 "$SCRIPT_DIR/bridge.py" "$INSTALL_DIR/bridge.py"
install -m 0644 "$SCRIPT_DIR/$SERVICE_NAME" "/etc/systemd/system/$SERVICE_NAME"

echo "== Loading the firewall and asserting the air-gap =="
systemctl daemon-reload
systemctl enable "$FW_SERVICE_NAME"
systemctl restart "$FW_SERVICE_NAME"

FORWARD_CHAIN="$(nft list chain ip moonlight_bridge forward 2>/dev/null || true)"
POSTROUTING_CHAIN="$(nft list chain ip moonlight_bridge postrouting 2>/dev/null || true)"
fail=0
if ! grep -q 'policy drop' <<<"$FORWARD_CHAIN"; then
  echo "ERROR: FORWARD policy is not 'drop' — the air-gap is NOT guaranteed." >&2
  fail=1
fi
if ! grep -qF "$LAN_SUBNET" <<<"$FORWARD_CHAIN"; then
  echo "ERROR: allow rule for $LAN_SUBNET is missing — the Switch could not reach the Sunshine host." >&2
  fail=1
fi
if ! grep -q 'masquerade' <<<"$POSTROUTING_CHAIN"; then
  echo "ERROR: masquerade rule is missing — the Sunshine host could not reply." >&2
  fail=1
fi
if [[ "$fail" -ne 0 ]]; then
  echo "Refusing to finish — firewall rules did not load correctly." >&2
  exit 1
fi

echo "== Enabling services =="
systemctl enable dnsmasq
systemctl restart dnsmasq
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "== Bringing up the AP =="
nmcli con up "$CON_NAME"

echo
echo "Done."
echo "  SSID:        $AP_SSID"
echo "  Pi AP IP:    $AP_IP/$AP_PREFIX"
echo "  Switch:      usually $DHCP_START (check Settings > Internet)"
echo "  Uplink:      $ETH_IF (home LAN, DHCP)"
echo "  Allowed:     Switch -> $LAN_SUBNET only"
echo "  Air-gap:     FORWARD policy = drop (Switch can't reach the internet)"
echo
echo "Now add the Sunshine host by IP in Moonlight — see README for the exact steps."
