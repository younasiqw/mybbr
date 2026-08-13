#!/usr/bin/env bash
# TCPFit-Lite: 高阶单机 TCP 调优与出向流量整形系统 (Proxy 专用)
# 核心：BBR + FQ Pacing + 动态 BDP + ISP Policer 嗅探 + 全球公益节点库

set -uo pipefail

VERSION="2.0.0-UI"
STATE_DIR="/var/lib/tcpfit-lite"
SYSCTL_FILE="/etc/sysctl.d/99-tcpfit-lite.conf"
IPERF_PIDS_FILE="/tmp/tcpfit_iperf_pids"
DEFAULT_RTT=150

# --- 完美整合的全球公益 iperf3 测速池 ---
# 格式: HOST|LOCATION|PROVIDER|PORT_RANGE
PEER_POOL="
160.242.19.254|AO-Luanda|Paratus|9205-9240
41.110.39.130|DZ-Algiers|DATAPACKET|5201
213.158.175.240|EG-Cairo|DATAPACKET|5201
102.214.66.39|GH-Accra|DATAPACKET|5201
102.214.66.19|GH-Accra|DATAPACKET|5201
212.60.92.134|GM-Banjul|Pura|60001-60003
105.235.237.2|GQ-Bata|Guineanet|5201-5209
gw1.malabo.guineanet.net|GQ-Bata|Guine@net|5201-5209
speed.mymanga.pro|KE-Nairobi|Mymanga|9202-9240
speedtestfl.telecom.mu|MU-Floreal|Mauritius Telecom|5201-5209
197.227.12.18|MU-Floreal|Mauritius Telecom|5201-5209
41.226.22.119|TN-Tunis|Topnet|9201-9240
41.210.185.162|UG-Kampala|DATAPACKET|5201
69.48.239.124|ZA-Johannesburg|FortiSASE|30003-30009
23.249.55.42|AE-Dubai|FortiSASE|30001-30009
69.48.238.200|AE-Dubai|FortiSASE|30001-30009
speedtest.hkg12.hk.leaseweb.net|HK-Hong Kong|LeaseWeb|5201-5210
84.17.57.129|HK-Hong Kong|DATAPACKET|5201
23.249.58.14|HK-Hong Kong|FortiSASE|30000-30009
iperf.scbd.net.id|ID-Curug|Arthatel|5201-5209
speedtest.tangerang2.myrepublic.net.id|ID-Kediri|MyRepublic|9200-9240
speed.netfiber.net.il|IL-Jerusalem|Netfiber|5201
speed.rimon.net.il|IL-Jerusalem|Rimon|5201
169.150.202.193|IL-Tel Aviv|DATAPACKET|5201
23.249.61.122|IN-Bangalore|FortiSASE|30001-30009
49.205.75.2|IN-Bengaluru|ACT Fibernet|5008-5020
69.48.236.198|IN-Pune|FortiSASE|30001-30009
23.249.60.154|JP-Komagome|FortiSASE|30001-30009
speedtest.tyo11.jp.leaseweb.net|JP-Tokyo|LeaseWeb|5201-5210
89.187.160.1|JP-Tokyo|DATAPACKET|5201
66.35.31.81|JP-Tokyo|FortiSASE|30001-30009
coverage1.mobicom.mn|MN-Ulaanbaatar|Mobicom|5201-5202
speedtest.sin1.sg.leaseweb.net|SG-Singapore|LeaseWeb|5201-5210
89.187.162.1|SG-Singapore|DATAPACKET|5201
sgp.proof.ovh.net|SG-Singapore|OVH|5201-5210
96.45.38.22|SG-Singapore|FortiSASE|30001-30009
iperf.pendc.com|TR-Bursa|PENDC|5201-5209
156.146.52.1|TR-Istanbul|DATAPACKET|5201
69.48.237.66|TR-Istanbul|FortiSASE|30001-30009
speedtest.uztelecom.uz|UZ-Tashkent|UZ Telecom|5200-5209
185.180.12.40|AT-Vienna|DATAPACKET|5201
iperf3-vie-at.alwyzon.net|AT-Vienna|Alwyzon|5201-5210
207.211.214.65|BE-Brussels|DATAPACKET|5201
185.3.160.57|BE-Liège|VOO|5201-5240
37.19.203.1|BG-Sofia|DATAPACKET|5201
speedtest.shinternet.ch|CH-Schaffhausen|Sasag|5200-5209
speedtest.init7.net|CH-Winterthur|Init7|5201-5204
speedtest.iway.ch|CH-Zürich|iWay|5201
89.187.165.1|CH-Zürich|DATAPACKET|5201
t5.cscs.ch|CH-Zürich|CSCS|5201-5203
185.152.65.113|CZ-Prague|DATAPACKET|5201
a209.speedtest.wobcom.de|DE-Berlin|WOBCOM|5201
a110.speedtest.wobcom.de|DE-Berlin|WOBCOM|5201
a208.speedtest.wobcom.de|DE-Düsseldorf|WOBCOM|5201
178.215.228.109|DE-Frankfurt|ESEVEN|9203-9240
fra.speedtest.clouvider.net|DE-Frankfurt|Clouvider|5200-5209
speedtest.ip-projects.de|DE-Frankfurt|IP Projects|5201
speedtest.fra1.de.leaseweb.net|DE-Frankfurt|LeaseWeb|5201-5210
spd-desrv.hostkey.com|DE-Frankfurt|HOSTKEY|5201-5209
a210.speedtest.wobcom.de|DE-Frankfurt|WOBCOM|5201
a205.speedtest.wobcom.de|DE-Frankfurt|WOBCOM|5201
185.102.219.93|DE-Frankfurt|DATAPACKET|5201
96.45.39.38|DE-Frankfurt|FortiSASE|30001-30009
speedtest.level66.services|DE-Frankfurt|level66.network|5201-5205
speedtest.wtnet.de|DE-Norderstedt|wilhelm.tel|5200-5209
speedtest.wobcom.de|DE-Wolfsburg|WOBCOM|5201
a400.speedtest.wobcom.de|DE-Wolfsburg|WOBCOM|5201
speedtest.hiper.dk|DK-Copenhagen|Hiper|5201-5205
speed1.fiberby.dk|DK-Copenhagen|Fiberby|9201-9240
speed2.fiberby.dk|DK-Copenhagen|Fiberby|9201-9240
bwtest.linxtelecom.com|EE-Tallinn|CITIC|5201-5209
185.93.3.50|ES-Madrid|DATAPACKET|5201
148.230.45.213|ES-Madrid|FortiSASE|30001-30009
spd-fisrv.hostkey.com|FI-Helsinki|HOSTKEY|5201-5209
speedtest.milkywan.fr|FR-Croissy-Beaubourg|MilkyWan|9200-9240
138.199.14.66|FR-Marseille|DATAPACKET|5201
185.93.2.193|FR-Paris|DATAPACKET|5201
iperf3.moji.fr|FR-Paris|moji|5200-5240
ping-90ms.online.net|FR-Paris|Scaleway|5200-5209
iperf.online.net|FR-Paris|Scaleway|5200-5209
96.45.42.156|FR-Paris|FortiSASE|30001-30009
96.45.41.167|FR-Valbonne|FortiSASE|30001-30009
ping.online.net|FR-Vitry-sur-Seine|Scaleway|5200-5209
speedtestb.quickline.co.uk|GB-Doncaster|QUICKLINE|5201-5250
iperf.as42831.net|GB-London|UK Servers|5300-5400
speedtest.lon1.uk.leaseweb.net|GB-London|LeaseWeb|5202-5210
speedtest.lon12.uk.leaseweb.net|GB-London|LeaseWeb|5201-5210
lon.speedtest.clouvider.net|GB-London|Cloudvider|5200-5208
185.59.221.51|GB-London|DATAPACKET|5201
speedtest2.lightningfibre.net.uk|GB-London|Lightning Fibre|4000-4007
96.45.40.45|GB-London|FortiSASE|30001-30009
speedtest.rapidswitch.com|GB-Maidenhead|RapidSwitch|5201-5209
man.speedtest.clouvider.net|GB-Manchester|Clouvider|5200-5209
169.150.252.2|GR-Athens|DATAPACKET|5201
169.150.242.129|HR-Zagreb|DATAPACKET|5201
87.249.137.8|IE-Dublin|DATAPACKET|5201
spd-icsrv.hostkey.com|IS-Reykjavik|HOSTKEY|5201-5209
it1.speedtest.aruba.it|IT-Arezzo|Aruba.it|5201
84.17.59.129|IT-Milan|DATAPACKET|5201
217.61.40.96|IT-Ponte San Pietro|Aruba.it|5201
speed-cb.dimensione.com|IT-Rome|Dimensione|5201-5209
speedtestlondon.telecom.mu|MU-London|Mauritius Telecom|5201-5209
speedtest.ams1.nl.leaseweb.net|NL-Amsterdam|LeaseWeb|5201-5210
speedtest.ams2.nl.leaseweb.net|NL-Amsterdam|LeaseWeb|5201-5210
ams.speedtest.clouvider.net|NL-Amsterdam|Clouvider|5200-5209
ping-ams1.online.net|NL-Amsterdam|Scaleway|5201-5209
a204.speedtest.wobcom.de|NL-Amsterdam|WOBCOM|5201
185.102.218.1|NL-Amsterdam|DATAPACKET|5201
iperf-ams-nl.eranium.net|NL-Amsterdam|Eranium|5201-5210
speedtest.netone.nl|NL-Amsterdam|NetOne|5201
lg.ams-nl.gigahost.no|NL-Amsterdam|Gigahost|9201-9240
speedtest.nl1.mirhosting.net|NL-Dronten|Mirhosting|5201-5210
nl.speed.vps1.net|NL-Dronten|vps1|5201-5210
iperf1.surfwireless.nl|NL-Lelystad|SURFnet|5201-5220
iperf.worldstream.nl|NL-Naaldwijk|Worldstream|5201-5205
lg.gigahost.no|NO-Sandefjord|Gigahost|9201-9240
speedsrv.multinet24.pl|PL-Debica|Multinet24|5301-5310
185.246.208.67|PL-Warsaw|DATAPACKET|5201
109.61.94.65|PT-Lisbon|DATAPACKET|5201
lisboa.speedtest.net.zon.pt|PT-Lisbon|NOS|5201-5209
porto.speedtest.net.zon.pt|PT-Porto|NOS|5201-5209
185.102.217.170|RO-Bucharest|DATAPACKET|5201
speedtest1.sox.rs|RS-Belgrade|SOX|9202-9240
iperf.fegis.nu|SE-Alvsjo|Hostup|5201-5207
speedtest.kamel.network|SE-Kista|Kamel Networks|5201-5205
185.76.9.135|SE-Stockholm|DATAPACKET|5201
156.146.40.65|SK-Bratislava|DATAPACKET|5201
37.19.218.65|UA-Kyiv|DATAPACKET|5201
speed.cosmonova.net|UA-Kyiv|Cosmonova|5201-5209
148.230.60.200|BR-Sao Paulo|FortiSASE|30001-30009
138.199.4.1|BR-São Paulo|DATAPACKET|5201
79.127.209.1|CL-Santiago|DATAPACKET|5201
156.146.53.53|CR-San Jose|DATAPACKET|5201
speedtest.masnet.ec|EC-Santa Ana|MásNet|5201-5209
speedtest1.flowjamaica.com|JM-Portmore|Flow|5506-5520
121.127.43.65|MX-Querétaro|DATAPACKET|5201
speedtest1.cwpanama.net|PA-Colón|CW Panama|5505-5509
speedtest6.cwpanama.net|PA-Panamá|CW Panama|5505-5509
speedtest.mtl2.ca.leaseweb.net|CA-Montreal|LeaseWeb|5201-5210
speedtest.goco.ca|CA-Montreal|TELUS|9203-9240
173.243.131.29|CA-Ottawa|FortiSASE|30001-30009
138.199.57.129|CA-Toronto|DATAPACKET|5201
96.45.43.6|CA-Toronto|FortiSASE|30001-30009
66.35.30.9|CA-Vancouver|FortiSASE|30001-30009
speed.couch.ca|CA-Victoria|couch.ca|15201-15210
yyc-speedtest.xplore.ca|CA-Woodstock|Xplore|8070-8099
ash.speedtest.clouvider.net|US-Ashburn|Clouvider|5200-5209
37.19.206.20|US-Ashburn|DATAPACKET|5201
66.35.22.79|US-Ashburn|FortiSASE|30001-30009
atl.speedtest.clouvider.net|US-Atlanta|Clouvider|5200-5209
185.152.66.67|US-Atlanta|DATAPACKET|5201
109.61.86.65|US-Boston|DATAPACKET|5201
speedtest.chi11.us.leaseweb.net|US-Chicago|LeaseWeb|5201-5210
185.93.1.65|US-Chicago|DATAPACKET|5201
chi.speedtest.clouvider.net|US-Chicago|Clouvider|5200-5209
speedtest.dal13.us.leaseweb.net|US-Dallas|LeaseWeb|5201-5210
dal.speedtest.clouvider.net|US-Dallas|Clouvider|5200-5209
89.187.164.1|US-Dallas|DATAPACKET|5201
dfw.speedtest.is.cc|US-Dallas|InterServer.net|5203-5210
66.35.27.207|US-Dallas|FortiSASE|30001-30009
37.19.216.1|US-Houston|DATAPACKET|5201
speedtest.nocix.net|US-Kansas City|NOCIX|5201-5205
la.speedtest.clouvider.net|US-Los Angeles|Clouvider|5200-5209
speedtest.lax12.us.leaseweb.net|US-Los Angeles|LeaseWeb|5201-5210
185.152.67.2|US-Los Angeles|DATAPACKET|5201
speedtest.mia11.us.leaseweb.net|US-Miami|LeaseWeb|5201-5210
195.181.162.195|US-Miami|DATAPACKET|5201
23.249.54.234|US-Miami|FortiSASE|30002-30009
spd-uswb.hostkey.com|US-New York|HOSTKEY|5201-5209
185.59.223.8|US-New York|DATAPACKET|5201
speedtest.nyc1.us.leaseweb.net|US-New York City|LeaseWeb|5201-5210
speedtest.phx1.us.leaseweb.net|US-Phoenix|LeaseWeb|5201-5210
phx.speedtest.clouvider.net|US-Phoenix|Clouvider|5200-5209
209.40.123.215|US-Plano|FortiSASE|30001-30009
speedtest.xmission.com|US-Salt Lake|XMISSION|5201-5209
speedtest.sfo12.us.leaseweb.net|US-San Francisco|LeaseWeb|5201-5210
66.35.20.123|US-San Jose|FortiSASE|30001-30009
148.230.59.38|US-San Jose|FortiSASE|30001-30009
speedtest.sea11.us.leaseweb.net|US-Seattle|LeaseWeb|5201-5210
84.17.41.11|US-Seattle|DATAPACKET|5201
speedtest.wdc2.us.leaseweb.net|US-Washington|LeaseWeb|5201-5210
speedtest.syd12.au.leaseweb.net|AU-Sydney|LeaseWeb|5201-5210
143.244.63.144|AU-Sydney|DATAPACKET|5201
syd.proof.ovh.net|AU-Sydney|OVH|5201-5210
96.45.44.87|AU-Sydney|FortiSASE|30001-30009
speedtest.lagoon.nc|NC-Noumea|Lagoon|5202-5210
akl.linetest.nz|NZ-Auckland|2Degrees|5301-5309
chch.linetest.nz|NZ-Christchurch|2Degrees|5301-5309
154.81.51.4|PG-Port Moresby|DATAPACKET|5201
103.146.200.98|PG-Port Moresby|DATAPACKET|5201
"

