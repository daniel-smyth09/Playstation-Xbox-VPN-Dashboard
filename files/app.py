#!/usr/bin/env python3
import subprocess, os, time, threading, zlib, struct, math, json, re, hashlib
from flask import Flask, jsonify, request

app = Flask(__name__)
VPN_IF = 'wgpia0'
PORT = 8080
STATE_FILE = '/var/lib/vpn-dashboard/state.json'
HISTORY_FILE = '/var/lib/vpn-dashboard/history.json'
PIN_FILE = '/var/lib/vpn-dashboard/pin.hash'
DATA_STATS_FILE = '/var/lib/vpn-dashboard/data-stats.json'
CONFIG_FILE = '/etc/vpn-dashboard.conf'

def _read_config():
    global LAN_IF, WAN_IF
    LAN_IF = 'eth1'
    WAN_IF = 'eth0'
    try:
        with open(CONFIG_FILE) as f:
            for line in f:
                if '=' in line and not line.strip().startswith('#'):
                    k, v = line.strip().split('=', 1)
                    if k.strip() == 'LAN_IF': LAN_IF = v.strip()
                    elif k.strip() == 'WAN_IF': WAN_IF = v.strip()
    except:
        pass

_read_config()

_net = {'rx': None, 'tx': None, 'ts': 0}
_cpu = {'idle': 0, 'total': 0}
_ip = {'v': None, 'ts': 0}
_icon_cache = {}
_speedtest = {'running': False, 'result': None, 'error': None}
_ks_test = {'running': False, 'result': None, 'error': None}
_latency = {'running': False, 'result': None, 'error': None}
_dnsleak = {'running': False, 'result': None, 'error': None}
_latmon = {'running': False, 'values': [], 'thread': None}
_sniffer = {'running': False, 'packets': [], 'process': None, 'thread': None}
_data_stats = {'last_rx': 0, 'last_tx': 0, 'days': []}
_vpn = {'state': 'Unknown', 'connected_since': 0, 'prev': 'Unknown', 'region': ''}
_watchdog = {'enabled': False, 'thread': None}
_state = {'favorites': [], 'last_region': '', 'autoconnect': False, 'daily_reconnect': False, 'reconnect_hour': 3}
_lock = threading.Lock()
DATA_STATS_FILE = '/var/lib/vpn-dashboard/data-stats.json'

# ============================================================
# Helpers
# ============================================================
def sh(cmd, t=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=t, shell=isinstance(cmd, str))
        return r.stdout.strip()
    except:
        return ''

def pia(*a):
    return sh(['piactl'] + list(a))

def get_ip():
    with _lock:
        now = time.time()
        if _ip['v'] and now - _ip['ts'] < 20:
            return _ip['v']
    ip = sh(['curl', '-s', '--max-time', '5', 'https://ifconfig.me'])
    if ip and ip.count('.') == 3:
        with _lock:
            _ip['v'] = ip
            _ip['ts'] = now
        return ip
    return _ip['v'] or ''

def net_bytes():
    try:
        with open('/proc/net/dev') as f:
            for l in f:
                if VPN_IF + ':' in l:
                    p = l.split()
                    return int(p[1]), int(p[9])
    except:
        pass
    return None, None

def fmt_b(b):
    for u in ['B','KB','MB','GB','TB']:
        if b < 1024: return f'{b:.1f} {u}'
        b /= 1024
    return f'{b:.1f} PB'

def fmt_up(s):
    if s <= 0: return '--'
    d = int(s // 86400)
    h = int((s % 86400) // 3600)
    m = int((s % 3600) // 60)
    sec = int(s % 60)
    if d: return f'{d}d {h}h {m}m'
    if h: return f'{h}h {m}m {sec}s'
    if m: return f'{m}m {sec}s'
    return f'{sec}s'

def fmt_ts(ts):
    try:
        t = time.localtime(ts)
        now = time.localtime()
        if t.tm_yday == now.tm_yday:
            return time.strftime('%H:%M', t)
        return time.strftime('%b %d %H:%M', t)
    except:
        return '?'

# ============================================================
# State persistence
# ============================================================
def _load_state():
    global _state
    try:
        with open(STATE_FILE) as f:
            _state.update(json.load(f))
    except:
        pass

def _save_state():
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, 'w') as f:
            json.dump(_state, f)
    except:
        pass

def _hash_pin(pin):
    return hashlib.sha256(pin.encode()).hexdigest()

def _check_pin(pin):
    try:
        with open(PIN_FILE) as f:
            return _hash_pin(pin) == f.read().strip()
    except:
        return False

def _pin_exists():
    return os.path.exists(PIN_FILE)

# ============================================================
# History
# ============================================================
def _log_history(event, region=''):
    try:
        hist = []
        try:
            with open(HISTORY_FILE) as f:
                hist = json.load(f)
        except:
            pass
        hist.insert(0, {'ts': time.time(), 'event': event, 'region': region})
        hist = hist[:100]
        with open(HISTORY_FILE, 'w') as f:
            json.dump(hist, f)
    except:
        pass

def _load_history():
    try:
        with open(HISTORY_FILE) as f:
            return json.load(f)
    except:
        return []

# ============================================================
# Data Usage Stats
# ============================================================
def _load_data_stats():
    global _data_stats
    try:
        with open(DATA_STATS_FILE) as f:
            saved = json.load(f)
            _data_stats.update(saved)
    except:
        pass

def _save_data_stats():
    try:
        with open(DATA_STATS_FILE, 'w') as f:
            json.dump(_data_stats, f)
    except:
        pass

def _data_stats_loop():
    while True:
        try:
            rx, tx = net_bytes()
            if rx is not None and tx is not None:
                last_rx = _data_stats.get('last_rx', rx)
                last_tx = _data_stats.get('last_tx', tx)
                d_rx = max(0, rx - last_rx)
                d_tx = max(0, tx - last_tx)
                today_str = time.strftime('%Y-%m-%d')
                days = _data_stats.setdefault('days', [])
                today_entry = None
                for d in days:
                    if d.get('date') == today_str:
                        today_entry = d
                        break
                if not today_entry:
                    today_entry = {'date': today_str, 'rx': 0, 'tx': 0}
                    days.append(today_entry)
                today_entry['rx'] += d_rx
                today_entry['tx'] += d_tx
                _data_stats['last_rx'] = rx
                _data_stats['last_tx'] = tx
                _data_stats['days'] = days[-30:]
                _save_data_stats()
        except:
            pass
        time.sleep(60)

# ============================================================
# Live Latency Monitor
# ============================================================
def _latmon_loop():
    while _latmon['running']:
        try:
            out = sh('ping -c 1 -W 3 ps5.np.playstation.net', t=5)
            m = re.search(r'time=([\d.]+)', out)
            ms = float(m.group(1)) if m else None
            _latmon['values'].append({'ts': time.time(), 'ms': ms})
            _latmon['values'] = _latmon['values'][-30:]
        except:
            pass
        time.sleep(10)

# ============================================================
# Packet Sniffer
# ============================================================
def _sniffer_loop():
    import subprocess as sp
    try:
        proc = sp.Popen(
            ['tcpdump', '-i', LAN_IF, '-l', '-n', '-q', '-t',
             'udp port 53 or (tcp[tcpflags] & tcp-syn != 0)'],
            stdout=sp.PIPE, stderr=sp.DEVNULL, text=True, bufsize=1
        )
        _sniffer['process'] = proc
        for line in proc.stdout:
            if not _sniffer['running']:
                break
            line = line.strip()
            if not line:
                continue
            ts = time.time()
            entry = {'ts': ts, 'raw': line, 'type': 'conn', 'detail': line}
            if 'A?' in line:
                m = re.search(r'A\?\s+(\S+)', line)
                entry['type'] = 'dns'
                entry['detail'] = m.group(1).rstrip('.') if m else line
            parts = line.split()
            if len(parts) >= 3:
                dst = parts[2] if parts[2] != '>' else (parts[3] if len(parts) > 3 else '')
                dst = dst.split('.')[0:4]
                entry['dest_ip'] = '.'.join(dst) if len(dst) == 4 else ''
            _sniffer['packets'].append(entry)
            _sniffer['packets'] = _sniffer['packets'][-200:]
    except Exception as e:
        _sniffer['error'] = str(e)
    finally:
        try:
            if _sniffer.get('process'):
                _sniffer['process'].terminate()
        except:
            pass
        _sniffer['process'] = None
        _sniffer['running'] = False

# ============================================================
# Background monitors
# ============================================================
def _monitor_vpn():
    while True:
        try:
            state = pia('get', 'connectionstate')
            region = pia('get', 'region')
            now = time.time()
            with _lock:
                if state == 'Connected' and _vpn['prev'] != 'Connected':
                    _vpn['connected_since'] = now
                    _log_history('connected', region)
                elif state != 'Connected' and _vpn['prev'] == 'Connected':
                    _vpn['connected_since'] = 0
                    _log_history('disconnected')
                _vpn['state'] = state
                _vpn['region'] = region
                _vpn['prev'] = state
        except:
            pass
        time.sleep(3)

def _watchdog_loop():
    while _watchdog['enabled']:
        try:
            state = pia('get', 'connectionstate')
            if state == 'Disconnected':
                pia('connect')
        except:
            pass
        time.sleep(10)

def _daily_reconnect_loop():
    last_reconnect_day = -1
    while True:
        try:
            if _state.get('daily_reconnect'):
                now = time.localtime()
                hour = _state.get('reconnect_hour', 3)
                today_key = now.tm_yday
                if now.tm_hour == hour and today_key != last_reconnect_day:
                    last_reconnect_day = today_key
                    pia('disconnect')
                    time.sleep(3)
                    pia('connect')
                    _log_history('daily_reconnect', pia('get', 'region'))
        except:
            pass
        time.sleep(60)

# ============================================================
# PWA Icon
# ============================================================
def _encode_png(raw_data, w, h):
    def chunk(ctype, data):
        c = ctype + data
        crc = zlib.crc32(c) & 0xffffffff
        return struct.pack('>I', len(data)) + c + struct.pack('>I', crc)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw_data, 9)) + chunk(b'IEND', b'')

