#!/bin/bash
# ============================================================
#  PS5/Xbox VPN PIA Dashboard - Complete Installer
#  For Raspberry Pi 4/5 with stock Raspberry Pi OS (Bookworm)
#  Ethernet-only: USB adapter = LAN (console), onboard = WAN (router)
#
#  Works with: PS4, PS5, Xbox Series S, Xbox Series X
#
#  Author: Daniel Smyth
#  GitHub: https://github.com/daniel-smyth09/Playstation-Xbox-VPN-Dashboard
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
echo "  PS5/Xbox VPN PIA Dashboard Installer"
echo "  Author: Daniel Smyth"
echo "  https://github.com/daniel-smyth09/Playstation-Xbox-VPN-Dashboard"
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
echo "  |  ROUTER  |========|   PI 5   |========| CONSOLE  |"
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
echo "     the other end to your console ($CONSOLE_NAME)."
echo "  4. Power on the Pi and SSH in."
echo ""
echo "This setup means:"
echo "  - All other devices in your house (phones, laptops) are"
echo "    completely unaffected - they use your router as normal."
echo "  - ONLY the $CONSOLE_NAME goes through the VPN tunnel."
echo ""
read -p "Ready to continue? (y/n) [y]: " READY
READY=${READY:-y}
[ "$READY" != "y" ] && [ "$READY" != "Y" ] && exit 0

# ============================================================
# CHECK IF ALREADY INSTALLED
# ============================================================
if [ -f /etc/vpn-dashboard.conf ] && systemctl is-active --quiet vpn-dashboard 2>/dev/null; then
  echo ""
  echo "============================================================"
  echo "  VPN Dashboard Already Installed"
  echo "============================================================"
  echo ""
  echo "  The dashboard is already running on this Pi."
  echo ""
  echo "    [1] Change PIN"
  echo "    [2] Re-run full installer (will overwrite config)"
  echo "    [3] Exit"
  echo ""
  read -p "  Choose [1-3]: " REINSTALL_CHOICE
  case "$REINSTALL_CHOICE" in
    1)
      echo ""
      while true; do
        read -p "  Enter new PIN (4-10 digits): " NEW_PIN
        if [[ "$NEW_PIN" =~ ^[0-9]{4,10}$ ]]; then
          echo -n "$NEW_PIN" | sha256sum | awk '{print $1}' > /var/lib/vpn-dashboard/pin.hash
          chmod 600 /var/lib/vpn-dashboard/pin.hash
          echo "  PIN changed successfully!"
          echo ""
          exit 0
        else
          echo "  Invalid PIN. Use 4-10 digits only."
        fi
      done
      ;;
    2)
      echo ""
      echo "  Proceeding with full reinstall..."
      ;;
    *)
      exit 0
      ;;
  esac
fi

# ============================================================
# STEP 0.5: CONSOLE SELECTION
# ============================================================
echo ""
echo "============================================================"
echo "  Console Selection"
echo "============================================================"
echo ""
echo "  Which console will be connected to this VPN gateway?"
echo ""
echo "    [1] PlayStation (PS4, PS5)"
echo "    [2] Xbox (Series S, Series X)"
echo ""
read -p "  Choose [1 or 2]: " CONSOLE_CHOICE

if [ "$CONSOLE_CHOICE" = "1" ]; then
  CONSOLE_FAMILY="playstation"
  echo ""
  echo "  Which PlayStation model?"
  echo "    [1] PS5 (default)"
  echo "    [2] PS4"
  read -p "  Choose [1 or 2, default 1]: " PS_MODEL
  PS_MODEL=${PS_MODEL:-1}
  case "$PS_MODEL" in
    2) CONSOLE_NAME="PS4" ;;
    *) CONSOLE_NAME="PS5" ;;
  esac
elif [ "$CONSOLE_CHOICE" = "2" ]; then
  CONSOLE_FAMILY="xbox"
  echo ""
  echo "  Which Xbox model?"
  echo "    [1] Xbox Series X (default)"
  echo "    [2] Xbox Series S"
  read -p "  Choose [1 or 2, default 1]: " XBOX_MODEL
  XBOX_MODEL=${XBOX_MODEL:-1}
  case "$XBOX_MODEL" in
    2) CONSOLE_NAME="Xbox Series S" ;;
    *) CONSOLE_NAME="Xbox Series X" ;;
  esac
else
  echo "  Invalid choice. Defaulting to PS5."
  CONSOLE_FAMILY="playstation"
  CONSOLE_NAME="PS5"
fi