# --- UI 与基础函数 ---
green=$'\033[0;32m'; red=$'\033[0;31m'; yellow=$'\033[0;33m'; cyan=$'\033[0;36m'; plain=$'\033[0m'
info() { echo -e "${cyan}[*]${plain} $1"; }
ok() { echo -e "${green}[+]${plain} $1"; }
warn() { echo -e "${yellow}[!]${plain} $1" >&2; }
die() { echo -e "${red}[x]${plain} $1" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "需要 root 权限"; }
mkdir -p "$STATE_DIR"

# 精准 PID 管理
record_pid() { echo "$1" >> "$IPERF_PIDS_FILE"; }
reap_iperf() {
    if [ -f "$IPERF_PIDS_FILE" ]; then
        xargs -r kill -9 < "$IPERF_PIDS_FILE" 2>/dev/null || true
        rm -f "$IPERF_PIDS_FILE"
    fi
    pkill -x iperf3 2>/dev/null || true
    # 清理可能残留的并发 ping
    pkill -x ping 2>/dev/null || true
}

trap 'echo; warn "操作被中断，正在清理进程和恢复网卡..."; clear_qdisc "$(detect_iface)"; reap_iperf; exit 130' INT TERM

# --- 环境检测 ---
detect_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || \
    ip -6 route show default 2>/dev/null | awk '{print $5; exit}'
}

