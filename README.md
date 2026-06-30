# PS5 VPN Dashboard — Raspberry Pi 4/5

A complete, self-contained installer that turns a Raspberry Pi into a VPN gateway for your PlayStation 5. All PS5 traffic is encrypted and routed through Private Internet Access (PIA) — and nothing else on your network is affected.

**Author:** Daniel Smyth  
**GitHub:** [daniel-smyth09/PS5-VPN-Dashboard](https://github.com/daniel-smyth09/PS5-VPN-Dashboard)

---

## 🚀 Quick Install

On your Raspberry Pi (after flashing Raspberry Pi OS Lite and SSH'ing in):

```bash
# 1. Clone this repo
git clone https://github.com/daniel-smyth09/PS5-VPN-Dashboard.git
cd PS5-VPN-Dashboard

# 2. Run the installer
sudo bash install-vpn.sh
```

That's it. The installer walks you through everything else interactively (wiring, PIA account, network detection). Full step-by-step instructions below.

---

## What This Does

```
Internet ←→ Router ←(eth)→ Pi ←(USB eth)→ PS5
```

- ✅ All PS5 traffic is encrypted and routed through PIA VPN
- ✅ Other devices in your house (phones, laptops) are completely unaffected
- ✅ Kill switch blocks the PS5 instantly if the VPN ever drops
- ✅ Web dashboard to control everything from your phone
- ✅ Gigabit speeds on Pi 5 (~800 Mbps through WireGuard)

---

## Hardware You Need

### 1. Raspberry Pi (Pi 5 strongly recommended)

The **[Raspberry Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/)** is strongly recommended because its CPU can push ~800 Mbps through WireGuard — fast enough to saturate most home internet connections.

The Pi 4 also works but caps out around ~300 Mbps through the VPN. Either way, you also need:

- **Official Pi power supply** (5V 5A for Pi 5, 5V 3A for Pi 4 — third-party chargers cause stability issues)
- **MicroSD card** (16GB+, Class 10 or A2 speed)
- **Active cooler** for the Pi 5 (the official cooler or a small fan — the Pi throttles without it)

### 2. USB 3.0 Gigabit Ethernet Adapter

This is the critical component — it becomes the LAN port that connects to your PS5. You **must** use a USB 3.0 Gigabit adapter with the **ASIX AX88179 chipset** for reliable gigabit speeds on the Pi.

**Recommended (UK):** [UGREEN USB 3.0 Gigabit Ethernet Adapter](https://www.amazon.co.uk/UGREEN-Ethernet-Aluminum-Internet-Compatible-Sliver/dp/B07M91X2NW) — this is the exact model tested and confirmed working at full gigabit speeds.

Alternatives with the same ASIX AX88179 chipset:
- Cable Matters USB 3.0 to Gigabit Ethernet
- Plugable USB 3.0 Gigabit Ethernet (USBC-E1000)

⚠️ **Avoid:** Cheap adapters with Realtek RTL8152/RTL8153 chipsets — they work but are flaky under sustained load. Avoid anything labelled "100 Mbps" (you want Gigabit).

### 3. Cables & Networking

- **Two Ethernet cables** (Cat 5e or Cat 6 — both come with most routers)
- **A router with a free Ethernet port** (your existing home router is fine)

### 4. PIA VPN Account

- **Sign up at [privateinternetaccess.com](https://www.privateinternetaccess.com)** if you don't have one
- You'll need your username (email or x-prefixed) and password during install

> 💵 **Affiliate disclosure:** If you'd like to support this project, you can sign up for PIA using my affiliate link. I earn a small commission at **no extra cost to you** — PIA pays the commission, you pay the same price. If you'd prefer not to use it, the regular link above works identically.
>
> **👉 [Get PIA VPN — affiliate link (supports this project)](https://www.privateinternetaccess.com/pages/buy-a-vpn/1218buyavpn?invite=U2FsdGVkX18xigjex1hWb2nhc3SLIAL9-rojYcMYzG0%2CKL4FF4d70mcKMGBfLEg9dNNnhHU)**

---

## What's In This Package

```
PS5-VPN-Dashboard/
├── install-vpn.sh              The master installer (run this)
├── uninstall-vpn.sh            The complete uninstaller
├── README.md                   This file
└── files/
    ├── app.py                  The dashboard web application
    └── pia-linux-arm64-*.run   PIA installer (bundled)
```

The installer asks which PIA `.run` file to use:
1. **Bundled installer** (`files/pia-linux-arm64-*.run`) — default, just press Enter
2. **Your own installer** — download from [PIA](https://www.privateinternetaccess.com/download/linux-vpn), name it `files/piavpn.run`

---

## Before You Start

1. **Flash Raspberry Pi OS Lite (64-bit) Bookworm** to your MicroSD card
   - Use the [Raspberry Pi Imager](https://rpf.io/imager)
   - Click the gear icon to configure:
     - ✅ Enable SSH (use password authentication)
     - ✅ Set username and password
     - ✅ Set Wi-Fi country (for initial setup only)

2. **Boot the Pi and SSH in**, then update:
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   ```

3. **Clone this repository to the Pi:**
   ```bash
   git clone https://github.com/daniel-smyth09/PS5-VPN-Dashboard.git
   cd PS5-VPN-Dashboard
   ```
   (No internet on the Pi? Download the ZIP from GitHub on your PC and transfer it via [WinSCP](https://winscp.net/).)

---

## Hardware Wiring

Plug everything in **before** running the installer:

```
  +----------+        +----------+        +----------+
  |  ROUTER  |========|   PI 5   |========|   PS5    |
  +----------+  eth   +----------+  eth   +----------+
                    onboard |  | USB 3.0
                       port |  | adapter
                            |  |
                            v  v
                     (next to USB   (plug into a
                      ports)         BLUE USB 3.0
                                     port)
```

### Step-by-step wiring

1. **Router → Pi (onboard port):** Plug an Ethernet cable into the Pi's **built-in** network port (the one next to the USB ports). Connect the other end to your router.

2. **USB adapter → Pi:** Plug the USB-Ethernet adapter into one of the Pi's **BLUE** USB 3.0 ports.
   - ❌ NOT the black USB 2.0 ports (too slow)
   - ❌ NOT the USB-C port (power only)

3. **PS5 → USB adapter:** Plug an Ethernet cable into the USB adapter. Connect the other end to your PS5.

4. **Power on** the Pi and SSH in.

### Why this wiring?

- **Onboard Ethernet** = WAN (gets internet from your router)
- **USB adapter** = LAN (serves the PS5 only)
- Only the PS5 goes through the VPN — your phones, laptops, etc. are completely unaffected

---

## Installation

Run the installer on the Pi (from the cloned repo directory):

```bash
cd PS5-VPN-Dashboard
sudo bash install-vpn.sh
```

The installer will automatically:

- Detect your OS and architecture
- Update system packages (`apt`/`dnf`/`yum`/`pacman`)
- Show the wiring diagram and confirm hardware
- Auto-detect your network interfaces (onboard vs USB)
- Ask which PIA installer to use (bundled or your own)
- Ask for your PIA username and password
- Disable IPv6 (prevents VPN leaks)
- Install PIA VPN with WireGuard
- Set up the LAN interface (`10.99.99.1/24`)
- Configure DHCP + DNS for the PS5
- Configure firewall + NAT + kill switch
- Enable VPN auto-connect on boot
- Install the web dashboard
- Generate a security PIN
- Start everything

Takes ~5–10 minutes. At the end it prints the dashboard URL and your generated PIN.

### PIA Installer Options

PIA doesn't offer a stable "latest" download URL, so the installer asks which `.run` file to use:

**Option 1 (default) — Use the bundled installer:**
- Located at `files/pia-linux-arm64-*.run`
- Just press Enter at the prompt
- Easiest path

**Option 2 — Provide your own installer:**
- Download the latest Linux ARM installer from [PIA's download page](https://www.privateinternetaccess.com/download/linux-vpn)
- Place the `.run` file in the `files/` directory
- Rename it to **exactly**: `piavpn.run`
- Choose option 2 at the prompt and confirm

Why not auto-download? PIA's website generates download links dynamically — there's no static "latest" URL, and building from GitHub source takes 30+ minutes on a Pi. The bundled file guarantees a working install; option 2 lets you use a newer version if you want.

---

## PIA Login

During installation, you'll be asked for your PIA credentials:

- **Username:** your email address (e.g. `you@example.com`), or an x-prefixed username (e.g. `x1234567`) if your account uses one
- **Password:** the password you set when signing up for PIA

Don't have an account? Sign up at [privateinternetaccess.com](https://www.privateinternetaccess.com).

If login fails during install, you can log in manually later:
```bash
piactl login
```

---

## Dashboard

Access from any device on your home network:

```
http://PI-IP:8080
```

**Install as an app on iPhone:**
1. Open the URL in Safari
2. Tap the Share button (square with up arrow)
3. Tap "Add to Home Screen"

### Features

| Category | Features |
|----------|----------|
| **VPN Control** | Live status, IP, region, connection timer, connect/disconnect/reconnect, quick-reconnect |
| **Regions** | Searchable list, favourites, quick-connect bar, one-tap switching |
| **Throughput** | Live download/upload graph, session totals |
| **Diagnostics** | Speed test, PSN latency test, live latency monitor, kill switch test, DNS leak test |
| **Stats** | 7-day data usage chart, connection history |
| **Traffic** | PS5 packet sniffer (DNS queries + connections) |
| **System** | CPU/RAM/temp/uptime, auto-reconnect toggle, daily scheduled reconnect |
| **Power** | Reboot/shutdown Pi (PIN protected), QR code for new devices |

**Defaults:** Region = Netherlands · Protocol = WireGuard · PIN = printed at end of install

---

## Switching Regions

**Via dashboard:** Tap a region in the list, or use the quick-connect bar (star regions to pin them as favourites).

**Via SSH:**
```bash
piactl set region germany
piactl disconnect && sleep 2 && piactl connect
```

List all available regions:
```bash
piactl get regions
```

---

## Verify It's Working

1. **On PS5:** Settings → Network → Test Internet Connection  
   Should succeed and show a download speed.

2. **On PS5 browser:** Open [ipleak.net](https://ipleak.net)
   - ✅ IP = PIA server (Netherlands etc.)
   - ✅ No mention of your real ISP
   - ✅ DNS = Cloudflare (`1.1.1.1`) via tunnel

3. **In dashboard:** Tap "Test Kill Switch"
   - Should show ✅ "Kill switch working"
   - This disconnects the VPN for ~6 seconds, then reconnects

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| **PS5 can't get an IP** | `sudo systemctl restart lan-up dnsmasq` then `sudo journalctl -u dnsmasq -f` |
| **PS5 connects but no internet** | `piactl get connectionstate` (must say "Connected") — check `sudo iptables -L FORWARD -n -v` |
| **VPN not auto-connecting on boot** | `sudo systemctl status pia-connect` and `sudo journalctl -u pia-connect` |
| **Dashboard not loading** | `sudo systemctl status vpn-dashboard` and `sudo journalctl -u vpn-dashboard -f` |
| **PIA login failed** | Run `piactl login` manually and enter your credentials |
| **Forgot PIN** | `echo -n "1234" \| sha256sum \| awk '{print $1}' \| sudo tee /var/lib/vpn-dashboard/pin.hash` (replace `1234`) |
| **USB adapter not detected** | `ls /sys/class/net/`, `ip link show`, `dmesg \| grep -i usb` — should appear as `eth1`, `enx...`, or `usb0` |
| **Slow speeds** | Make sure the adapter is in a **blue USB 3.0 port** (not black USB 2.0) |

---

## Architecture Details

**Interfaces:**
- `WAN` (onboard eth) = WAN, gets DHCP from your router
- `LAN` (USB adapter) = LAN, `10.99.99.1/24`, serves PS5
- `wgpia0` = WireGuard tunnel to PIA

**Network:**
- Subnet: `10.99.99.0/24`
- Pi LAN IP: `10.99.99.1`
- PS5 IP range: `10.99.99.10` – `10.99.99.50` (DHCP)
- DNS: `1.1.1.1`, `1.0.0.1` (Cloudflare, routed through tunnel)

**Security:**
- Kill switch: `FORWARD` chain drops anything from LAN → WAN, so if `wgpia0` drops, the PS5 has no internet
- IPv6 disabled: prevents IPv6 leaks around the IPv4 tunnel
- All PS5 traffic is NAT'd through `wgpia0`, so replies route back correctly

---

## Uninstall

To remove everything cleanly:

```bash
cd PS5-VPN-Dashboard
sudo bash uninstall-vpn.sh
```

The uninstaller will:

- Stop and disable all 6 services
- Remove all systemd service files
- Flush all iptables rules (firewall, NAT, kill switch)
- Remove all config files and dashboard data
- Restore NetworkManager to default (manage all interfaces)
- Re-enable IPv6 (removes the disable from `cmdline.txt`)
- Optionally remove packages (you choose: all, none, or all-except-PIA)
- Back up your PIN hash in case you reinstall

It asks for confirmation (type `yes`) before doing anything destructive, and gives you 3 options for package removal so you don't lose PIA if you use it elsewhere.

After uninstall, plug the PS5 directly into your router to restore its internet connection.

---

## Credits

**Author:** Daniel Smyth  
**GitHub:** [daniel-smyth09/ps5-vpn-gateway](https://github.com/daniel-smyth09/ps5-vpn-gateway)

Built for use with [Private Internet Access (PIA) VPN](https://www.privateinternetaccess.com).  
"WireGuard" is a registered trademark of Jason A. Donenfeld.  
"PlayStation" and "PS5" are trademarks of Sony Interactive Entertainment.