echo ""
echo "  Console: $CONSOLE_NAME"
echo "  The dashboard and all messages will reference this console."
echo ""
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
echo "  [2/10] Refreshing Package Index"
echo "============================================================"
echo "  Refreshing package lists (no system-wide upgrade)..."
case "$PKG_MGR" in
  apt-get)
    apt-get update -qq
    ;;
  dnf|yum)
    $PKG_MGR makecache -y 2>/dev/null || $PKG_MGR check-update 2>/dev/null || true
    ;;
  pacman)
    pacman -Sy --noconfirm
    ;;
esac
echo "  Package index refreshed."

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
      echo "  Detected USB adapter: $iface (driver: $driver) -> LAN ($CONSOLE_NAME)"
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

while true; do
  if [ -z "$WAN_IF" ] || [ -z "$LAN_IF" ]; then
    echo ""
    echo "Could not auto-detect both interfaces. Please specify."
    echo "Available: $INTERFACES"
    [ -z "$WAN_IF" ] && read -p "  WAN interface (to router): " WAN_IF
    [ -z "$LAN_IF" ] && read -p "  LAN interface (to $CONSOLE_NAME): " LAN_IF
  fi

  echo ""
  echo "Final assignment:"
  echo "  WAN (router):          $WAN_IF"
  echo "  LAN ($CONSOLE_NAME):   $LAN_IF"
  echo ""
  read -p "Correct? (y/n) [y]: " CONFIRM
  CONFIRM=${CONFIRM:-y}
  if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
    break
  fi
  # User said no - let them redefine both
  echo ""
  echo "Please specify the correct interfaces."
  echo "Available: $INTERFACES"
  read -p "  WAN interface (to router): " WAN_IF
  read -p "  LAN interface (to $CONSOLE_NAME): " LAN_IF
done

echo "LAN_IF=$LAN_IF" > /etc/vpn-dashboard.conf
echo "WAN_IF=$WAN_IF" >> /etc/vpn-dashboard.conf
echo "CONSOLE_NAME=$CONSOLE_NAME" >> /etc/vpn-dashboard.conf
echo "CONSOLE_FAMILY=$CONSOLE_FAMILY" >> /etc/vpn-dashboard.conf
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
  # PIA installer refuses to run as root - drop to the calling user
  REAL_USER="${SUDO_USER:-$USER}"
  if [ "$REAL_USER" = "root" ] || [ -z "$REAL_USER" ]; then
    echo "  WARNING: Running as root with no SUDO_USER detected."
    echo "  PIA installer needs a normal user. Trying 'pi' user..."
    REAL_USER="pi"
  fi
  echo "  Running installer as user: $REAL_USER"
  # Give the user read+execute access to the file (may be in root's home)
  chmod 755 "$FILES_DIR" 2>/dev/null || true
  chmod 755 "$(dirname "$PIA_RUN_FILE")" 2>/dev/null || true
  if ! sudo -u "$REAL_USER" "$PIA_RUN_FILE" 2>&1 | grep -v -iE 'Aborted|XDG_SESSION_TYPE|nohup.*client|clear-cache' | sed 's/^/    /'; then
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

# Wait for piactl to be able to communicate with the daemon
echo "  Waiting for PIA daemon to be ready..."
PIA_READY=0
for i in $(seq 1 15); do
  if piactl get connectionstate 2>/dev/null; then
    PIA_READY=1
    break
  fi
  sleep 2
done
if [ "$PIA_READY" = "0" ]; then
  echo "  WARNING: piactl could not communicate with daemon after 30s."
  echo "  You may need to restart the daemon: sudo systemctl restart pia-daemon"
fi

# Enable background mode (required for headless/Pi operation)
echo "  Enabling PIA background mode..."
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ] || [ -z "$REAL_USER" ]; then REAL_USER="pi"; fi
sudo -u "$REAL_USER" piactl background enable 2>/dev/null || piactl background enable 2>/dev/null || true
sleep 2

# Set protocol
piactl set protocol wireguard 2>/dev/null || echo "  (protocol set skipped)"
echo "  Protocol: WireGuard"

# ============================================================
# STEP 6: PIA LOGIN
# ============================================================
echo ""
echo "============================================================"
echo "  [6/10] Logging into PIA"
echo "============================================================"
echo ""

# Determine real user and home directory
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ] || [ -z "$REAL_USER" ]; then REAL_USER="pi"; fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
LOGIN_FILE="$REAL_HOME/.pia.login"