detect_ram_mb() { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }

# --- 数学计算 (动态 BDP 与 TCP 内存) ---
calc_bdp() { awk -v b="$1" -v r="$2" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}'; }

calc_tcp_mem() {
    awk -v m="$1" 'BEGIN{
        pg=m*1024/4; low=int(pg/16); pres=int(pg/8); max=int(pg/4)
        if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384
        printf "%d %d %d", low, pres, max
    }'
}

calc_buf_max() {
    awk -v b="$1" -v m="$2" 'BEGIN{
        v=b*2; cap=m*32768
        if(cap>268435456) cap=268435456
        if(v>cap) v=cap
        if(v<4194304) v=4194304
        printf "%d", v
    }'
}

# --- 流量整形 (TC HTB+FQ) ---
set_qdisc() {
    local iface="$1" rate="$2"
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root handle 1: htb default 10
    tc class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" burst 32k cburst 32k quantum 1514
    tc qdisc add dev "$iface" parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate "${rate}mbit"
}

clear_qdisc() {
    local iface="$1"
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root fq 2>/dev/null || true
}

# --- 核心网络调优 (Sysctl + Initcwnd) ---
apply_sysctl() {
    local bw="$1" role="$2"
    local iface=$(detect_iface)
    local ram=$(detect_ram_mb)
    local bdp=$(calc_bdp "$bw" "$DEFAULT_RTT")
    local buf_max=$(calc_buf_max "$bdp" "$ram")
    local tcp_mem=$(calc_tcp_mem "$ram")
    
    local buf_def=$([ "$role" = "proxy" ] && echo 1048576 || echo 4194304)

    info "基于参数推导: 带宽 ${bw}Mbps / 延迟 ${DEFAULT_RTT}ms / 内存 ${ram}MB"
    
    modprobe tcp_bbr 2>/dev/null || true

    cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.core.rmem_default = $buf_def
net.core.wmem_default = $buf_def
net.ipv4.tcp_rmem = 4096 $buf_def $buf_max
net.ipv4.tcp_wmem = 4096 $buf_def $buf_max
net.ipv4.tcp_mem = $tcp_mem

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF
    sysctl -qp "$SYSCTL_FILE" >/dev/null 2>&1
    ok "Sysctl BBR 及 TCP 缓冲区参数应用完成"

    local gw4=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    local gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}')
    [ -n "$gw4" ] && ip -4 route change default via "$gw4" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
    [ -n "$gw6" ] && ip -6 route change default via "$gw6" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
    ok "出站路由 initcwnd/initrwnd 已提速至 32 (IPv4/IPv6)"
}