def _generate_icon(size=512):
    if size in _icon_cache:
        return _icon_cache[size]
    cx, cy = size / 2, size / 2
    sw, sh_ = size * 0.35, size * 0.42
    BG = b'\x0d\x11\x17\xff'
    GREEN = b'\x3f\xb9\x50\xff'
    DARK = b'\x2a\x7b\x35\xff'
    rows = []
    for y in range(size):
        row = bytearray([0])
        sy = (y - cy) / sh_
        for x in range(size):
            sx = (x - cx) / sw
            color = BG
            in_shield = False
            if -1.0 <= sy <= 1.2:
                if sy <= 0.15:
                    max_w = 1.0
                    if sy < -0.80:
                        t = max(0, min(1, (sy + 1.0) / 0.20))
                        max_w = t ** 0.5
                    in_shield = abs(sx) <= max_w
                else:
                    in_shield = abs(sx) <= max(0, 1.0 - (sy - 0.15) / 1.05)
            if in_shield:
                color = GREEN
                px, py = x - cx, y - cy
                bw, bh = size * 0.065, size * 0.05
                by = size * 0.03
                if abs(px) < bw and abs(py - by) < bh:
                    color = DARK
                arc_cy = by - bh
                pdist = math.sqrt(px*px + (py - arc_cy)**2)
                if pdist < bw * 0.85 and pdist > bw * 0.45 and py < arc_cy:
                    color = DARK
            row.extend(color)
        rows.append(bytes(row))
    _icon_cache[size] = _encode_png(b''.join(rows), size, size)
    return _icon_cache[size]

# ============================================================
# Core API
# ============================================================
@app.route('/')
def index():
    return PAGE

@app.route('/api/status')
def api_status():
    with _lock:
        state, connected_since = _vpn['state'], _vpn['connected_since']
    region = pia('get', 'region')
    proto = pia('get', 'protocol')
    up = os.path.exists(f'/sys/class/net/{VPN_IF}')
    ip = get_ip() if state == 'Connected' and up else ''
    rx, tx = net_bytes()
    conn_time = (time.time() - connected_since) if connected_since and state == 'Connected' else 0
    ps5_ip = ''
    try:
        with open('/var/lib/misc/dnsmasq.leases') as f:
            for l in f:
                p = l.strip().split()
                if len(p) >= 4:
                    ps5_ip = p[2]; break
    except:
        pass
    return jsonify({
        'state': state, 'region': region, 'protocol': proto,
        'pubip': ip, 'vpn_up': up, 'ps5_ip': ps5_ip,
        'total_rx': fmt_b(rx) if rx else '0 B', 'total_tx': fmt_b(tx) if tx else '0 B',
        'connection_time': fmt_up(conn_time),
        'autoconnect': _watchdog['enabled'],
        'daily_reconnect': _state.get('daily_reconnect', False),
        'reconnect_hour': _state.get('reconnect_hour', 3),
    })

@app.route('/api/regions')
def api_regions():
    out = pia('get', 'regions')
    cur = pia('get', 'region')
    return jsonify({'regions': [r.strip() for r in out.split('\n') if r.strip()], 'current': cur, 'favorites': _state.get('favorites', [])})

@app.route('/api/connect', methods=['POST'])
def api_connect():
    pia('connect'); return jsonify({'ok': True})

@app.route('/api/disconnect', methods=['POST'])
def api_disconnect():
    pia('disconnect'); return jsonify({'ok': True})

@app.route('/api/reconnect', methods=['POST'])
def api_reconnect():
    pia('disconnect'); time.sleep(2); pia('connect'); return jsonify({'ok': True})

@app.route('/api/region', methods=['POST'])
def api_set_region():
    r = request.get_json().get('region', '')
    pia('set', 'region', r)
    _state['last_region'] = r; _save_state()
    return jsonify({'ok': True})

@app.route('/api/favorite', methods=['POST'])
def api_favorite():
    r = request.get_json().get('region', '')
    favs = _state.setdefault('favorites', [])
    if r in favs: favs.remove(r)
    else: favs.append(r)
    _save_state()
    return jsonify({'ok': True, 'favorites': favs})

@app.route('/api/quickreconnect', methods=['POST'])
def api_quick_reconnect():
    last = _state.get('last_region') or pia('get', 'region')
    pia('set', 'region', last)
    pia('disconnect'); time.sleep(2); pia('connect')
    return jsonify({'ok': True, 'region': last})

@app.route('/api/autoconnect', methods=['POST'])
def api_autoconnect():
    enabled = request.get_json().get('enabled', False)
    _watchdog['enabled'] = enabled
    if enabled and (_watchdog['thread'] is None or not _watchdog['thread'].is_alive()):
        _watchdog['thread'] = threading.Thread(target=_watchdog_loop, daemon=True)
        _watchdog['thread'].start()
    _state['autoconnect'] = enabled; _save_state()
    return jsonify({'ok': True, 'enabled': enabled})

@app.route('/api/schedule', methods=['POST'])
def api_schedule():
    data = request.get_json()
    _state['daily_reconnect'] = data.get('enabled', False)
    _state['reconnect_hour'] = int(data.get('hour', 3))
    _save_state()
    return jsonify({'ok': True})

@app.route('/api/throughput')
def api_throughput():
    rx, tx = net_bytes()
    now = time.time()
    if rx is None:
        _net['rx'] = None
        return jsonify({'rx_mbps': 0, 'tx_mbps': 0, 'available': False})
    if _net['rx'] is not None and _net['ts'] > 0:
        dt = now - _net['ts']
        rx_m = max(0, (rx - _net['rx']) * 8 / dt / 1e6) if dt > 0 else 0
        tx_m = max(0, (tx - _net['tx']) * 8 / dt / 1e6) if dt > 0 else 0
    else:
        rx_m = tx_m = 0
    _net.update(rx=rx, tx=tx, ts=now)
    return jsonify({'rx_mbps': round(rx_m, 1), 'tx_mbps': round(tx_m, 1), 'available': True})

@app.route('/api/system')
def api_system():
    try:
        with open('/proc/stat') as f: p = f.readline().split()[1:]
        idle = int(p[3]) + int(p[4]); total = sum(int(x) for x in p)
    except: idle = total = 0
    cpu = round((1 - (idle - _cpu['idle']) / (total - _cpu['total'])) * 100, 1) if _cpu['total'] > 0 and total > _cpu['total'] else 0
    _cpu.update(idle=idle, total=total)
    mt = mu = 0
    try:
        with open('/proc/meminfo') as f:
            for l in f:
                if l.startswith('MemTotal:'): mt = int(l.split()[1])
                elif l.startswith('MemAvailable:'): mu = mt - int(l.split()[1])
    except: pass
    temp = 0
    try:
        with open('/sys/class/thermal/thermal_zone0/temp') as f: temp = int(f.read().strip()) / 1000
    except: pass
    up_s = 0
    try:
        with open('/proc/uptime') as f: up_s = float(f.read().split()[0])
    except: pass
    return jsonify({'cpu': cpu, 'mem_pct': round(mu/mt*100, 1) if mt else 0,
        'mem_str': f'{mu//1024}/{mt//1024} MB', 'temp': round(temp, 1),
        'uptime_str': fmt_up(up_s), 'load': sh("awk '{print $1, $2, $3}' /proc/loadavg")})

@app.route('/api/clients')
def api_clients():
    out = []
    try:
        with open('/var/lib/misc/dnsmasq.leases') as f:
            for l in f:
                p = l.strip().split()
                if len(p) >= 4:
                    out.append({'mac': p[1], 'ip': p[2], 'name': p[3] if p[3] != '*' else 'PS5'})
    except: pass
    return jsonify({'clients': out})

@app.route('/api/logs')
def api_logs():
    return jsonify({'logs': sh('journalctl -u pia-daemon -u pia-connect --no-pager -n 15 2>&1', 5)})

# ============================================================
# History API
# ============================================================
@app.route('/api/history')
def api_history():
    return jsonify({'history': _load_history()})

# ============================================================
# Data Usage + Live Latency endpoints
# ============================================================
@app.route('/api/datastats')
def api_datastats():
    return jsonify({'days': _data_stats.get('days', [])[-7:]})