# Check if existing login file is present (from a previous install)
USE_EXISTING=0
if [ -f "$LOGIN_FILE" ]; then
  EXISTING_USER=$(head -1 "$LOGIN_FILE" 2>/dev/null || echo "")
  echo "  Found existing PIA login file: $LOGIN_FILE"
  echo "  Username: $EXISTING_USER"
  echo ""
  read -p "  Use these saved credentials? (y/n) [y]: " USE_SAVED
  USE_SAVED=${USE_SAVED:-y}
  if [ "$USE_SAVED" = "y" ] || [ "$USE_SAVED" = "Y" ]; then
    USE_EXISTING=1
  fi
fi

if [ "$USE_EXISTING" = "1" ]; then
  echo "  Logging in with saved credentials..."
  LOGIN_RESULT=$(sudo -u "$REAL_USER" piactl login "$LOGIN_FILE" 2>&1 || true)
  sleep 3
  if echo "$LOGIN_RESULT" | grep -qi "error\|fail\|invalid\|incorrect"; then
    echo "  WARNING: Login may have failed: $LOGIN_RESULT"
  elif echo "$LOGIN_RESULT" | grep -qi "already logged"; then
    echo "  >>> Already logged in."
  else
    echo "  >>> Login successful (using saved credentials)."
  fi
else
  # Ask for fresh credentials
  echo "  You need to log into your PIA account so the VPN can connect."
  echo ""
  echo "  Tip: If you don't have an account yet, sign up at:"
  echo "       https://www.privateinternetaccess.com"
  echo ""
  read -p "  Enter your PIA username: " PIA_USER
  read -s -p "  Enter your PIA password (hidden): " PIA_PASS
  echo ""
  echo ""

  # Write the credentials and fix ownership/permissions
  printf '%s\n%s\n' "$PIA_USER" "$PIA_PASS" > "$LOGIN_FILE"
  chown "$REAL_USER":"$REAL_USER" "$LOGIN_FILE"
  chmod 600 "$LOGIN_FILE"

  echo "  Logging in as $PIA_USER ..."
  echo "  (Credentials saved to $LOGIN_FILE for future use)"
  LOGIN_RESULT=$(sudo -u "$REAL_USER" piactl login "$LOGIN_FILE" 2>&1 || true)
  sleep 3

  if echo "$LOGIN_RESULT" | grep -qi "error\|fail\|invalid\|incorrect"; then
    echo "  WARNING: Login may have failed:"
    echo "    $LOGIN_RESULT"
    echo ""
    echo "  You can log in manually later by running:"
    echo "    piactl login $LOGIN_FILE"
    echo ""
    read -p "  Continue with install anyway? (y/n) [y]: " CONT
    CONT=${CONT:-y}
    [ "$CONT" != "y" ] && [ "$CONT" != "Y" ] && exit 0
  elif [ -z "$LOGIN_RESULT" ]; then
    echo "  >>> Login successful."
  else
    echo "  >>> Login result: $LOGIN_RESULT"
  fi
fi

# Set default region to auto (users change this via dashboard)
piactl set region auto 2>/dev/null || true
DEFAULT_REGION="auto"
echo "  Default region: auto (change via dashboard)"

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
  # Explicitly tell NM to release the interface
  nmcli device set "$LAN_IF" managed no 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true
  sleep 3
  # Disconnect any NM-managed connection on it
  nmcli device disconnect "$LAN_IF" 2>/dev/null || true
  sleep 1
fi

# Manually configure the interface NOW (don't wait for lan-up service)
echo "  Configuring $LAN_IF with static IP..."
ip addr flush dev "$LAN_IF" 2>/dev/null || true
ip link set "$LAN_IF" up 2>/dev/null || true
ip addr add 10.99.99.1/24 dev "$LAN_IF" 2>/dev/null || true

echo "  Creating lan-up service for $LAN_IF..."
cat > /etc/systemd/system/lan-up.service << EOF
[Unit]
Description=Assign static IP to $LAN_IF for $CONSOLE_NAME LAN
After=network-pre.target NetworkManager.service
Before=dnsmasq.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStartPre=/usr/sbin/rfkill unblock wifi 2>/dev/null || true
ExecStartPre=/sbin/ip link set dev $LAN_IF up 2>/dev/null || true
ExecStartPre=/sbin/ip addr flush dev $LAN_IF 2>/dev/null || true
ExecStartPre=/bin/sh -c 'nmcli device set $LAN_IF managed no 2>/dev/null || true'
ExecStart=/sbin/ip addr add 10.99.99.1/24 dev $LAN_IF
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
# VPN Gateway - dnsmasq config
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
server=10.0.0.243
server=10.0.0.242
EOF
echo "  dnsmasq configured for $LAN_IF (10.99.99.0/24, DNS via PIA tunnel)"

