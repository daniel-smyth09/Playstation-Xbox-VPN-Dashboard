#!/bin/bash
# ============================================================
#  PS5 VPN Gateway - Complete Installer
#  For Raspberry Pi 4/5 with stock Raspberry Pi OS (Bookworm)
#  Ethernet-only: USB adapter = LAN (PS5), onboard = WAN (router)
#
#  Author: Daniel Smyth
#  GitHub: https://github.com/daniel-smyth09/PS5-VPN-Dashboard
# ============================================================
set -e

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================
if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo: sudo bash install-vpn.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

clear
echo "============================================================"
echo "  PS5 VPN Gateway Installer"
echo "  Author: Daniel Smyth"
echo "  https://github.com/daniel-smyth09/PS5-VPN-Dashboard"
echo "============================================================"
echo ""
echo "REQUIRED HARDWARE:"
echo "  1. Raspberry Pi 4 or 5 (with official power supply)"
echo "  2. USB 3.0 Gigabit Ethernet adapter (ASIX AX88179 chipset)"
echo "  3. Two Ethernet cables"
echo "  4. PIA VPN account (privateinternetaccess.com)"
echo ""
echo "WIRING DIAGRAM (IMPORTANT - read carefully):"
echo ""
echo "  +----------+        +----------+        +----------+"
echo "  |  ROUTER  |========|   PI 5   |========|   PS5    |"
echo "  +----------+  eth   +----------+  eth   +----------+"
echo "      (your)   cable      |  |     cable      (console)"
echo "                          |  |"
echo "              +-----------+  +-----------+"
echo "              | onboard       | USB 3.0"
echo "              | Ethernet      | Gigabit"
echo "              | (WAN)         | adapter"
echo "              |               | (LAN)"
echo "              v               v"
echo "         (Pi's built-in    (USB adapter"
echo "          network port)     plugged into"
echo "                            a BLUE USB)"
echo ""
echo "CONNECTIONS (do this BEFORE running the installer):"
echo "  1. Plug an Ethernet cable into the Pi's BUILT-IN network"
echo "     port (next to the USB ports) and connect the other end"
echo "     to your ROUTER."
echo "  2. Plug the USB-Ethernet adapter into one of the Pi's BLUE"
echo "     USB 3.0 ports (NOT the black USB 2.0 ports, NOT USB-C)."
echo "  3. Plug an Ethernet cable into the USB adapter and connect"
echo "     the other end to your PS5."
echo "  4. Power on the Pi and SSH in."
echo ""
echo "This setup means:"
echo "  - All other devices in your house (phones, laptops) are"
echo "    completely unaffected - they use your router as normal."
echo "  - ONLY the PS5 goes through the VPN tunnel."
echo ""
read -p "Ready to continue? (y/n) [y]: " READY
READY=${READY:-y}
[ "$READY" != "y" ] && [ "$READY" != "Y" ] && exit 0

# ============================================================
# STEP 1: DETECT OPERATING SYSTEM
# ============================================================
echo ""
echo "============================================================"
echo "  [1/10] Detecting Operating System"
echo "============================================================"

# Detect distro
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID=$ID
  OS_LIKE=$ID_LIKE
  OS_VERSION=$VERSION_ID
  OS_NAME="$NAME $VERSION"
else
  OS_ID="unknown"
  OS_NAME="unknown"
fi

# Detect package manager
PKG_MGR=""
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt-get"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
elif command -v pacman &>/dev/null; then
  PKG_MGR="pacman"
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) PIA_ARCH="arm64" ;;
  x86_64|amd64)  PIA_ARCH="x64" ;;
  *)             PIA_ARCH="$ARCH" ;;
esac

echo "  OS:         $OS_NAME"
echo "  ID:         $OS_ID"
echo "  Architecture: $ARCH ($PIA_ARCH)"
echo "  Package mgr: $PKG_MGR"