@app.route('/api/latmon/start', methods=['POST'])
def api_latmon_start():
    if not _latmon['running']:
        _latmon['running'] = True
        _latmon['values'] = []
        _latmon['thread'] = threading.Thread(target=_latmon_loop, daemon=True)
        _latmon['thread'].start()
    return jsonify({'ok': True})

@app.route('/api/latmon/stop', methods=['POST'])
def api_latmon_stop():
    _latmon['running'] = False
    return jsonify({'ok': True})

@app.route('/api/latmon/status')
def api_latmon_status():
    return jsonify({'running': _latmon['running'], 'values': _latmon['values']})

# ============================================================
# Sniffer endpoints
# ============================================================
@app.route('/api/sniffer/start', methods=['POST'])
def api_sniffer_start():
    if not _sniffer['running']:
        _sniffer['running'] = True
        _sniffer['packets'] = []
        _sniffer['error'] = None
        _sniffer['thread'] = threading.Thread(target=_sniffer_loop, daemon=True)
        _sniffer['thread'].start()
    return jsonify({'ok': True})

@app.route('/api/sniffer/stop', methods=['POST'])
def api_sniffer_stop():
    _sniffer['running'] = False
    try:
        if _sniffer.get('process'):
            _sniffer['process'].terminate()
    except:
        pass
    return jsonify({'ok': True})

@app.route('/api/sniffer/status')
def api_sniffer_status():
    return jsonify({'running': _sniffer['running'], 'packets': _sniffer['packets'][-100:], 'error': _sniffer.get('error')})

@app.route('/api/sniffer/clear', methods=['POST'])
def api_sniffer_clear():
    _sniffer['packets'] = []
    return jsonify({'ok': True})

# ============================================================
# Speedtest
# ============================================================
def _run_speedtest():
    try:
        _speedtest['running'] = True; _speedtest['result'] = None; _speedtest['error'] = None
        if sh('command -v speedtest-cli'):
            out = sh('speedtest-cli --json 2>&1', t=120)
            if not out:
                _speedtest['error'] = 'No output (timed out)'
                return
            data = json.loads(out)
            srv = data.get('server', {})
            client = data.get('client', {})
            _speedtest['result'] = {
                'download': round(data.get('download', 0) / 1e6, 1),
                'upload': round(data.get('upload', 0) / 1e6, 1),
                'ping': round(data.get('ping', 0), 1),
                'server': f"{srv.get('sponsor', srv.get('name', '?'))}, {srv.get('country', '?')}",
                'isp': client.get('isp', ''),
            }
        elif sh('command -v speedtest'):
            out = sh('speedtest --format=json --accept-license --accept-gdpr 2>&1', t=120)
            if not out:
                _speedtest['error'] = 'No output (timed out)'
                return
            data = json.loads(out)
            srv = data.get('server', {})
            _speedtest['result'] = {
                'download': round(data.get('download', {}).get('bandwidth', 0) * 8 / 1e6, 1),
                'upload': round(data.get('upload', {}).get('bandwidth', 0) * 8 / 1e6, 1),
                'ping': round(data.get('ping', {}).get('latency', 0), 1),
                'server': f"{srv.get('name', '?')}, {srv.get('location', '?')}",
                'isp': data.get('isp', ''),
            }
        else:
            _speedtest['error'] = 'speedtest not installed. Run on Pi: sudo apt install -y speedtest-cli'
    except Exception as e:
        _speedtest['error'] = str(e)
    finally:
        _speedtest['running'] = False

@app.route('/api/speedtest/start', methods=['POST'])
def api_speedtest_start():
    if not _speedtest['running']:
        threading.Thread(target=_run_speedtest, daemon=True).start()
    return jsonify({'ok': True})

@app.route('/api/speedtest/status')
def api_speedtest_status():
    return jsonify({'running': _speedtest['running'], 'result': _speedtest['result'], 'error': _speedtest['error']})

# ============================================================
# Kill Switch Test (PIN protected)
# ============================================================
def _run_killswitch_test():
    try:
        _ks_test['running'] = True; _ks_test['result'] = None; _ks_test['error'] = None
        pia('disconnect'); time.sleep(4)
        rules = sh('iptables -S FORWARD')
        has_rule = any('DROP' in l and (LAN_IF in l or 'wlan0' in l) and WAN_IF in l for l in rules.split('\n'))
        _ks_test['result'] = {'passed': has_rule, 'message': '\u2705 Kill switch working - PS5 protected' if has_rule else '\u274c Kill switch rule missing!'}
        pia('connect'); time.sleep(2)
    except Exception as e:
        _ks_test['error'] = str(e)
    finally:
        _ks_test['running'] = False

@app.route('/api/killswitch-test', methods=['POST'])
def api_killswitch_test():
    pin = request.get_json().get('pin', '')
    if not _pin_exists(): return jsonify({'ok': False, 'error': 'No PIN set'}), 403
    if not _check_pin(pin): return jsonify({'ok': False, 'error': 'Incorrect PIN'}), 403
    if not _ks_test['running']:
        threading.Thread(target=_run_killswitch_test, daemon=True).start()
    return jsonify({'ok': True})

@app.route('/api/killswitch-status')
def api_killswitch_status():
    return jsonify({'running': _ks_test['running'], 'result': _ks_test['result'], 'error': _ks_test['error']})

# ============================================================
# DNS Leak Test
# ============================================================
def _run_dnsleak():
    try:
        _dnsleak['running'] = True; _dnsleak['result'] = None; _dnsleak['error'] = None
        pia_dns = sh('ping -c 1 -W 2 10.0.0.243')
        pia_reachable = '1 received' in pia_dns or '1 packets received' in pia_dns
        dnsmasq_conf = sh('grep "^server=" /etc/dnsmasq.conf 2>/dev/null')
        resolv = sh('cat /etc/resolv.conf 2>/dev/null')
        nslookup_out = sh('nslookup example.com 2>&1')
        srv_match = re.search(r'Server:\s+(\S+)', nslookup_out)
        dns_server = srv_match.group(1) if srv_match else 'unknown'
        uses_pia = '10.0.0.243' in dnsmasq_conf or '10.0.0.242' in dnsmasq_conf
        if pia_reachable and uses_pia:
            status = 'pass'; message = '\u2705 DNS secure - queries go through PIA tunnel'
        elif pia_reachable:
            status = 'warn'; message = '\u26a0 PIA DNS reachable but dnsmasq config changed'
        else:
            status = 'fail'; message = '\u274c DNS may leak - PIA DNS not reachable'
        _dnsleak['result'] = {'status': status, 'message': message, 'pia_reachable': pia_reachable,
            'dns_server': dns_server, 'uses_pia': uses_pia, 'dnsmasq_conf': dnsmasq_conf, 'resolv_conf': resolv.strip()}
    except Exception as e:
        _dnsleak['error'] = str(e)
    finally:
        _dnsleak['running'] = False

@app.route('/api/dnsleak/start', methods=['POST'])
def api_dnsleak_start():
    if not _dnsleak['running']:
        threading.Thread(target=_run_dnsleak, daemon=True).start()
    return jsonify({'ok': True})

@app.route('/api/dnsleak/status')
def api_dnsleak_status():
    return jsonify({'running': _dnsleak['running'], 'result': _dnsleak['result'], 'error': _dnsleak['error']})

# ============================================================
# Latency Check
# ============================================================
def _run_latency():
    try:
        _latency['running'] = True; _latency['result'] = None; _latency['error'] = None
        out = sh('ping -c 5 -I wgpia0 ps5.np.playstation.net', t=20)
        m = re.search(r'rtt min/avg/max/mdev = [\d.]+/([\d.]+)/', out)
        mloss = re.search(r'(\d+)% packet loss', out)
        avg = float(m.group(1)) if m else 0
        loss = int(mloss.group(1)) if mloss else 0
        _latency['result'] = {'latency_ms': round(avg, 1), 'packet_loss': loss, 'target': 'PSN'}
    except Exception as e:
        _latency['error'] = str(e)
    finally:
        _latency['running'] = False

@app.route('/api/latency', methods=['POST'])
def api_latency_start():
    if not _latency['running']:
        threading.Thread(target=_run_latency, daemon=True).start()
    return jsonify({'ok': True})

@app.route('/api/latency/status')
def api_latency_status():
    return jsonify({'running': _latency['running'], 'result': _latency['result'], 'error': _latency['error']})

# ============================================================
# Power controls (PIN protected)
# ============================================================
@app.route('/api/reboot', methods=['POST'])
def api_reboot():
    if not _check_pin(request.get_json().get('pin', '')):
        return jsonify({'ok': False, 'error': 'Incorrect PIN'}), 403
    threading.Thread(target=lambda: (time.sleep(1), sh(['reboot'])), daemon=True).start()
    return jsonify({'ok': True})

@app.route('/api/shutdown', methods=['POST'])
def api_shutdown():
    if not _check_pin(request.get_json().get('pin', '')):
        return jsonify({'ok': False, 'error': 'Incorrect PIN'}), 403
    threading.Thread(target=lambda: (time.sleep(1), sh(['shutdown', '-h', 'now'])), daemon=True).start()
    return jsonify({'ok': True})