# --- 测速对端自动选择 (支持 100+ 节点自动并发测速) ---
auto_pick_peer() {
    command -v ping >/dev/null || die "缺少 ping，无法自动选点。请安装 iputils-ping"
    info "正在并发 Ping 测试全球 117 个公益 iperf3 节点寻找最优链路..."
    
    local tmpf=$(mktemp)
    
    while IFS='|' read -r host loc prov port_str; do
        [ -z "$host" ] && continue
        (
            # 发送两个包，提取 RTT
            rtt=$(ping -c 2 -q -W 2 "$host" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
            if [ -n "$rtt" ]; then
                # 提取端口范围中的首个端口，比如将 9205-9240 提取为 9205
                local target_port=$(echo "$port_str" | awk -F'-' '{print $1}')
                echo "$rtt|$host|$loc|$prov|$target_port" >> "$tmpf"
            fi
        ) &
    done <<< "$PEER_POOL"
    wait
    
    local best=$(sort -n -t '|' -k 1 "$tmpf" | head -n 1)
    rm -f "$tmpf"
    
    if [ -n "$best" ]; then
        local rtt=$(echo "$best" | cut -d'|' -f1)
        local host=$(echo "$best" | cut -d'|' -f2)
        local loc=$(echo "$best" | cut -d'|' -f3)
        local prov=$(echo "$best" | cut -d'|' -f4)
        local port=$(echo "$best" | cut -d'|' -f5)
        
        ok "自动选中延迟最低节点: $host ($loc / $prov)"
        ok "测速端口: $port | 延迟: ${rtt}ms"
        echo "${host}:${port}"
    else
        echo ""
    fi
}

# --- Iperf3 测试引擎 ---
run_iperf() {
    local peer="$1" port="$2" time="$3" threads="$4"
    local logf=$(mktemp)
    timeout 25 iperf3 -c "$peer" -p "$port" -t "$time" -P "$threads" -f m > "$logf" 2>&1 &
    local pid=$!
    record_pid "$pid"
    wait "$pid"
    
    local grep_str=$([ "$threads" -gt 1 ] && echo 'SUM.*sender' || echo 'sender')
    local out=$(grep -E "$grep_str" "$logf" | tail -1)
    rm -f "$logf"
    
    if [ -n "$out" ]; then
        local bitrate=$(echo "$out" | awk '{print $(NF-3)}')
        local retrans=$(echo "$out" | awk '{print $(NF-1)}')
        echo "$bitrate $retrans"
    fi
}

loss_pct() {
    awk -v r="$1" -v b="$2" -v t="$3" 'BEGIN{
        pk = b*1000000*t/8/1448
        if(pk<1) pk=1
        printf "%.4f", r*100/pk
    }'
}