if [ "$PKG_MGR" != "apt-get" ]; then
  echo ""
  echo "  WARNING: This script is designed for Debian/Ubuntu/Raspberry Pi OS"
  echo "  (which use apt-get). Your system uses $PKG_MGR."
  echo "  The script will try to continue but may need manual fixes."
  echo ""
  read -p "  Continue anyway? (y/n) [y]: " CONT
  CONT=${CONT:-y}
  [ "$CONT" != "y" ] && [ "$CONT" != "Y" ] && exit 0
fi

if [ ! -f /proc/device-tree/model ] && [ ! -f /sys/firmware/devicetree/base/model ]; then
  echo "  NOTE: This doesn't appear to be a Raspberry Pi."
  echo "  It may still work, but hardware detection is optimised for Pi 4/5."
fi

# ============================================================
# STEP 2: UPDATE THE SYSTEM
# ============================================================
echo ""
echo "============================================================"
echo "  [2/10] Updating System Packages"
echo "============================================================"
echo "  Running $PKG_MGR update (this may take a minute)..."
case "$PKG_MGR" in
  apt-get)
    apt-get update -qq
    apt-get full-upgrade -y
    ;;
  dnf|yum)
    $PKG_MGR update -y
    ;;
  pacman)
    pacman -Syu --noconfirm
    ;;
esac
echo "  System updated."

# ============================================================
# STEP 3: DETECT NETWORK INTERFACES
# ============================================================
echo ""
echo "============================================================"
echo "  [3/10] Detecting Network Interfaces"
echo "============================================================"
sleep 2

# Find all non-loopback, non-wireguard ethernet interfaces
INTERFACES=$(ls /sys/class/net/ | grep -vE 'lo$|wg|tun|docker|br-|veth|p2p|wlan' | sort)

if [ -z "$INTERFACES" ]; then
  echo "ERROR: No Ethernet interfaces detected."
  echo "Make sure the USB adapter is plugged into a BLUE USB 3.0 port."
  exit 1
fi

echo "Found interfaces:"
echo "$INTERFACES" | sed 's/^/  - /'
echo ""

# Auto-detect: onboard is eth0, USB adapter is usually eth1, enx*, or usb*
WAN_IF=""
LAN_IF=""

for iface in $INTERFACES; do
  driver=$(basename $(readlink /sys/class/net/$iface/device/driver 2>/dev/null) 2>/dev/null || echo "unknown")
  usb_check=$(readlink -f /sys/class/net/$iface/device 2>/dev/null | grep -i usb || echo "")

  if [ -n "$usb_check" ]; then
    if [ -z "$LAN_IF" ]; then
      LAN_IF="$iface"
      echo "  Detected USB adapter: $iface (driver: $driver) -> LAN (PS5)"
    fi
  else
    if [ -z "$WAN_IF" ]; then
      WAN_IF="$iface"
      echo "  Detected onboard: $iface (driver: $driver) -> WAN (Router)"
    fi
  fi
done

# Fallback: eth0 = WAN, eth1 = LAN
if [ -z "$WAN_IF" ] && ip link show eth0 &>/dev/null; then WAN_IF="eth0"; fi
if [ -z "$LAN_IF" ] && ip link show eth1 &>/dev/null; then LAN_IF="eth1"; fi

if [ -z "$WAN_IF" ] || [ -z "$LAN_IF" ]; then
  echo ""
  echo "Could not auto-detect both interfaces. Please specify:"
  echo "Available: $INTERFACES"
  [ -z "$WAN_IF" ] && read -p "  WAN interface (to router): " WAN_IF
  [ -z "$LAN_IF" ] && read -p "  LAN interface (to PS5): " LAN_IF
fi