@app.route('/api/pin/check', methods=['POST'])
def api_pin_check():
    pin = request.get_json().get('pin', '')
    if not _pin_exists(): return jsonify({'ok': False, 'exists': False})
    return jsonify({'ok': _check_pin(pin), 'exists': True})

# ============================================================
# QR Code
# ============================================================
@app.route('/api/qr')
def api_qr():
    try:
        import qrcode, qrcode.image.svg
        ip = sh('hostname -I').split()[0]
        url = f'http://{ip}:{PORT}'
        qr = qrcode.QRCode(box_size=8, border=2, image_factory=qrcode.image.svg.SvgImage)
        qr.add_data(url)
        img = qr.make_image()
        return (img.to_string(), {'Content-Type': 'image/svg+xml'})
    except ImportError:
        return jsonify({'error': 'python3-qrcode not installed. Run: sudo apt install python3-qrcode'}), 500

# ============================================================
# PWA routes
# ============================================================
@app.route('/manifest.json')
def manifest():
    return jsonify({'name': 'PS5 VPN Dashboard', 'short_name': 'PS5 VPN', 'start_url': '/',
        'display': 'standalone', 'background_color': '#0d1117', 'theme_color': '#0d1117',
        'icons': [{'src': '/icon/192.png', 'sizes': '192x192', 'type': 'image/png'},
                  {'src': '/icon/512.png', 'sizes': '512x512', 'type': 'image/png', 'purpose': 'any maskable'}]})

@app.route('/icon/<int:size>.png')
def icon_route(size):
    return (_generate_icon(size), {'Content-Type': 'image/png'})

@app.route('/apple-touch-icon.png')
@app.route('/favicon.png')
def icon_default():
    return (_generate_icon(180), {'Content-Type': 'image/png'})

@app.route('/sw.js')
def sw():
    return ('self.addEventListener("install",e=>self.skipWaiting());self.addEventListener("activate",e=>e.waitUntil(self.clients.claim()));', {'Content-Type': 'application/javascript'})