# --- 限速器扫描 (Policer Sweep) ---
sweep_policer() {
    local peer_full="$1" bw="$2" iface="$3"
    
    local peer="${peer_full%:*}"
    local port="${peer_full##*:}"
    [ "$peer" = "$port" ] && port=5201 # 默认兜底端口
    
    info "开始扫描 ISP 限速拐点 (目标: $peer:$port, 基准带宽: ${bw}Mbps)..."
    
    clear_qdisc "$iface"
    local res=$(run_iperf "$peer" "$port" 10 1)
    [ -z "$res" ] && { warn "对端无响应或被占用。"; return 1; }
    
    local ug=$(echo "$res" | awk '{print $1}')
    local urt=$(echo "$res" | awk '{print $2}')
    local ulp=$(loss_pct "$urt" "$ug" 10)
    
    echo -e "  [裸测] 吞吐: ${ug}Mbps, 重传: ${urt}, 丢包率: ${ulp}%"
    
    if awk -v l="$ulp" 'BEGIN{exit !(l < 0.1)}'; then
        ok "裸测无明显丢包 (低于 0.1%)，未撞击 ISP 限速墙，无需施加降速整形。"
        return 0
    fi
    
    warn "发现丢包率偏高，存在 ISP Policer 惩罚。开始精细扫描..."
    
    local lo=$(awk -v g="$ug" 'BEGIN{v=int(g*0.85); if(v<1)v=1; print v}')
    local hi=$(awk -v g="$ug" 'BEGIN{print int(g*1.2)}')
    local step=$(awk -v l="$lo" -v h="$hi" 'BEGIN{s=int((h-l)/8); if(s<5)s=5; print s}')
    
    local last_ok=""
    local broke_at=""
    
    for r in $(seq "$lo" "$step" "$hi"); do
        set_qdisc "$iface" "$r"
        local s_res=$(run_iperf "$peer" "$port" 8 1)
        [ -z "$s_res" ] && continue
        
        local sg=$(echo "$s_res" | awk '{print $1}')
        local srt=$(echo "$s_res" | awk '{print $2}')
        local slp=$(loss_pct "$srt" "$sg" 8)
        
        if awk -v l="$slp" 'BEGIN{exit !(l > 0.1)}'; then
            echo -e "  [限速 ${r}Mbit] 吞吐: ${sg}Mbps, 重传: ${srt}, 丢包率: ${red}${slp}% (触达红线)${plain}"
            broke_at=$r
            break
        else
            echo -e "  [限速 ${r}Mbit] 吞吐: ${sg}Mbps, 重传: ${srt}, 丢包率: ${green}${slp}% (干净)${plain}"
            last_ok=$r
        fi
        sleep 2
    done
    
    clear_qdisc "$iface"
    
    if [ -n "$last_ok" ]; then
        local final_rate=$(awk -v k="$last_ok" 'BEGIN{print int(k*0.95)}')
        ok "探测到干净上限为 ${last_ok}Mbit，建议整形值：${final_rate}Mbit"
        set_qdisc "$iface" "$final_rate"
        ok "已应用 HTB 出向整形 (速率: ${final_rate}Mbit)，代理将彻底告别断流！"
    else
        warn "未能在扫描区间找到绝对干净的速率点。将保留仅 FQ 的基础 BBR 配置。"
    fi
}