echo ""
echo "Final assignment:"
echo "  WAN (router): $WAN_IF"
echo "  LAN (PS5):    $LAN_IF"
echo ""
read -p "Correct? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}
[ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && exit 0

echo "LAN_IF=$LAN_IF" > /etc/vpn-dashboard.conf
echo "WAN_IF=$WAN_IF" >> /etc/vpn-dashboard.conf
chmod 644 /etc/vpn-dashboard.conf

# ============================================================
# STEP 4: DISABLE IPV6 (prevents leaks)
# ============================================================
echo ""
echo "============================================================"
echo "  [4/10] Disabling IPv6 (prevents VPN leaks)"
echo "============================================================"
if ! grep -q "ipv6.disable=1" /boot/firmware/cmdline.txt 2>/dev/null; then
  echo "ipv6.disable=1" >> /boot/firmware/cmdline.txt
  echo "  Added ipv6.disable=1 to cmdline.txt (will take effect on reboot)"
else
  echo "  Already disabled"
fi

# ============================================================
# STEP 5: CHECK + INSTALL PIA VPN
# ============================================================
echo ""
echo "============================================================"
echo "  [5/10] Installing Private Internet Access (PIA)"
echo "============================================================"

if command -v piactl &>/dev/null; then
  echo "  PIA is already installed:"
  echo "    piactl version: $(piactl --version 2>/dev/null || echo 'unknown')"
  echo "  >>> Using existing install."
else
  echo "  PIA is NOT installed yet."
  echo ""
  echo "  You need to provide the PIA installer (.run file)."
  echo "  Two options:"
  echo ""
  echo "    [1] Use the PIA installer bundled with this package"
  echo "        (files/pia-linux-arm64-*.run)"
  echo ""
  echo "    [2] Provide your own PIA installer"
  echo "        Download the latest from:"
  echo "          https://www.privateinternetaccess.com/download/linux-vpn"
  echo "        Place the .run file in the files/ directory and"
  echo "        name it exactly:  piavpn.run"
  echo ""
  read -p "  Choose option [1 or 2, default 1]: " PIA_OPTION
  PIA_OPTION=${PIA_OPTION:-1}

  PIA_RUN_FILE=""

  if [ "$PIA_OPTION" = "1" ]; then
    # Use the bundled .run file
    BUNDLED=$(ls "$FILES_DIR"/pia-linux-*.run 2>/dev/null | head -1)
    if [ -z "$BUNDLED" ] || [ ! -s "$BUNDLED" ]; then
      echo ""
      echo "  ERROR: No bundled PIA installer found in files/ folder."
      echo "  Expected: files/pia-linux-arm64-*.run"
      echo ""
      echo "  Option 2: download your own .run file and place it in"
      echo "  the files/ directory named piavpn.run, then re-run."
      exit 1
    fi
    PIA_RUN_FILE="$BUNDLED"
    echo ""
    echo "  Using bundled installer: $(basename "$BUNDLED")"
  elif [ "$PIA_OPTION" = "2" ]; then
    # User provides their own
    USER_FILE="$FILES_DIR/piavpn.run"
    if [ -f "$USER_FILE" ] && [ -s "$USER_FILE" ]; then
      echo ""
      echo "  Found your installer: files/piavpn.run"
      PIA_RUN_FILE="$USER_FILE"
    else
      echo ""
      echo "  Please download the Linux ARM installer from:"
      echo "    https://www.privateinternetaccess.com/download/linux-vpn"
      echo ""
      echo "  Then place the .run file in this directory:"
      echo "    $FILES_DIR/"
      echo ""
      echo "  Rename it to EXACTLY:  piavpn.run"
      echo "  (Full path: $USER_FILE)"
      echo ""
      read -p "  Done? Press Enter when the file is in place (or 'q' to quit): " DONE_RESP
      [ "$DONE_RESP" = "q" ] && exit 0
      if [ ! -f "$USER_FILE" ] || [ ! -s "$USER_FILE" ]; then
        echo ""
        echo "  ERROR: files/piavpn.run not found."
        echo "  Please verify the file exists and re-run this script."
        exit 1
      fi
      PIA_RUN_FILE="$USER_FILE"
      echo "  Found: files/piavpn.run"
    fi
  else
    echo "  Invalid option. Exiting."
    exit 1
  fi

  echo ""
  echo "  Installing PIA from: $(basename "$PIA_RUN_FILE")"
  chmod +x "$PIA_RUN_FILE"
  if ! "$PIA_RUN_FILE" 2>&1 | sed 's/^/    /'; then
    echo ""
    echo "  ERROR: PIA installer failed."
    exit 1
  fi
  echo ""
  echo "  >>> PIA installed successfully."
  echo ""
fi

# Create PIA daemon systemd service if missing (installer doesn't always create one)
if [ ! -f /etc/systemd/system/pia-daemon.service ] && [ ! -f /etc/systemd/system/private-internet-access.service ]; then
  echo "  Creating pia-daemon systemd service..."
  cat > /etc/systemd/system/pia-daemon.service << EOF
[Unit]
Description=Private Internet Access Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/piavpn/bin/pia-daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi
systemctl enable pia-daemon 2>/dev/null || systemctl enable private-internet-access 2>/dev/null || true
systemctl start pia-daemon 2>/dev/null || systemctl start private-internet-access 2>/dev/null || true
sleep 3

if ! command -v piactl &>/dev/null; then
  echo "  ERROR: piactl not found. PIA install may have failed."
  exit 1
fi

PIA_DAEMON_SVC=$(systemctl is-active pia-daemon 2>/dev/null || systemctl is-active private-internet-access 2>/dev/null || echo "unknown")
echo "  PIA daemon: $PIA_DAEMON_SVC"
echo "  piactl: $(piactl --version 2>/dev/null || echo 'unknown')"

# Set defaults
piactl set protocol wireguard
DEFAULT_REGION="netherlands"
piactl set region "$DEFAULT_REGION"
echo "  Default region: $DEFAULT_REGION"
echo "  Protocol: WireGuard"

# ============================================================
# STEP 6: PIA LOGIN
# ============================================================
echo ""
echo "============================================================"
echo "  [6/10] Logging into PIA"
echo "============================================================"
echo ""
echo "You need to log into your PIA account so the VPN can connect."
echo ""
echo "Your PIA username is your email address (e.g. you@example.com)"
echo "or an x-prefixed username (e.g. x1234567) if you have one."
echo "Your password is the one you set when you signed up for PIA."
echo ""
echo "Tip: If you don't have an account yet, sign up at:"
echo "     https://www.privateinternetaccess.com"
echo ""
read -p "Enter your PIA username: " PIA_USER
read -s -p "Enter your PIA password (hidden): " PIA_PASS
echo ""
echo ""

echo "  Attempting login as $PIA_USER ..."
LOGIN_RESULT=$(piactl login "$PIA_USER" "$PIA_PASS" 2>&1 || true)
sleep 2

if echo "$LOGIN_RESULT" | grep -qi "error\|fail\|invalid\|incorrect"; then
  echo "  WARNING: Login may have failed:"
  echo "  $LOGIN_RESULT"
  echo ""
  echo "  You can log in manually later by running:"
  echo "    piactl login"
  echo ""
  read -p "Continue with install anyway? (y/n) [y]: " CONT
  CONT=${CONT:-y}
  [ "$CONT" != "y" ] && [ "$CONT" != "Y" ] && exit 0
else
  echo "  Login credentials accepted."
fi

# ============================================================
# STEP 7: CONFIGURE LAN INTERFACE
# ============================================================
echo ""
echo "============================================================"
echo "  [7/10] Configuring LAN interface ($LAN_IF)"
echo "============================================================"

# Take LAN interface out of NetworkManager control (if present)
NM_CONF="/etc/NetworkManager/conf.d/99-unmanaged-lan.conf"
if command -v nmcli &>/dev/null; then
  echo "  Removing $LAN_IF from NetworkManager control..."
  cat > "$NM_CONF" << EOF
[keyfile]
unmanaged-devices=interface-name:$LAN_IF
EOF
  systemctl restart NetworkManager 2>/dev/null || true
  sleep 2
fi

echo "  Creating lan-up service for $LAN_IF..."
cat > /etc/systemd/system/lan-up.service << EOF
[Unit]
Description=Assign static IP to $LAN_IF for PS5 LAN
After=network-pre.target
Before=dnsmasq.service

[Service]
Type=oneshot
ExecStartPre=/usr/sbin/rfkill unblock wifi 2>/dev/null || true
ExecStartPre=/sbin/ip addr flush dev $LAN_IF
ExecStart=/sbin/ip addr add 10.99.99.1/24 dev $LAN_IF
ExecStart=/sbin/ip link set dev $LAN_IF up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lan-up.service
echo "  LAN interface configured: 10.99.99.1/24"

# ============================================================
# STEP 8: DHCP + DNS + SUPPORTING PACKAGES
# ============================================================
echo ""
echo "============================================================"
echo "  [8/10] Installing DHCP, DNS, and supporting packages"
echo "============================================================"
echo "  Packages: dnsmasq, tcpdump, speedtest-cli, python3-flask, python3-qrcode"
case "$PKG_MGR" in
  apt-get)
    apt-get install -y dnsmasq iptables-persistent tcpdump speedtest-cli python3-flask python3-qrcode 2>&1 | tail -3
    ;;
  *)
    echo "  WARNING: Package installation for $PKG_MGR not fully implemented."
    echo "  Please install manually: dnsmasq tcpdump python3-flask python3-qrcode"
    $PKG_MGR install -y dnsmasq tcpdump python3-flask python3-qrcode 2>/dev/null || true
    ;;