# ============================================================
# STEP 9: FIREWALL + NAT + KILL SWITCH + AUTO-CONNECT + DASHBOARD
# ============================================================
echo ""
echo "============================================================"
echo "  [9/10] Configuring firewall, kill switch, auto-connect, dashboard"
echo "============================================================"

# --- Firewall script ---
# cat > /usr/local/bin/vpn-fw.sh << SCRIPT_EOF
# #!/bin/bash
# # VPN Gateway - Firewall rules
# LAN_NET=10.99.99.0/24
# WAN=$WAN_IF
# LAN=$LAN_IF
# VPN=wgpia0

# for i in \$(seq 1 30); do
#   if [ -d "/sys/class/net/wgpia0" ]; then VPN=wgpia0; break; fi
#   sleep 1
# done

# iptables -t nat -D POSTROUTING -s \$LAN_NET -o \$VPN -j MASQUERADE 2>/dev/null || true
# iptables -D FORWARD -i \$LAN -o \$VPN -j ACCEPT 2>/dev/null || true
# iptables -D FORWARD -i \$LAN -o \$WAN -j DROP 2>/dev/null || true

# iptables -t nat -A POSTROUTING -s \$LAN_NET -o \$VPN -j MASQUERADE

# iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \\
#   iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# iptables -C FORWARD -i \$LAN -o \$VPN -j ACCEPT 2>/dev/null || \\
#   iptables -A FORWARD -i \$LAN -o \$VPN -j ACCEPT
# iptables -C FORWARD -i \$LAN -o \$WAN -j DROP 2>/dev/null || \\
#   iptables -A FORWARD -i \$LAN -o \$WAN -j DROP
# iptables -C INPUT -i \$LAN -j ACCEPT 2>/dev/null || \\
#   iptables -I INPUT 1 -i \$LAN -j ACCEPT
# iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \\
#   iptables -I INPUT 1 -i lo -j ACCEPT
# SCRIPT_EOF

cat > /usr/local/bin/vpn-fw.sh << SCRIPT_EOF
#!/bin/bash
# VPN Gateway - Firewall rules
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

iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C FORWARD -i \$LAN -o \$VPN -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i \$LAN -o \$VPN -j ACCEPT
iptables -C FORWARD -i \$LAN -o \$WAN -j DROP 2>/dev/null || \
  iptables -A FORWARD -i \$LAN -o \$WAN -j DROP
iptables -C INPUT -i \$LAN -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i \$LAN -j ACCEPT
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i lo -j ACCEPT

# === SSH and management access on WAN (added after original rules) ===
iptables -C INPUT -i \$WAN -p tcp --dport 8080 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i \$WAN -p tcp --dport 8080 -j ACCEPT
iptables -C INPUT -i \$WAN -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i \$WAN -p tcp --dport 22 -j ACCEPT
iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Poke holes in PIA's chain if it exists
iptables -I piavpn.INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
iptables -I piavpn.INPUT 2 -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
iptables -I piavpn.INPUT 3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
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
# Enable background mode (required for headless operation)
piactl background enable 2>/dev/null || true
sleep 1

# Wait for daemon to respond
for i in \$(seq 1 30); do
  piactl get connectionstate 2>/dev/null && break
  sleep 2
done

# If not logged in, try the saved login file
LOGIN_FILE="\$(eval echo ~${REAL_USER})/.pia.login"
STATE=\$(piactl get connectionstate 2>/dev/null)
if [ "\$STATE" = "Disconnected" ] || [ -z "\$STATE" ]; then
  # Try to re-login if credentials file exists
  if [ -f "\$LOGIN_FILE" ]; then
    piactl login "\$LOGIN_FILE" 2>/dev/null
    sleep 2
  fi
fi

piactl connect
# Wait for Connected state (max 40s)
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
Description=$CONSOLE_NAME VPN Dashboard
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

echo "  Starting lan-up service..."
systemctl start lan-up.service 2>/dev/null &
sleep 3

echo "  Configuring LAN interface ($LAN_IF)..."
if ! ip addr show "$LAN_IF" 2>/dev/null | grep -q "10.99.99.1"; then
  nmcli device set "$LAN_IF" managed no 2>/dev/null || true
  ip addr flush dev "$LAN_IF" 2>/dev/null || true
  ip link set "$LAN_IF" up 2>/dev/null || true
  ip addr add 10.99.99.1/24 dev "$LAN_IF" 2>/dev/null || true
fi

echo "  Starting DHCP/DNS server (dnsmasq)..."
systemctl start dnsmasq
sleep 1