# --- 交互界面菜单逻辑 ---

run_auto_tune() {
    read -p "请输入服务器可用带宽 (Mbps, 推荐填商家标称值): " bw
    [[ "$bw" =~ ^[0-9]+$ ]] || { warn "必须输入数字！"; return 1; }
    
    read -p "机器用途 (1=代理Proxy/并发多, 2=大文件/并发少) [默认 1]: " role_input
    local role=$([ "$role_input" = "2" ] && echo "bulk" || echo "proxy")
    
    echo -e "\n测速对端选择:"
    echo "  [回车] 自动 Ping 测速全球公益节点池，选取最低延迟"
    echo "  [手动] 输入你自定义的 iperf3 服务端 IP (如 1.2.3.4 或 1.2.3.4:9205)"
    read -p "请输入对端 (默认回车): " peer_input
    
    local peer_full=""
    if [ -z "$peer_input" ]; then
        peer_full=$(auto_pick_peer)
        [ -z "$peer_full" ] && { warn "无法自动获取公益节点，请检查网络或手动输入。"; return 1; }
    else
        peer_full="$peer_input"
        ok "使用自定义测速节点: $peer_full"
    fi
    
    echo "========================================================="
    info "正在应用基础动态内核调优..."
    apply_sysctl "$bw" "$role"
    
    info "正在进行 ISP 限速拐点嗅探与出向流量整形..."
    local iface=$(detect_iface)
    sweep_policer "$peer_full" "$bw" "$iface"
    
    echo "========================================================="
    ok "一键全自动调优操作已完成！"
}