esac

systemctl disable --now dnsmasq 2>/dev/null || true

cat > /etc/dnsmasq.conf << EOF
# PS5 VPN Gateway - dnsmasq config
interface=$LAN_IF
listen-address=10.99.99.1
bind-interfaces
dhcp-range=10.99.99.10,10.99.99.50,255.255.255.0,12h
dhcp-option=3,10.99.99.1
dhcp-option=6,10.99.99.1
dhcp-authoritative
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
dhcp-lease-max=50
log-dhcp
no-resolv
server=1.1.1.1
server=1.0.0.1
EOF
echo "  dnsmasq configured for $LAN_IF (10.99.99.0/24, DNS via Cloudflare)"

# ============================================================
# STEP 9: FIREWALL + NAT + KILL SWITCH + AUTO-CONNECT + DASHBOARD
# ============================================================
echo ""
echo "============================================================"
echo "  [9/10] Configuring firewall, kill switch, auto-connect, dashboard"
echo "============================================================"

# --- Firewall script ---
cat > /usr/local/bin/vpn-fw.sh << SCRIPT_EOF
#!/bin/bash
# PS5 VPN Gateway - Firewall rules
LAN_NET=10.99.99.0/24
WAN=$WAN_IF
LAN=$LAN_IF
VPN=wgpia0