echo "  Starting firewall + kill switch..."
systemctl restart vpn-fw.service 2>/dev/null || true
sleep 1

echo "  Starting PIA auto-connect..."
systemctl start pia-connect.service 2>/dev/null &
sleep 2

echo "  Waiting for VPN to connect (this can take 30-60 seconds)..."
VPN_WAIT_SPINNER="|/-\\"
for i in $(seq 1 30); do
  VPN_STATE=$(piactl get connectionstate 2>/dev/null || echo "Unknown")
  if [ "$VPN_STATE" = "Connected" ]; then
    echo -e "\r  VPN status: Connected!                    "
    break
  fi
  printf "\r  VPN status: %s (waiting... %s) " "$VPN_STATE" "${VPN_WAIT_SPINNER:$((i%4)):1}"
  sleep 2
done
echo ""

echo "  Starting web dashboard..."
systemctl start vpn-dashboard
sleep 2

echo ""
echo "  Service status:"
echo "    lan-up:         $(systemctl is-active lan-up 2>/dev/null)"
echo "    dnsmasq:        $(systemctl is-active dnsmasq 2>/dev/null)"
echo "    pia-daemon:     $(systemctl is-active pia-daemon 2>/dev/null || systemctl is-active private-internet-access 2>/dev/null)"
echo "    pia-connect:    $(systemctl is-active pia-connect 2>/dev/null)"
echo "    vpn-fw:         $(systemctl is-active vpn-fw 2>/dev/null)"
echo "    vpn-dashboard:  $(systemctl is-active vpn-dashboard 2>/dev/null)"

# Final VPN status check
VPN_STATE=$(piactl get connectionstate 2>/dev/null || echo "Unknown")
echo ""
if [ "$VPN_STATE" = "Connected" ]; then
  VPN_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "unknown")
  echo "  >>> VPN connected successfully! (IP: $VPN_IP)"
else
  echo "  >>> NOTE: VPN not yet connected (state: $VPN_STATE)"
  echo "  >>> If it doesn't connect within a minute, run:"
  echo "  >>>   piactl background enable && piactl connect"
  echo "  >>> Or reboot: sudo reboot"
fi

# ============================================================
# DONE
# ============================================================
echo ""
echo "============================================================"
echo "  Installation Complete!"
echo "============================================================"
echo ""
echo "AUTHOR: Daniel Smyth"
echo "GITHUB: https://github.com/daniel-smyth09/Playstation-Xbox-VPN-Dashboard"
echo ""
echo "------------------------------------------------------------"
echo "  HARDWARE WIRING (final check)"
echo "------------------------------------------------------------"
echo ""
echo "  Make sure everything is plugged in like this:"
echo ""
echo "     ROUTER  ====ethernet====  [onboard port]  PI 5  [USB 3.0 port]====USB-Eth adapter====ethernet====  $CONSOLE_NAME"
echo "                                                                 (blue)"
echo ""
echo "  - Router to Pi: use the Pi's BUILT-IN Ethernet port"
echo "    (the one next to the USB ports, NOT a USB adapter)"
echo "  - Pi to console: USB-Ethernet adapter plugged into a BLUE"
echo "    USB 3.0 port, then Ethernet cable to your console"
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
echo "  1. On your $CONSOLE_NAME: Settings -> Network -> Test Internet Connection"
echo "     It should succeed and show a download speed."
echo ""
echo "  2. On your $CONSOLE_NAME web browser, open:  https://ipleak.net"
echo "     - Your IP should show Netherlands (or your chosen region)"
echo "     - There should be NO mention of your real ISP (e.g. Virgin)"
echo "     - DNS servers should be Cloudflare (1.1.1.1)"
echo ""
echo "  3. In the dashboard, tap 'Test Kill Switch'"
echo "     - Should show a green tick: Kill switch working"
echo "     - This confirms the $CONSOLE_NAME is protected if VPN drops"
echo ""
echo "------------------------------------------------------------"
echo "  TROUBLESHOOTING"
echo "------------------------------------------------------------"
echo ""
echo "  $CONSOLE_NAME can't get internet:"
echo "    piactl get connectionstate    (must say 'Connected')"
echo "    sudo journalctl -u pia-connect -f   (watch VPN connect)"
echo ""
echo "  $CONSOLE_NAME can't get an IP address:"
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
echo "  automatically, then test on the $CONSOLE_NAME."
echo ""
echo "============================================================"
echo "  Thanks for using the VPN Gateway!"
echo "  Author: Daniel Smyth"
echo "  https://github.com/daniel-smyth09/Playstation-Xbox-VPN-Dashboard"
echo "============================================================"
echo ""
