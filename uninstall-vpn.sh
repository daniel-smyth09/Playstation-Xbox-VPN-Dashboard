#!/bin/bash
# ============================================================
#  PS5 VPN Gateway - Complete Uninstaller
#  Removes all components installed by install-vpn.sh
#
#  Author: Daniel Smyth
#  GitHub: https://github.com/daniel-smyth09/PS5-VPN-Dashboard
# ============================================================

# --- Must be root ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo: sudo bash uninstall-vpn.sh"
  exit 1
fi

clear
echo "============================================================"
echo "  PS5 VPN Gateway Uninstaller"
echo "  Author: Daniel Smyth"
echo "  https://github.com/daniel-smyth09/PS5-VPN-Dashboard"
echo "============================================================"
echo ""
echo "This will remove ALL of the following:"
echo ""
echo "  Services:"
echo "    - vpn-dashboard   (web dashboard)"
echo "    - pia-connect     (auto-connect)"
echo "    - pia-daemon      (PIA VPN daemon)"
echo "    - vpn-fw          (firewall/NAT/kill switch)"
echo "    - lan-up          (LAN static IP)"
echo "    - dnsmasq         (DHCP/DNS)"
echo ""
echo "  Files & directories:"
echo "    - /opt/vpn-dashboard/          (dashboard app)"
echo "    - /opt/piavpn/                 (PIA VPN install)"
echo "    - /var/lib/vpn-dashboard/      (state, PIN, history, stats)"
echo "    - /etc/vpn-dashboard.conf      (interface config)"
echo "    - /usr/local/bin/vpn-fw.sh     (firewall script)"
echo "    - /usr/local/bin/pia-wait-and-connect.sh"
echo "    - /etc/dnsmasq.conf            (DHCP/DNS config)"
echo "    - All systemd service files"
echo ""
echo "  Packages (optional):"
echo "    - dnsmasq, tcpdump, speedtest-cli"
echo "    - python3-flask, python3-qrcode"
echo "    - PIA VPN (piactl)"
echo ""
echo "  Also:"
echo "    - Remove IPv6 disable from cmdline.txt"
echo "    - Flush iptables rules (restore default firewall)"
echo "    - Re-enable NetworkManager on all interfaces"
echo ""
echo "!! WARNING: This is irreversible. Your PS5 will lose its   !!"
echo "!! VPN connection immediately after running this script.   !!"
echo "!! The PS5 will need to be plugged back into your router   !!"
echo "!! directly to regain internet access.                     !!"
echo ""
read -p "Are you SURE you want to continue? Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0
echo ""

# ============================================================
# STEP 1: STOP SERVICES
# ============================================================
echo "============================================================"
echo "  [1/6] Stopping Services"
echo "============================================================"
for svc in vpn-dashboard pia-connect pia-daemon private-internet-access vpn-fw lan-up dnsmasq; do
  if systemctl list-unit-files | grep -q "$svc.service"; then
    echo "  Stopping $svc..."
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  fi
done
echo "  All services stopped."

# ============================================================
# STEP 2: REMOVE SYSTEMD SERVICE FILES
# ============================================================
echo ""
echo "============================================================"
echo "  [2/6] Removing Service Files"
echo "============================================================"
for svc in vpn-dashboard pia-connect pia-daemon private-internet-access vpn-fw lan-up; do
  for path in "/etc/systemd/system/$svc.service" \
              "/lib/systemd/system/$svc.service" \
              "/usr/lib/systemd/system/$svc.service"; do
    if [ -f "$path" ]; then
      echo "  Removing $path"
      rm -f "$path"
    fi
  done
done

# Remove override directories
rm -rf /etc/systemd/system/dnsmasq.service.d 2>/dev/null
rm -rf /etc/systemd/system/vpn-dashboard.service.d 2>/dev/null

systemctl daemon-reload
echo "  Service files removed."

# ============================================================
# STEP 3: REMOVE FIREWALL RULES
# ============================================================
echo ""
echo "============================================================"
echo "  [3/6] Removing Firewall Rules"
echo "============================================================"

# Flush our custom rules
echo "  Flushing iptables rules..."
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true

# Also clear any PIA-specific chains
for chain in $(iptables -S 2>/dev/null | grep '^\-N piavpn' | awk '{print $2}'); do
  iptables -F "$chain" 2>/dev/null || true
  iptables -X "$chain" 2>/dev/null || true
done

# Save the now-empty rules
netfilter-persistent save 2>/dev/null || true
echo "  Firewall rules flushed."

# ============================================================
# STEP 4: REMOVE CONFIG & DATA FILES
# ============================================================
echo ""
echo "============================================================"
echo "  [4/6] Removing Configuration & Data"
echo "============================================================"

echo "  Removing firewall and helper scripts..."
rm -f /usr/local/bin/vpn-fw.sh
rm -f /usr/local/bin/pia-wait-and-connect.sh

echo "  Removing dashboard config..."
rm -f /etc/vpn-dashboard.conf
rm -f /etc/dnsmasq.conf
mv /etc/dnsmasq.conf.orig /etc/dnsmasq.conf 2>/dev/null || true

echo "  Removing dashboard state data..."
# Save PIN hash if user wants to reinstall later
if [ -f /var/lib/vpn-dashboard/pin.hash ]; then
  echo "    (Keeping PIN hash backup at /root/vpn-dashboard-pin.backup)"
  cp /var/lib/vpn-dashboard/pin.hash /root/vpn-dashboard-pin.backup 2>/dev/null || true