for i in \$(seq 1 30); do
  if [ -d "/sys/class/net/wgpia0" ]; then VPN=wgpia0; break; fi
  sleep 1
done

iptables -t nat -D POSTROUTING -s \$LAN_NET -o \$VPN -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i \$LAN -o \$VPN -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i \$LAN -o \$WAN -j DROP 2>/dev/null || true

iptables -t nat -A POSTROUTING -s \$LAN_NET -o \$VPN -j MASQUERADE

iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \\
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C FORWARD -i \$LAN -o \$VPN -j ACCEPT 2>/dev/null || \\
  iptables -A FORWARD -i \$LAN -o \$VPN -j ACCEPT
iptables -C FORWARD -i \$LAN -o \$WAN -j DROP 2>/dev/null || \\
  iptables -A FORWARD -i \$LAN -o \$WAN -j DROP
iptables -C INPUT -i \$LAN -j ACCEPT 2>/dev/null || \\
  iptables -I INPUT 1 -i \$LAN -j ACCEPT
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \\
  iptables -I INPUT 1 -i lo -j ACCEPT
SCRIPT_EOF
chmod +x /usr/local/bin/vpn-fw.sh

cat > /etc/systemd/system/vpn-fw.service << EOF
[Unit]
Description=VPN Firewall and NAT
After=network-pre.target lan-up.service pia-daemon.service
Before=dnsmasq.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/vpn-fw.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- PIA auto-connect helper ---
cat > /usr/local/bin/pia-wait-and-connect.sh << EOF
#!/bin/bash
for i in \$(seq 1 30); do
  piactl get connectionstate 2>/dev/null && break
  sleep 2