run_base_tune() {
    read -p "请输入服务器可用带宽 (Mbps): " bw
    [[ "$bw" =~ ^[0-9]+$ ]] || { warn "必须输入数字！"; return 1; }
    
    read -p "机器用途 (1=代理Proxy/并发多, 2=大文件/并发少) [默认 1]: " role_input
    local role=$([ "$role_input" = "2" ] && echo "bulk" || echo "proxy")
    
    info "正在应用基础动态内核调优..."
    apply_sysctl "$bw" "$role"
    ok "基础调优已完成！(未施加动态流量整形)"
}

show_status() {
    local iface=$(detect_iface)
    echo "── 机器当前网络调优状态 ──"
    echo "默认 qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "拥塞控制:   $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "当前网卡结构: $(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
    
    local htb_rate=$(tc class show dev "$iface" 2>/dev/null | grep -oE 'rate [0-9]+[MKG]bit' | head -1)
    if [ -n "$htb_rate" ]; then
        echo -e "限速器状态: ${green}已开启 (${htb_rate})${plain}"
    else
        echo -e "限速器状态: ${yellow}未配置上限 (仅 FQ Pacing)${plain}"
    fi
}

menu_loop() {
    need_root
    command -v iperf3 >/dev/null || { info "正在安装 iperf3..."; apt-get update -qq; apt-get install -y iperf3 2>/dev/null || yum install -y iperf3 2>/dev/null; }
    
    while true; do
        clear
        echo "========================================================="
        echo " TCPFit-Lite 跨境网络代理加速与动态整形脚本 v${VERSION}"
        echo " 核心: BBR + FQ Pacing + 动态 BDP + ISP Policer 嗅探"
        echo "========================================================="
        echo "  1. 一键全自动调优 (推荐: 基础调优 + 自动寻找拐点整形)"
        echo "  2. 仅基础调优 (仅修改 Sysctl BBR 与动态缓冲区)"
        echo "  3. 清除当前出向流量整形 (恢复纯 FQ)"
        echo "  4. 查看当前网络调优状态"
        echo "  0. 退出脚本"
        echo "========================================================="
        read -p " 请选择操作 [0-4]: " choice
        
        case "$choice" in
            1) run_auto_tune ;;
            2) run_base_tune ;;
            3) 
                info "正在清除 TC HTB 流量整形..."
                clear_qdisc "$(detect_iface)"
                ok "清除完毕，现已恢复为无上限的纯 FQ 发包策略。"
                ;;
            4) show_status ;;
            0) ok "退出脚本。"; exit 0 ;;
            *) warn "无效输入，请输入 0-4 之间的数字。" ;;
        esac
        
        echo
        read -p "按任意键返回主菜单..." -n 1 -s
    done
}

# --- 入口 ---
menu_loop "$@"