fi
rm -rf /var/lib/vpn-dashboard

echo "  Removing NetworkManager unmanaged config..."
rm -f /etc/NetworkManager/conf.d/99-unmanaged-lan.conf
rm -f /etc/NetworkManager/conf.d/99-unmanaged-wlan.conf
systemctl restart NetworkManager 2>/dev/null || true

echo "  Removing dashboard app..."
rm -rf /opt/vpn-dashboard

echo "  Files removed."

# ============================================================
# STEP 5: RESTORE CMDLINE.TXT (re-enable IPv6)
# ============================================================
echo ""
echo "============================================================"
echo "  [5/6] Re-enabling IPv6"
echo "============================================================"
if [ -f /boot/firmware/cmdline.txt ]; then
  if grep -q "ipv6.disable=1" /boot/firmware/cmdline.txt; then
    sed -i 's/ ipv6.disable=1//g' /boot/firmware/cmdline.txt
    echo "  Removed ipv6.disable=1 from cmdline.txt"
  else
    echo "  IPv6 was not disabled (cmdline.txt unchanged)"
  fi
elif [ -f /boot/cmdline.txt ]; then
  if grep -q "ipv6.disable=1" /boot/cmdline.txt; then
    sed -i 's/ ipv6.disable=1//g' /boot/cmdline.txt
    echo "  Removed ipv6.disable=1 from /boot/cmdline.txt"
  else
    echo "  IPv6 was not disabled (cmdline.txt unchanged)"
  fi
fi

# ============================================================
# STEP 6: OPTIONAL PACKAGE REMOVAL
# ============================================================
echo ""
echo "============================================================"
echo "  [6/6] Optional Package Removal"
echo "============================================================"
echo ""
echo "Do you want to remove the installed packages too?"
echo "  - dnsmasq (DHCP/DNS)"
echo "  - tcpdump (packet sniffer)"
echo "  - speedtest-cli (speed test)"
echo "  - python3-flask, python3-qrcode (dashboard dependencies)"
echo "  - PIA VPN (piactl)"
echo ""
echo "Removing these won't break anything, but keeping them"
echo "doesn't hurt either. Choose wisely:"
echo ""
echo "  1) Remove all packages (clean slate)"
echo "  2) Keep packages (in case you reinstall)"
echo "  3) Remove everything EXCEPT PIA (in case you use PIA elsewhere)"
echo ""
read -p "Choice [2]: " PKG_CHOICE
PKG_CHOICE=${PKG_CHOICE:-2}

case "$PKG_CHOICE" in
  1)
    echo ""
    echo "  Removing all packages..."
    apt-get remove -y dnsmasq tcpdump speedtest-cli python3-flask python3-qrcode 2>/dev/null || true
    if command -v piactl &>/dev/null; then
      echo "  Uninstalling PIA..."
      # PIA doesn't have a clean uninstaller, remove manually
      rm -rf /opt/piavpn
      rm -f /usr/local/bin/piactl
      rm -f /usr/bin/piactl
      rm -rf /etc/private-internet-access
      rm -rf /var/lib/piavpn 2>/dev/null
      rm -rf ~/.config/privateinternetaccess 2>/dev/null
      echo "  PIA removed."
    fi
    apt-get autoremove -y 2>/dev/null || true
    echo "  Packages removed."
    ;;
  3)
    echo ""
    echo "  Removing packages (keeping PIA)..."
    apt-get remove -y dnsmasq tcpdump speedtest-cli python3-flask python3-qrcode 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    echo "  Packages removed (PIA kept)."
    ;;
  2)
    echo "  Keeping all packages."
    ;;
  *)
    echo "  Invalid choice. Keeping all packages."
    ;;
esac

# ============================================================
# DONE
# ============================================================
echo ""
echo "============================================================"
echo "  Uninstall Complete!"
echo "============================================================"
echo ""
echo "The following has been removed from this Pi:"
echo "  - PS5 VPN Gateway (all services and configs)"
echo "  - Firewall rules (flushed)"
echo "  - Network interface configuration"
echo ""
if [ "$PKG_CHOICE" = "1" ]; then
  echo "  - All packages including PIA"
elif [ "$PKG_CHOICE" = "3" ]; then
  echo "  - All packages except PIA"
else
  echo "  - Packages kept installed"
fi
echo ""
echo "------------------------------------------------------------"
echo "  IMPORTANT - NEXT STEPS"
echo "------------------------------------------------------------"
echo ""
echo "  Your PS5 currently has NO internet connection because the"
echo "  Pi is no longer acting as a gateway."
echo ""
echo "  To get the PS5 back online:"
echo ""
echo "    1. Unplug the Ethernet cable from the Pi's USB adapter"
echo "    2. Plug it directly into your router"
echo "    3. On PS5: Settings -> Network -> Test Internet Connection"
echo ""
echo "  To restore IPv6 (if you need it), reboot the Pi:"
echo ""
echo "    sudo reboot"
echo ""
if [ -f /root/vpn-dashboard-pin.backup ]; then
  echo "  NOTE: Your old dashboard PIN was backed up to:"
  echo "    /root/vpn-dashboard-pin.backup"
  echo "  (Delete this file if you don't plan to reinstall)"
  echo ""
fi
echo "============================================================"
echo "  PS5 VPN Gateway Uninstaller"
echo "  Author: Daniel Smyth"
echo "  https://github.com/daniel-smyth09/PS5-VPN-Dashboard"
echo "============================================================"
echo ""