done
piactl connect
for i in \$(seq 1 20); do
  [ "\$(piactl get connectionstate)" = "Connected" ] && exit 0
  sleep 2
done
exit 1
EOF
chmod +x /usr/local/bin/pia-wait-and-connect.sh

cat > /etc/systemd/system/pia-connect.service << EOF
[Unit]
Description=Connect PIA VPN
After=pia-daemon.service network-online.target
Wants=network-online.target pia-daemon.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 8
ExecStart=/usr/local/bin/pia-wait-and-connect.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- Dashboard ---
mkdir -p /opt/vpn-dashboard /var/lib/vpn-dashboard
if [ -f "$FILES_DIR/app.py" ]; then
  cp "$FILES_DIR/app.py" /opt/vpn-dashboard/app.py
  chmod 644 /opt/vpn-dashboard/app.py
  echo "  Dashboard app installed"
else
  echo "  WARNING: app.py not found in files/ - dashboard unavailable"
fi

cat > /etc/systemd/system/vpn-dashboard.service << EOF
[Unit]
Description=PS5 VPN Dashboard
After=pia-daemon.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/vpn-dashboard/app.py
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpn-fw.service pia-connect.service vpn-dashboard.service

iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT
netfilter-persistent save 2>/dev/null || true

# --- Generate PIN ---
if [ ! -f /var/lib/vpn-dashboard/pin.hash ]; then
  GENERATED_PIN=$(shuf -i 1000-9999 -n 1)
  echo ""
  echo "  +----------------------------------------+"
  echo "  |  SECURITY PIN GENERATED                |"
  echo "  |  Your dashboard PIN is: $GENERATED_PIN      |"
  echo "  |  Required for Reboot/Shutdown/         |"
  echo "  |  Kill Switch Test                      |"
  echo "  +----------------------------------------+"
  echo -n "$GENERATED_PIN" | sha256sum | awk '{print $1}' > /var/lib/vpn-dashboard/pin.hash
else
  echo "  PIN already set (keeping existing)"
fi
chmod 600 /var/lib/vpn-dashboard/pin.hash

echo "  Kill switch active"
echo "  NAT enabled"
echo "  Auto-connect enabled ($DEFAULT_REGION)"
echo "  Dashboard ready on port 8080"

# ============================================================
# STEP 10: START EVERYTHING
# ============================================================
echo ""
echo "============================================================"
echo "  [10/10] Starting Services"
echo "============================================================"

systemctl enable dnsmasq
systemctl start lan-up.service
sleep 2
systemctl start dnsmasq
sleep 1
systemctl restart vpn-fw.service
sleep 1
systemctl start pia-connect.service
sleep 5
systemctl start vpn-dashboard
sleep 2

echo "  lan-up:         $(systemctl is-active lan-up)"
echo "  dnsmasq:        $(systemctl is-active dnsmasq)"
echo "  pia-daemon:     $(systemctl is-active pia-daemon 2>/dev/null || systemctl is-active private-internet-access 2>/dev/null)"
echo "  pia-connect:    $(systemctl is-active pia-connect)"
echo "  vpn-fw:         $(systemctl is-active vpn-fw)"
echo "  vpn-dashboard:  $(systemctl is-active vpn-dashboard)"