# ============================================================
# PAGE
# ============================================================
PAGE = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="PS5 VPN">
<meta name="theme-color" content="#0d1117">
<link rel="manifest" href="/manifest.json">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="icon" type="image/png" href="/icon/192.png">
<title>PS5 VPN Dashboard</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0d1117;--card:#161b22;--border:#30363d;--text:#e6edf3;--dim:#7d8590;--green:#3fb950;--red:#f85149;--blue:#58a6ff;--amber:#d29922;--gold:#e3b341}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;font-size:15px;line-height:1.5;min-height:100vh}
.grid{display:grid;grid-template-columns:1fr;gap:12px;max-width:1100px;margin:0 auto;padding:12px}
@media(min-width:860px){.grid{grid-template-columns:1fr 1fr}}
.span-2{grid-column:1/-1}
.header{text-align:center;padding:12px 0 4px}
.header h1{font-size:22px;font-weight:700}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:16px}
.card h3{font-size:12px;font-weight:600;margin-bottom:12px;color:var(--dim);text-transform:uppercase;letter-spacing:.5px;display:flex;align-items:center;justify-content:space-between}
.status-row{display:flex;align-items:center;gap:10px;margin-bottom:10px}
.dot{width:12px;height:12px;border-radius:50%;flex-shrink:0}
.dot.on{background:var(--green);box-shadow:0 0 8px var(--green);animation:pulse 2s infinite}
.dot.off{background:var(--red);box-shadow:0 0 8px var(--red)}
.dot.wait{background:var(--amber);box-shadow:0 0 8px var(--amber);animation:pulse 1s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.state-text{font-size:18px;font-weight:600}
.detail-row{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid rgba(48,54,61,.5);font-size:14px}
.detail-row:last-child{border-bottom:none}
.detail-row span:first-child{color:var(--dim)}
.detail-row span:last-child{font-weight:500;text-align:right;word-break:break-all}
.btn-row{display:flex;gap:8px;flex-wrap:wrap}
.btn{flex:1;min-width:80px;padding:12px 8px;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;transition:opacity .2s,transform .1s;color:#fff}
.btn:active{transform:scale(.97)}
.btn:disabled{opacity:.4;cursor:not-allowed}
.btn-go{background:var(--green)}.btn-stop{background:var(--red)}.btn-rec{background:#388bfd}.btn-warn{background:var(--amber);color:#000}.btn-danger{background:#da3633}.btn-full{width:100%;margin-top:8px}
.speed-row{display:flex;gap:12px;margin-bottom:8px}
.speed-box{flex:1;background:rgba(255,255,255,.03);border-radius:8px;padding:12px;text-align:center}
.speed-val{font-size:26px;font-weight:700}
.speed-val.dl{color:var(--green)}.speed-val.ul{color:var(--blue)}
.speed-unit{font-size:12px;color:var(--dim);margin-top:2px}
canvas{width:100%;height:70px;display:block;margin:6px 0}
.totals{display:flex;justify-content:space-between;font-size:12px;color:var(--dim)}
.totals strong{color:var(--text)}
.search-box{width:100%;padding:10px 12px;background:var(--bg);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:14px;margin-bottom:8px}
.search-box:focus{outline:none;border-color:var(--blue)}
.region-list{max-height:340px;overflow-y:auto;border-radius:8px}
.region-item{display:flex;justify-content:space-between;align-items:center;padding:10px 12px;border-bottom:1px solid rgba(48,54,61,.4);cursor:pointer;transition:background .15s}
.region-item:hover{background:rgba(255,255,255,.04)}
.region-item.active{background:rgba(59,185,80,.08)}
.region-item.active .rname{color:var(--green);font-weight:600}
.region-left{display:flex;align-items:center;gap:8px;flex:1;min-width:0}
.star{cursor:pointer;font-size:16px;color:var(--dim);user-select:none}
.star.on{color:var(--gold)}
.rname{font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.rbtn{background:var(--border);color:var(--text);border:none;padding:4px 12px;border-radius:6px;font-size:12px;cursor:pointer;flex-shrink:0}
.region-item.active .rbtn{background:var(--green);color:#fff}
.bar-row{display:flex;align-items:center;gap:8px;margin-bottom:8px}
.bar-row span:first-child{width:40px;font-size:13px;color:var(--dim)}
.bar{flex:1;height:8px;background:rgba(255,255,255,.06);border-radius:4px;overflow:hidden}
.bar-fill{height:100%;border-radius:4px;background:var(--green);transition:width .5s}
.bar-fill.warn{background:var(--amber)}.bar-fill.danger{background:var(--red)}
.bar-row span:last-child{width:54px;text-align:right;font-size:13px}
.client-item{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid rgba(48,54,61,.4)}
.client-item:last-child{border-bottom:none}
.client-icon{font-size:20px}.client-name{font-weight:500;font-size:14px}.client-meta{font-size:12px;color:var(--dim)}
.logs{background:#010409;border:1px solid var(--border);border-radius:8px;padding:10px;font-size:11px;font-family:'SF Mono',Monaco,Consolas,monospace;color:var(--dim);max-height:200px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.toggle-row{display:flex;justify-content:space-between;align-items:center;padding:8px 0}
.toggle{position:relative;width:44px;height:24px;background:var(--border);border-radius:12px;cursor:pointer;transition:background .2s;flex-shrink:0}
.toggle.on{background:var(--green)}
.toggle::after{content:'';position:absolute;top:2px;left:2px;width:20px;height:20px;background:#fff;border-radius:50%;transition:transform .2s}
.toggle.on::after{transform:translateX(20px)}
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%) translateY(80px);background:var(--border);color:#fff;padding:10px 20px;border-radius:20px;font-size:14px;opacity:0;transition:all .3s;z-index:100;max-width:90%;text-align:center}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
.footer{text-align:center;color:var(--dim);font-size:12px;padding:16px 0}
.sniff-item{display:flex;align-items:center;gap:8px;padding:3px 0;border-bottom:1px solid rgba(48,54,61,.2);font-size:11px;line-height:1.4}
.sniff-item:last-child{border-bottom:none}
.sniff-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.sniff-dot.dns{background:var(--blue)}.sniff-dot.conn{background:var(--amber)}
.sniff-time{color:var(--dim);min-width:50px;flex-shrink:0}
.sniff-detail{flex:1;word-break:break-all;color:var(--text)}
.latency-box{text-align:center;padding:10px;background:rgba(255,255,255,.03);border-radius:8px;margin-bottom:8px}
.latency-val{font-size:32px;font-weight:700;color:var(--blue)}
.qc-btn{flex:1;min-width:100px;padding:14px 8px;border:1px solid var(--border);border-radius:10px;background:rgba(255,255,255,.03);color:var(--text);cursor:pointer;font-size:13px;font-weight:600;text-align:center;transition:all .15s}
.qc-btn:hover{border-color:var(--blue);background:rgba(88,166,255,.08)}
.qc-btn.active{border-color:var(--green);background:rgba(59,185,80,.1);color:var(--green)}
.qc-btn:active{transform:scale(.96)}
.result-box{text-align:center;padding:8px 0}
.hist-item{display:flex;align-items:center;gap:8px;padding:5px 0;border-bottom:1px solid rgba(48,54,61,.3);font-size:13px}
.hist-item:last-child{border-bottom:none}
.hist-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.hist-dot.conn{background:var(--green)}.hist-dot.disc{background:var(--red)}.hist-dot.rec{background:var(--blue)}.hist-dot.wol{background:var(--gold)}
.hist-time{color:var(--dim);font-size:12px;min-width:80px}
.hist-event{flex:1}
.modal-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.8);z-index:200;display:flex;align-items:center;justify-content:center}
.modal-box{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:24px;max-width:360px;width:90%;text-align:center}
.pin-input{width:100%;padding:12px;background:var(--bg);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:18px;text-align:center;margin-bottom:12px}
.pin-err{color:var(--red);font-size:13px;margin-bottom:8px;display:none}
.modal-btns{display:flex;gap:8px}
.modal-btns button{flex:1;padding:10px;border:none;border-radius:8px;cursor:pointer;font-weight:600}
</style>
</head>
<body>
<div class="header"><h1>PS5 VPN Dashboard <span id="headerStatus"></span></h1></div>
<div class="grid">

  <div class="card">
    <div class="status-row">
      <span class="dot off" id="dot"></span>
      <span class="state-text" id="state">Checking...</span>
    </div>
    <div class="detail-row"><span>Location</span><span id="region">&mdash;</span></div>
    <div class="detail-row"><span>VPN IP</span><span id="ip">&mdash;</span></div>
    <div class="detail-row"><span>Protocol</span><span id="proto">&mdash;</span></div>
    <div class="detail-row"><span>Connected For</span><span id="connTime">&mdash;</span></div>
  </div>

  <div class="card">
    <h3>System Health</h3>
    <div class="bar-row"><span>CPU</span><div class="bar"><div class="bar-fill" id="cpuBar" style="width:0%"></div></div><span id="cpuTxt">0%</span></div>
    <div class="bar-row"><span>RAM</span><div class="bar"><div class="bar-fill" id="memBar" style="width:0%"></div></div><span id="memTxt">0%</span></div>
    <div class="detail-row"><span>Temperature</span><span id="temp">&mdash;</span></div>
    <div class="detail-row"><span>Uptime</span><span id="uptime">&mdash;</span></div>
    <div class="detail-row"><span>Load Avg</span><span id="load">&mdash;</span></div>
  </div>

  <div class="card span-2" id="favBar">
    <h3>Quick Connect <span style="text-transform:none;font-weight:400;font-size:11px">tap to switch location</span></h3>
    <div id="favButtons" style="display:flex;gap:8px;flex-wrap:wrap"></div>
    <div id="favHint" style="color:var(--dim);font-size:13px;text-align:center;padding:8px">Star regions below to add them here</div>
  </div>

  <div class="card">
    <h3>Tunnel Throughput</h3>
    <div class="speed-row">
      <div class="speed-box"><div class="speed-val dl" id="dlSpd">0.0</div><div class="speed-unit">Mbps Down</div></div>
      <div class="speed-box"><div class="speed-val ul" id="ulSpd">0.0</div><div class="speed-unit">Mbps Up</div></div>
    </div>
    <canvas id="chart"></canvas>
    <div class="totals"><span>DL: <strong id="tRx">0 B</strong></span><span>UL: <strong id="tTx">0 B</strong></span></div>
  </div>

  <div class="card">
    <h3>Controls</h3>
    <div class="btn-row">
      <button class="btn btn-go" id="btnGo" onclick="doConnect()">Connect</button>
      <button class="btn btn-stop" id="btnStop" onclick="doDisconnect()">Disconnect</button>
      <button class="btn btn-rec" id="btnRec" onclick="doReconnect()">Reconnect</button>
    </div>
    <button class="btn btn-warn btn-full" onclick="doQuickReconnect()">Quick Reconnect to Last</button>
    <div class="toggle-row"><span>Auto-Reconnect</span><div class="toggle" id="autoToggle" onclick="toggleAutoconnect()"></div></div>
    <div class="toggle-row"><span>Daily Reconnect</span><div class="toggle" id="dailyToggle" onclick="toggleDaily()"></div></div>
    <div id="reconnectHourRow" style="display:none"><div class="detail-row"><span>Reconnect at</span><select id="reconnectHour" onchange="setReconnectHour()" style="background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:4px 8px;font-size:14px"></select></div></div>
  </div>

  <div class="card">
    <h3>Gaming Latency <span style="text-transform:none;font-weight:400;font-size:11px">to PSN</span></h3>
    <div class="latency-box" id="latBox"><div class="latency-val" id="latencyVal">&mdash;</div><div class="speed-unit" id="latencyTarget">ms to PSN</div></div>
    <button class="btn btn-rec btn-full" id="btnLatency" onclick="runLatency()">Test PSN Latency</button>
    <canvas id="latChart" style="display:none;margin:8px 0;width:100%;height:160px"></canvas>
    <div class="toggle-row"><span>Live Monitor</span><div class="toggle" id="latmonToggle" onclick="toggleLatmon()"></div></div>
  </div>

  <div class="card">
    <h3>Speed Test</h3>
    <div id="speedtestResult" class="result-box"><div style="color:var(--dim);font-size:14px">Not run yet</div></div>
    <button class="btn btn-go btn-full" id="btnSpeedtest" onclick="runSpeedtest()">Run Speed Test</button>
  </div>

  <div class="card">
    <h3>Kill Switch <span style="font-size:10px;color:var(--amber)">(PIN)</span></h3>
    <div id="ksResult" class="result-box"><div style="color:var(--dim);font-size:14px">Not tested</div></div>
    <button class="btn btn-warn btn-full" id="btnKillswitch" onclick="runKillswitchTest()">Test Kill Switch</button>
  </div>

  <div class="card">
    <h3>DNS Leak Test</h3>
    <div id="dnsResult" class="result-box"><div style="color:var(--dim);font-size:14px">Not tested</div></div>
    <button class="btn btn-rec btn-full" id="btnDns" onclick="runDnsLeak()">Test DNS Leak</button>
  </div>

  <div class="card span-2">
    <h3>VPN Location <span style="text-transform:none;font-weight:400;font-size:11px">&#9733; = favourite</span></h3>
    <input class="search-box" id="search" placeholder="Search locations..." oninput="filterRegions()">
    <div class="region-list" id="regionList"></div>
  </div>

  <div class="card span-2">
    <h3>Data Usage <span style="text-transform:none;font-weight:400;font-size:11px">last 7 days</span></h3>
    <canvas id="dataChart" style="height:120px;margin-bottom:8px"></canvas>
    <div id="dataLegend" style="display:flex;gap:16px;justify-content:center;font-size:12px;color:var(--dim)"></div>
  </div>

  <div class="card span-2">
    <h3>Connection History</h3>
    <div id="history" style="max-height:200px;overflow-y:auto"></div>
  </div>

  <div class="card">
    <h3>QR Code</h3>
    <div class="result-box"><img id="qrImg" style="display:none;max-width:200px;border-radius:8px" alt="QR Code"><div id="qrStatus" style="color:var(--dim);font-size:14px">Tap to generate</div></div>
    <button class="btn btn-rec btn-full" onclick="showQr()">Show QR Code</button>
  </div>

  <div class="card">
    <h3>Power Controls <span style="font-size:10px;color:var(--amber)">(PIN)</span></h3>
    <div class="btn-row">
      <button class="btn btn-warn" onclick="doReboot()">Reboot Pi</button>
      <button class="btn btn-danger" onclick="doShutdown()">Shutdown Pi</button>
    </div>
  </div>

  <div class="card span-2">
    <h3>Recent Logs</h3>
    <pre class="logs" id="logs">Loading...</pre>
  </div>

  <div class="card span-2">
    <h3>PS5 Traffic Sniffer <span id="sniffStatus" style="text-transform:none;font-weight:400;font-size:11px;color:var(--dim)"></span></h3>
    <div style="display:flex;gap:8px;margin-bottom:8px">
      <button class="btn btn-go" id="btnSniffStart" onclick="startSniff()" style="flex:1">Start Sniffing</button>
      <button class="btn btn-stop" id="btnSniffStop" onclick="stopSniff()" style="flex:1;display:none">Stop Sniffing</button>
      <button class="btn btn-warn" onclick="clearSniff()" style="flex:0 0 auto;min-width:80px">Clear</button>
    </div>
    <div style="display:flex;gap:8px;margin-bottom:8px;font-size:11px;color:var(--dim)">
      <span style="display:flex;align-items:center;gap:4px"><span style="width:8px;height:8px;border-radius:50%;background:var(--blue);display:inline-block"></span>DNS Query</span>
      <span style="display:flex;align-items:center;gap:4px"><span style="width:8px;height:8px;border-radius:50%;background:var(--amber);display:inline-block"></span>Connection</span>
    </div>
    <div id="sniffList" style="max-height:300px;overflow-y:auto;background:#010409;border:1px solid var(--border);border-radius:8px;padding:8px;font-size:11px;font-family:'SF Mono',Monaco,Consolas,monospace"></div>
  </div>

</div>
<div class="footer">PS5 VPN Dashboard</div>
<div class="toast" id="toast"></div>

<script>
const $=id=>document.getElementById(id);
async function api(p,o={}){try{return await(await fetch(p,o)).json()}catch(e){return{}}}
function toast(m){const t=$('toast');t.textContent=m;t.className='toast show';clearTimeout(t._t);t._t=setTimeout(()=>t.className='toast',3e3)}

function prettyRegion(r){if(!r)return r;const S=['a','an','and','the','of','for','in','on','at','to','de','la','el','da','do','dos','las','los'];const U=['us','uk','uae','eu','au','ca','nz','ml','de','fr','es','it','nl','se','no','fi','dk','pl','cz','ip','dc','vpn','usa','ps5'];return r.split('-').map(w=>{const l=w.toLowerCase();return U.includes(l)?l.toUpperCase():S.includes(l)?l:l.charAt(0).toUpperCase()+l.slice(1)}).join(' ')}
function prettyProto(p){if(!p)return p;p=p.toLowerCase();if(p==='wireguard')return 'WireGuard';if(p==='openvpn')return 'OpenVPN';if(p==='ikev2')return 'IKEv2';return p.charAt(0).toUpperCase()+p.slice(1)}

let _cachedPin=null;
async function promptPin(){return new Promise(res=>{const o=document.createElement('div');o.className='modal-overlay';o.innerHTML='<div class="modal-box"><h3 style="margin-bottom:16px">&#128274; Enter PIN</h3><input type="password" class="pin-input" id="pinInput" placeholder="\u2022\u2022\u2022\u2022" maxlength="10" autocomplete="off"><div class="pin-err" id="pinErr">Incorrect PIN</div><div class="modal-btns"><button id="pinCancel" style="background:var(--border);color:var(--text)">Cancel</button><button id="pinOk" style="background:var(--green);color:#fff">Unlock</button></div></div>';document.body.appendChild(o);const i=o.querySelector('#pinInput'),e=o.querySelector('#pinErr');i.focus();async function v(){const pin=i.value;const r=await api('/api/pin/check',{method:'POST',body:JSON.stringify({pin}),headers:{'Content-Type':'application/json'}});if(r.ok){_cachedPin=pin;o.remove();res(pin)}else{e.style.display='block';e.textContent=r.exists?'Incorrect PIN':'No PIN set';i.value='';i.focus()}}o.querySelector('#pinOk').onclick=v;o.querySelector('#pinCancel').onclick=()=>{o.remove();res(null)};i.onkeydown=ev=>{if(ev.key==='Enter')v();if(ev.key==='Escape'){o.remove();res(null)}}})}

let _lastState='Unknown';
async function refreshStatus(){
  const s=await api('/api/status');const on=s.state==='Connected';const wait=s.state==='Connecting'||s.state==='Reconnecting';
  $('dot').className='dot '+(on?'on':wait?'wait':'off');
  $('state').textContent=s.state;$('region').textContent=prettyRegion(s.region)||'\u2014';
  $('ip').textContent=s.pubip||'\u2014';$('proto').textContent=prettyProto(s.protocol)||'\u2014';
    if(s.ps5_ip){$('headerStatus').innerHTML=' - <span class="dot on" style="display:inline-block;vertical-align:middle;margin:0 4px"></span><span style="color:var(--green)">PS5 Connected - '+s.ps5_ip+'</span>'}
  else{$('headerStatus').innerHTML=' - <span class="dot off" style="display:inline-block;vertical-align:middle;margin:0 4px"></span><span style="color:var(--red)">PS5 NOT Connected</span>'}
  $('connTime').textContent=s.connection_time||'\u2014';
  $('tRx').textContent=s.total_rx;$('tTx').textContent=s.total_tx;
  $('btnGo').disabled=on||wait;$('btnStop').disabled=!on;$('btnRec').disabled=!on&&!wait;
  $('autoToggle').className='toggle '+(s.autoconnect?'on':'');
  $('dailyToggle').className='toggle '+(s.daily_reconnect?'on':'');
  $('reconnectHourRow').style.display=s.daily_reconnect?'block':'none';
  if(s.daily_reconnect&&!$('reconnectHour').options.length){for(let h=0;h<24;h++){$('reconnectHour').add(new Option(h+':00',h))}$('reconnectHour').value=s.reconnect_hour}
  if(_lastState==='Connected'&&s.state==='Disconnected'){notify('VPN Disconnected','Your PS5 VPN has disconnected!')}
  if(_lastState!=='Connected'&&s.state==='Connected'){notify('VPN Connected','Connected via '+prettyRegion(s.region))}
  _lastState=s.state;
}

let dlH=new Array(40).fill(0),ulH=new Array(40).fill(0);
async function refreshTput(){const t=await api('/api/throughput');if(!t.available){$('dlSpd').textContent='0.0';$('ulSpd').textContent='0.0';return}$('dlSpd').textContent=t.rx_mbps.toFixed(1);$('ulSpd').textContent=t.tx_mbps.toFixed(1);dlH.push(t.rx_mbps);dlH.shift();ulH.push(t.tx_mbps);ulH.shift();drawChart()}
function drawChart(){const c=$('chart'),x=c.getContext('2d');c.width=c.offsetWidth;c.height=c.offsetHeight;const w=c.width,h=c.height;x.clearRect(0,0,w,h);const mx=Math.max(...dlH,...ulH,10);const st=w/(dlH.length-1);x.strokeStyle='rgba(255,255,255,.04)';x.lineWidth=1;for(let i=0;i<=4;i++){const y=h/4*i;x.beginPath();x.moveTo(0,y);x.lineTo(w,y);x.stroke()}x.fillStyle='rgba(59,185,80,.12)';x.beginPath();x.moveTo(0,h);dlH.forEach((v,i)=>x.lineTo(i*st,h-(v/mx)*h));x.lineTo(w,h);x.closePath();x.fill();x.strokeStyle='#3fb950';x.lineWidth=2;x.beginPath();dlH.forEach((v,i)=>{const y=h-(v/mx)*h;i===0?x.moveTo(0,y):x.lineTo(i*st,y)});x.stroke();x.strokeStyle='#58a6ff';x.lineWidth=2;x.beginPath();ulH.forEach((v,i)=>{const y=h-(v/mx)*h;i===0?x.moveTo(0,y):x.lineTo(i*st,y)});x.stroke();x.fillStyle='rgba(255,255,255,.3)';x.font='10px sans-serif';x.fillText(mx.toFixed(0)+' Mbps',4,11)}

async function refreshSys(){const s=await api('/api/system');$('cpuBar').style.width=s.cpu+'%';$('cpuTxt').textContent=s.cpu.toFixed(1)+'%';$('cpuBar').className='bar-fill '+(s.cpu>80?'danger':s.cpu>60?'warn':'');$('memBar').style.width=s.mem_pct+'%';$('memTxt').textContent=s.mem_pct.toFixed(1)+'%';$('memBar').className='bar-fill '+(s.mem_pct>85?'danger':s.mem_pct>70?'warn':'');$('temp').textContent=s.temp.toFixed(1)+' C';$('uptime').textContent=s.uptime_str;$('load').textContent=s.load}

let allRegions=[],favRegions=[],currentRegion='';
async function refreshRegions(){const r=await api('/api/regions');allRegions=r.regions||[];favRegions=r.favorites||[];currentRegion=r.current||'';renderRegions();renderFavBar()}
function renderFavBar(){const bar=$('favButtons');const hint=$('favHint');if(!favRegions.length){bar.innerHTML='';hint.style.display='block';return}hint.style.display='none';bar.innerHTML=favRegions.map(function(reg){return '<button class="qc-btn '+(reg===currentRegion?'active':'')+'" data-qc="'+reg+'">'+prettyRegion(reg)+'</button>'}).join('');bar.querySelectorAll('[data-qc]').forEach(function(b){b.onclick=function(){qcConnect(b.getAttribute('data-qc'))}})}
async function qcConnect(reg){toast('Switching to '+prettyRegion(reg)+'...');await api('/api/region',{method:'POST',body:JSON.stringify({region:reg}),headers:{'Content-Type':'application/json'}});await api('/api/reconnect',{method:'POST'});setTimeout(refreshStatus,5e3);setTimeout(refreshRegions,5e3)}
function renderRegions(){const q=$('search').value.toLowerCase();const list=$('regionList');list.innerHTML='';const favs=allRegions.filter(r=>favRegions.includes(r));const rest=allRegions.filter(r=>!favRegions.includes(r));if(favs.length&&q===''){const hd=document.createElement('div');hd.style.cssText='padding:6px 12px;font-size:11px;color:var(--gold);text-transform:uppercase;font-weight:600';hd.textContent='Favourites';list.appendChild(hd)}favs.filter(r=>r.toLowerCase().includes(q)).forEach(r=>list.appendChild(mkRegion(r)));if(rest.length&&q===''&&favs.length){const hd=document.createElement('div');hd.style.cssText='padding:6px 12px;font-size:11px;color:var(--dim);text-transform:uppercase;font-weight:600';hd.textContent='All Locations';list.appendChild(hd)}rest.filter(r=>r.toLowerCase().includes(q)).forEach(r=>list.appendChild(mkRegion(r)))}
function mkRegion(reg){const d=document.createElement('div');d.className='region-item'+(reg===currentRegion?' active':'');const isFav=favRegions.includes(reg);d.innerHTML='<div class="region-left"><span class="star '+(isFav?'on':'')+'">&#9733;</span><span class="rname">'+(reg===currentRegion?'\u25CF ':'')+prettyRegion(reg)+'</span></div><button class="rbtn">Select</button>';d.querySelector('.rbtn').onclick=()=>setRegion(reg);d.querySelector('.star').onclick=e=>{e.stopPropagation();toggleFav(reg)};return d}
function filterRegions(){renderRegions()}
async function toggleFav(reg){await api('/api/favorite',{method:'POST',body:JSON.stringify({region:reg}),headers:{'Content-Type':'application/json'}});await refreshRegions()}
async function setRegion(reg){toast('Switching to '+prettyRegion(reg)+'...');await api('/api/region',{method:'POST',body:JSON.stringify({region:reg}),headers:{'Content-Type':'application/json'}});await api('/api/reconnect',{method:'POST'});toast('Reconnecting...');setTimeout(refreshStatus,5e3);setTimeout(refreshRegions,5e3)}
async function doConnect(){toast('Connecting...');await api('/api/connect',{method:'POST'});setTimeout(refreshStatus,3e3)}
async function doDisconnect(){toast('Disconnecting...');await api('/api/disconnect',{method:'POST'});setTimeout(refreshStatus,2e3)}
async function doReconnect(){toast('Reconnecting...');await api('/api/reconnect',{method:'POST'});setTimeout(refreshStatus,8e3)}
async function doQuickReconnect(){toast('Quick reconnecting...');const r=await api('/api/quickreconnect',{method:'POST'});toast('Reconnecting via '+(r.region?prettyRegion(r.region):'last')+'...');setTimeout(refreshStatus,8e3)}
async function toggleAutoconnect(){const cur=$('autoToggle').classList.contains('on');const r=await api('/api/autoconnect',{method:'POST',body:JSON.stringify({enabled:!cur}),headers:{'Content-Type':'application/json'}});$('autoToggle').className='toggle '+(r.enabled?'on':'');toast('Auto-reconnect '+(r.enabled?'enabled':'disabled'))}
async function toggleDaily(){const cur=$('dailyToggle').classList.contains('on');const r=await api('/api/schedule',{method:'POST',body:JSON.stringify({enabled:!cur}),headers:{'Content-Type':'application/json'}});$('dailyToggle').className='toggle '+(r.enabled?'on':'');$('reconnectHourRow').style.display=r.enabled?'block':'none';toast('Daily reconnect '+(r.enabled?'enabled':'disabled'))}
async function setReconnectHour(){const h=parseInt($('reconnectHour').value);await api('/api/schedule',{method:'POST',body:JSON.stringify({enabled:true,hour:h}),headers:{'Content-Type':'application/json'}});toast('Will reconnect at '+h+':00 daily')}

function icon(n){n=(n||'').toLowerCase();if(n.includes('ps5')||n.includes('playstation'))return'\\uD83C\\uDFAE';if(n.includes('iphone')||n.includes('phone'))return'\\uD83D\\uDCF1';if(n.includes('pc')||n.includes('desktop'))return'\\uD83D\\uDCBB';if(n.includes('tv'))return'\\uD83D\\uDCFA';return'\\uD83D\\uDD17'}
async function refreshClients(){const c=await api('/api/clients');const d=$('clients');if(!c.clients||!c.clients.length){d.innerHTML='<div style="color:var(--dim);font-size:14px;padding:4px">No devices</div>';return}d.innerHTML=c.clients.map(cl=>'<div class="client-item"><span class="client-icon">'+icon(cl.name)+'</span><div><div class="client-name">'+cl.name+'</div><div class="client-meta">'+cl.ip+' &middot; '+cl.mac+'</div></div></div>').join('')}
async function refreshLogs(){const l=await api('/api/logs');$('logs').textContent=l.logs||'No logs'}

async function refreshHistory(){const h=await api('/api/history');const d=$('history');if(!h.history||!h.history.length){d.innerHTML='<div style="color:var(--dim);font-size:14px">No history yet</div>';return}const ec={connected:['conn','Connected'],disconnected:['disc','Disconnected'],daily_reconnect:['rec','Daily Reconnect'],wol_sent:['wol','Wake-on-LAN sent']};d.innerHTML=h.history.slice(0,20).map(e=>{const [cls,label]=ec[e.event]||['conn',e.event];const dt=new Date(e.ts*1000);const ts=dt.toLocaleString('en-GB',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});return '<div class="hist-item"><span class="hist-dot '+cls+'"></span><span class="hist-time">'+ts+'</span><span class="hist-event">'+label+(e.region?' &middot; '+prettyRegion(e.region):'')+'</span></div>'}).join('')}

async function runSpeedtest(){$('btnSpeedtest').disabled=true;$('btnSpeedtest').textContent='Running...';$('speedtestResult').innerHTML='<div style="color:var(--amber)">Testing... (~30-60s)</div>';await api('/api/speedtest/start',{method:'POST'});pollSpeedtest()}
async function pollSpeedtest(){const s=await api('/api/speedtest/status');if(s.running){setTimeout(pollSpeedtest,2e3);return}$('btnSpeedtest').disabled=false;$('btnSpeedtest').textContent='Run Speed Test';if(s.error){$('speedtestResult').innerHTML='<div style="color:var(--red)">Error: '+s.error+'</div>';return}if(s.result){const r=s.result;$('speedtestResult').innerHTML='<div class="speed-row"><div class="speed-box"><div class="speed-val dl">'+r.download+'</div><div class="speed-unit">Mbps Down</div></div><div class="speed-box"><div class="speed-val ul">'+r.upload+'</div><div class="speed-unit">Mbps Up</div></div></div><div class="detail-row"><span>Ping</span><span>'+r.ping+' ms</span></div><div class="detail-row"><span>Server</span><span>'+r.server+'</span></div><div class="detail-row"><span>ISP</span><span>'+r.isp+'</span></div>'}}
async function runKillswitchTest(){const pin=await promptPin();if(!pin)return;$('btnKillswitch').disabled=true;$('btnKillswitch').textContent='Testing...';$('ksResult').innerHTML='<div style="color:var(--amber)">Disconnecting VPN...</div>';await api('/api/killswitch-test',{method:'POST',body:JSON.stringify({pin}),headers:{'Content-Type':'application/json'}});pollKillswitch()}
async function pollKillswitch(){const s=await api('/api/killswitch-status');if(s.running){setTimeout(pollKillswitch,2e3);return}$('btnKillswitch').disabled=false;$('btnKillswitch').textContent='Test Kill Switch';if(s.error){$('ksResult').innerHTML='<div style="color:var(--red)">Error: '+s.error+'</div>';return}if(s.result){const col=s.result.passed?'var(--green)':'var(--red)';$('ksResult').innerHTML='<div style="color:'+col+';font-size:14px;font-weight:600">'+s.result.message+'</div>'}}

async function runDnsLeak(){$('btnDns').disabled=true;$('btnDns').textContent='Testing...';$('dnsResult').innerHTML='<div style="color:var(--amber)">Checking DNS...</div>';await api('/api/dnsleak/start',{method:'POST'});pollDns()}
async function pollDns(){const s=await api('/api/dnsleak/status');if(s.running){setTimeout(pollDns,2e3);return}$('btnDns').disabled=false;$('btnDns').textContent='Test DNS Leak';if(s.error){$('dnsResult').innerHTML='<div style="color:var(--red)">Error: '+s.error+'</div>';return}if(s.result){const col=s.result.status==='pass'?'var(--green)':s.result.status==='warn'?'var(--amber)':'var(--red)';$('dnsResult').innerHTML='<div style="color:'+col+';font-size:14px;font-weight:600;margin-bottom:8px">'+s.result.message+'</div><div class="detail-row"><span>DNS Server</span><span>'+s.result.dns_server+'</span></div><div class="detail-row"><span>PIA DNS</span><span>'+(s.result.pia_reachable?'Reachable':'Not reachable')+'</span></div><div class="detail-row"><span>dnsmasq</span><span>'+(s.result.uses_pia?'Forwards to PIA':'Custom config')+'</span></div>'}}

async function runLatency(){$('btnLatency').disabled=true;$('btnLatency').textContent='Pinging...';$('latencyVal').textContent='...';await api('/api/latency',{method:'POST'});pollLatency()}
async function pollLatency(){const s=await api('/api/latency/status');if(s.running){setTimeout(pollLatency,2e3);return}$('btnLatency').disabled=false;$('btnLatency').textContent='Test PSN Latency';if(s.error){$('latencyVal').textContent='ERR';$('latencyTarget').textContent=s.error;return}if(s.result){$('latencyVal').textContent=s.result.latency_ms;$('latencyTarget').textContent='ms to '+s.result.target+(s.result.packet_loss?' ('+s.result.packet_loss+'% loss)':'')}}

let _latmonOn=false;
async function toggleLatmon(){_latmonOn=!_latmonOn;$('latmonToggle').className='toggle '+(_latmonOn?'on':'');$('latChart').style.display=_latmonOn?'block':'none';$('latBox').style.display=_latmonOn?'none':'block';$('btnLatency').style.display=_latmonOn?'none':'block';if(_latmonOn){await api('/api/latmon/start',{method:'POST'});pollLatmon()}else{await api('/api/latmon/stop',{method:'POST'})}}
async function pollLatmon(){const s=await api('/api/latmon/status');if(_latmonOn&&s.running){drawLatChart(s.values||[]);setTimeout(pollLatmon,3e3)}}
function drawLatChart(vals){const c=$('latChart'),x=c.getContext('2d');c.width=c.offsetWidth;c.height=160;const w=c.width,h=c.height;x.clearRect(0,0,w,h);const ms=vals.filter(v=>v.ms).map(v=>v.ms);if(!ms.length){x.fillStyle='var(--dim)';x.font='14px sans-serif';x.fillText('Collecting data...',w/2-50,h/2);return}const mx=Math.max(...ms,50)*1.2;const st=w/Math.max(vals.length-1,1);x.strokeStyle='rgba(255,255,255,.04)';x.lineWidth=1;for(let i=0;i<=4;i++){const y=h/4*i;x.beginPath();x.moveTo(0,y);x.lineTo(w,y);x.stroke()}x.fillStyle='rgba(255,255,255,.2)';x.font='11px sans-serif';for(let i=0;i<=4;i++){const v=mx-(mx/4)*i;x.fillText(Math.round(v)+'ms',4,h/4*i+12)}x.fillStyle='rgba(88,166,255,.1)';x.beginPath();x.moveTo(0,h);vals.forEach(function(v,i){if(!v.ms)return;x.lineTo(i*st,h-(v.ms/mx)*h)});x.lineTo(w,h);x.closePath();x.fill();x.strokeStyle='#58a6ff';x.lineWidth=2;x.beginPath();vals.forEach(function(v,i){if(!v.ms)return;const y=h-(v.ms/mx)*h;i===0?x.moveTo(0,y):x.lineTo(i*st,y)});x.stroke();const last=ms[ms.length-1];x.fillStyle='#58a6ff';x.font='bold 12px sans-serif';x.fillText('now: '+last.toFixed(0)+'ms',w-80,16);x.fillStyle='rgba(255,255,255,.4)';x.fillText(mx.toFixed(0)+'ms max',w-90,h-4)}

async function refreshDataStats(){const s=await api('/api/datastats');drawDataChart(s.days||[])}
function drawDataChart(days){const c=$('dataChart'),x=c.getContext('2d');c.width=c.offsetWidth;c.height=120;const w=c.width,h=c.height;x.clearRect(0,0,w,h);if(!days.length){x.fillStyle='var(--dim)';x.font='12px sans-serif';x.fillText('No data yet - stats accumulate over time',w/2-90,h/2);return}const allB=days.map(d=>(d.rx||0)+(d.tx||0));const mx=Math.max(...allB,1);const bw=w/days.length*0.6;const gap=w/days.length;x.fillStyle='#3fb950';days.forEach((d,i)=>{const bh=(d.rx||0)/mx*h;x.fillRect(i*gap+gap*0.15,h-bh,bw,bh)});x.fillStyle='#58a6ff';days.forEach((d,i)=>{const bh=(d.tx||0)/mx*h;x.fillRect(i*gap+gap*0.15+bw,h-bh,bw*0.4,bh)});x.fillStyle='var(--dim)';x.font='10px sans-serif';days.forEach((d,i)=>{const dt=new Date(d.date);const lbl=dt.toLocaleDateString('en-GB',{weekday:'short'});x.fillText(lbl,i*gap+gap*0.3,h+14)});const tRx=days.reduce((s,d)=>s+(d.rx||0),0);const tTx=days.reduce((s,d)=>s+(d.tx||0),0);$('dataLegend').innerHTML='<span>&#9650; DL: <strong style="color:var(--green)">'+fmtData(tRx)+'</strong></span><span>&#9650; UL: <strong style="color:var(--blue)">'+fmtData(tTx)+'</strong></span>'}
function fmtData(b){for(const u of ['B','KB','MB','GB','TB']){if(b<1024)return b.toFixed(1)+' '+u;b/=1024}return b.toFixed(1)+' PB'}

async function showQr(){try{const r=await fetch('/api/qr');if(!r.ok){const e=await r.json();$('qrStatus').textContent=e.error||'Failed';return}const svg=await r.text();$('qrImg').src='data:image/svg+xml;base64,'+btoa(svg);$('qrImg').style.display='block';$('qrStatus').textContent='Scan to open on another device'}catch(e){$('qrStatus').textContent='Error generating QR'}}

let _sniffOn=false;
async function startSniff(){_sniffOn=true;$('btnSniffStart').style.display='none';$('btnSniffStop').style.display='block';$('sniffStatus').textContent='(running)';$('sniffStatus').style.color='var(--green)';await api('/api/sniffer/start',{method:'POST'});pollSniff()}
async function stopSniff(){_sniffOn=false;$('btnSniffStart').style.display='block';$('btnSniffStop').style.display='none';$('sniffStatus').textContent='(stopped)';$('sniffStatus').style.color='var(--dim)';await api('/api/sniffer/stop',{method:'POST'})}
async function clearSniff(){await api('/api/sniffer/clear',{method:'POST'});$('sniffList').innerHTML=''}
async function pollSniff(){if(!_sniffOn)return;const s=await api('/api/sniffer/status');const d=$('sniffList');if(s.error&&!d.innerHTML){d.innerHTML='<div style="color:var(--red);padding:8px">Error: '+s.error+'</div><div style="color:var(--dim);padding:4px 8px">Install tcpdump: sudo apt install -y tcpdump</div>'}if(s.packets&&s.packets.length){d.innerHTML=s.packets.slice().reverse().map(function(p){var dt=new Date(p.ts*1000);var tm=dt.toLocaleTimeString('en-GB',{hour:'2-digit',minute:'2-digit',second:'2-digit'});var icon=p.type==='dns'?'<span class="sniff-dot dns"></span>':'<span class="sniff-dot conn"></span>';var lbl=p.type==='dns'?'DNS':'TCP';return '<div class="sniff-item">'+icon+'<span class="sniff-time">'+tm+'</span><span class="sniff-detail"><span style="color:var(--dim)">['+lbl+']</span> '+p.detail+'</span></div>'}).join('');var scroll=d.scrollHeight-d.scrollTop-d.clientHeight<50;if(scroll){d.scrollTop=d.scrollHeight}}if(_sniffOn&&s.running){setTimeout(pollSniff,2e3)}}

async function doReboot(){const pin=await promptPin();if(!pin)return;if(confirm('Reboot the Pi now?')){toast('Rebooting...');await api('/api/reboot',{method:'POST',body:JSON.stringify({pin}),headers:{'Content-Type':'application/json'}})}}
async function doShutdown(){const pin=await promptPin();if(!pin)return;if(confirm('Shut down the Pi now?')){toast('Shutting down...');await api('/api/shutdown',{method:'POST',body:JSON.stringify({pin}),headers:{'Content-Type':'application/json'}})}}

function notify(t,b){if(!('Notification'in window))return;if(Notification.permission==='granted'){try{navigator.serviceWorker&&navigator.serviceWorker.ready.then(r=>r.showNotification(t,{body:b,icon:'/icon/192.png'}))}catch(e){try{new Notification(t,{body:b})}catch(_){}}}}
if('Notification'in window&&Notification.permission==='default'){document.addEventListener('click',()=>Notification.requestPermission(),{once:true})}
if('serviceWorker'in navigator){navigator.serviceWorker.register('/sw.js').catch(()=>{})}

function safe(fn, name){return async()=>{try{await fn()}catch(e){console.error('Dashboard error in '+name+':',e)}}}
safe(refreshStatus,'status')();safe(refreshRegions,'regions')();safe(refreshSys,'sys')();safe(refreshLogs,'logs')();safe(refreshHistory,'history')();safe(refreshDataStats,'datastats')();safe(pollSpeedtest,'speedtest')();safe(pollKillswitch,'killswitch')();safe(pollLatency,'latency')();safe(pollDns,'dns')();
setInterval(()=>safe(refreshStatus,'status')(),3e3);setInterval(()=>safe(refreshTput,'tput')(),1e3);setInterval(()=>safe(refreshSys,'sys')(),5e3);setInterval(()=>safe(refreshLogs,'logs')(),3e4);setInterval(()=>safe(refreshHistory,'history')(),15e3);setInterval(()=>safe(refreshDataStats,'datastats')(),3e4);
</script>
</body>
</html>'''

# Start background threads
_load_state()
_load_data_stats()
if _state.get('autoconnect') and not (_watchdog['thread'] and _watchdog['thread'].is_alive()):
    _watchdog['enabled'] = True
    _watchdog['thread'] = threading.Thread(target=_watchdog_loop, daemon=True)
    _watchdog['thread'].start()
threading.Thread(target=_monitor_vpn, daemon=True).start()
threading.Thread(target=_daily_reconnect_loop, daemon=True).start()
threading.Thread(target=_data_stats_loop, daemon=True).start()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, threaded=True)