# ============================================================
# DONE
# ============================================================
echo ""
echo "============================================================"
echo "  Installation Complete!"
echo "============================================================"
echo ""
echo "AUTHOR: Daniel Smyth"
echo "GITHUB: https://github.com/daniel-smyth09/PS5-VPN-Dashboard"
echo ""
echo "------------------------------------------------------------"
echo "  HARDWARE WIRING (final check)"
echo "------------------------------------------------------------"
echo ""
echo "  Make sure everything is plugged in like this:"
echo ""
echo "     ROUTER  ====ethernet====  [onboard port]  PI 5  [USB 3.0 port]====USB-Eth adapter====ethernet====  PS5"
echo "                                                                 (blue)"
echo ""
echo "  - Router to Pi: use the Pi's BUILT-IN Ethernet port"
echo "    (the one next to the USB ports, NOT a USB adapter)"
echo "  - Pi to PS5: USB-Ethernet adapter plugged into a BLUE"
echo "    USB 3.0 port, then Ethernet cable to the PS5"
echo ""
echo "------------------------------------------------------------"
echo "  DASHBOARD"
echo "------------------------------------------------------------"
echo ""
echo "  Open this URL on your phone (must be on the same Wi-Fi"
echo "  network as the Pi):"
echo ""
hostname -I | tr ' ' '\n' | grep -v '^$' | while read -r ip; do
  [ -n "$ip" ] && echo "    http://$ip:8080"
done
echo ""
echo "  Install as an app on iPhone:"
echo "    1. Open the URL in Safari"
echo "    2. Tap the Share button (square with up arrow)"
echo "    3. Tap 'Add to Home Screen'"
echo ""
echo "------------------------------------------------------------"
echo "  VERIFY THE VPN IS WORKING"
echo "------------------------------------------------------------"
echo ""
echo "  1. On your PS5: Settings -> Network -> Test Internet Connection"
echo "     It should succeed and show a download speed."
echo ""
echo "  2. On your PS5 web browser, open:  https://ipleak.net"
echo "     - Your IP should show Netherlands (or your chosen region)"
echo "     - There should be NO mention of your real ISP (e.g. Virgin)"
echo "     - DNS servers should be Cloudflare (1.1.1.1)"
echo ""
echo "  3. In the dashboard, tap 'Test Kill Switch'"
echo "     - Should show a green tick: Kill switch working"
echo "     - This confirms the PS5 is protected if VPN drops"
echo ""
echo "------------------------------------------------------------"
echo "  TROUBLESHOOTING"
echo "------------------------------------------------------------"
echo ""
echo "  PS5 can't get internet:"
echo "    piactl get connectionstate    (must say 'Connected')"
echo "    sudo journalctl -u pia-connect -f   (watch VPN connect)"
echo ""
echo "  PS5 can't get an IP address:"
echo "    sudo systemctl restart lan-up dnsmasq"
echo "    sudo journalctl -u dnsmasq -f"
echo ""
echo "  Dashboard not loading:"
echo "    sudo systemctl status vpn-dashboard"
echo "    sudo journalctl -u vpn-dashboard -f"
echo ""
echo "  PIA login failed - log in manually:"
echo "    piactl login"
echo ""
echo "  Forgot your PIN or want to change it:"
echo "    echo -n \"1234\" | sha256sum | awk '{print \$1}' | sudo tee /var/lib/vpn-dashboard/pin.hash"
echo "    (replace 1234 with your new 4-digit PIN)"
echo ""
echo "------------------------------------------------------------"
echo "  REBOOT"
echo "------------------------------------------------------------"
echo ""
echo "  A reboot is recommended to apply the IPv6 disable and make"
echo "  sure everything starts cleanly on boot:"
echo ""
echo "    sudo reboot"
echo ""
echo "  After reboot, wait ~90 seconds for the VPN to connect"
echo "  automatically, then test on the PS5."
echo ""
echo "============================================================"
echo "  Thanks for using the PS5 VPN Gateway!"
echo "  Author: Daniel Smyth"
echo "  https://github.com/daniel-smyth09/PS5-VPN-Dashboard"
echo "============================================================"
echo ""
