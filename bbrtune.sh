#!/usr/bin/env bash
# proxy-tcp-tune.sh — 专为跨境代理服务器打造的 TCP 调优与整形工具
# 包含动态 BDP 推导、TCP 内存约束、主动探测限速器 (Sweep)、HTB+FQ 出向整形

set -euo pipefail

VERSION="1.0.0"
STATE_DIR="/var/lib/proxy-tune"
SYSCTL_FILE="/etc/sysctl.d/99-proxy-tune.conf"
QDISC_SCRIPT="/usr/local/sbin/proxy-qdisc.sh"
QDISC_UNIT="/etc/systemd/system/proxy-qdisc@.service" # 注意这里用了模板单元 @

# 颜色输出
_info()  { printf "\033[0;36m[*] %s\033[0m\n" "$*"; }
_ok()    { printf "\033[0;32m[+] %s\033[0m\n" "$*"; }
_warn()  { printf "\033[0;33m[!] %s\033[0m\n" "$*" >&2; }
_die()   { printf "\033[0;31m[x] %s\033[0m\n" "$*" >&2; exit 1; }

# 精确的 PID 追踪，避免误杀其他服务
declare -a IPERF_PIDS=()
cleanup_pids() {
    for pid in "${IPERF_PIDS[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
    done
    IPERF_PIDS=()
}
trap 'cleanup_pids; qdisc_restore 2>/dev/null; exit 130' INT TERM

# ==========================================
# 1. 环境与能力检测
# ==========================================
detect_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || \
    ip -6 route show default 2>/dev/null | awk '{print $5; exit}'
}

check_tc_capability() {
    local iface="$1"
    _info "Checking TC (Traffic Control) capabilities on $iface..."
    if ! tc qdisc add dev "$iface" root handle 1: htb 2>/dev/null; then
        _die "Kernel lacks 'sch_htb' module or permissions (common in LXC containers). Shaping disabled."
    fi
    tc qdisc del dev "$iface" root 2>/dev/null
}

# ==========================================
# 2. 数学推导核心 (BDP & 内存自适应)
# ==========================================
# 目标：覆盖 150ms 的跨境 RTT
calc_bdp() { awk -v b="$1" -v r=150 'BEGIN{printf "%d", b*1000000/8*(r/1000)}'; }

# TCP 内存约束：保证海量并发下不 OOM
calc_tcp_mem() {
    local ram_mb="$1"
    awk -v m="$ram_mb" 'BEGIN{
        pg=m*1024/4;
        low=int(pg/16); pres=int(pg/8); max=int(pg/4);
        if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384;
        printf "%d %d %d", low, pres, max
    }'
}

calc_buf_max() {
    awk -v b="$1" -v m="$2" 'BEGIN{
        v = b*2
        cap = m*32768  # 限制单个 Socket 最大占物理内存的 1/32
        if(cap > 268435456) cap = 268435456 # 硬顶 256MB
        if(v > cap) v = cap
        if(v < 4194304) v = 4194304         # 兜底 4MB
        printf "%d", v
    }'
}

# ==========================================
# 3. 基础调优 (Sysctl & Initcwnd)
# ==========================================
apply_base_tune() {
    local bw="$1" iface="$2"
    local ram_mb; ram_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    
    local bdp; bdp=$(calc_bdp "$bw")
    local buf_max; buf_max=$(calc_buf_max "$bdp" "$ram_mb")
    local tcp_mem; tcp_mem=$(calc_tcp_mem "$ram_mb")
    local buf_def=1048576 # 代理场景默认 1MB 起步

    _info "Tuning derived from: ${bw} Mbps / RAM ${ram_mb} MB"
    _info "BDP: $((bdp/1024/1024)) MB, Buffer Max: $((buf_max/1024/1024)) MB"

    cat > "$SYSCTL_FILE" <<EOF
# 严格指定原生 BBR + FQ
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
net.ipv4.tcp_adv_win_scale = 1

net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# 代理服务器核心参数
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF
    sysctl -q -p "$SYSCTL_FILE"
    _ok "Sysctl parameters applied."

    # 提升 initcwnd (双栈支持)
    local gw4 gw6 if6
    gw4=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    if [ -n "$gw4" ]; then
        ip -4 route replace default via "$gw4" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null && _ok "IPv4 initcwnd=32 applied."
    fi
    gw6=$(ip -6 route show default 2>/dev/null | awk '/^default/{print $3; exit}')
    if6=$(ip -6 route show default 2>/dev/null | awk '/^default/{print $5; exit}')
    if [ -n "$gw6" ] && [ -n "$if6" ]; then
        ip -6 route change default via "$gw6" dev "$if6" initcwnd 32 initrwnd 32 2>/dev/null && _ok "IPv6 initcwnd=32 applied."
    fi
}

# ==========================================
# 4. Policer Sweep (主动测速与限速器拐点查找)
# ==========================================
run_iperf() {
    local peer="$1" port="$2" dur="$3" streams="$4"
    local tmp_file; tmp_file=$(mktemp)
    
    timeout 25 iperf3 -c "$peer" -p "$port" -t "$dur" -P "$streams" -f m > "$tmp_file" 2>&1 &
    local pid=$!
    IPERF_PIDS+=("$pid")
    wait "$pid" 2>/dev/null || true
    
    local out; out=$(grep -E "$( [ "$streams" -gt 1 ] && echo 'SUM.*sender' || echo 'sender' )" "$tmp_file" | tail -1)
    rm -f "$tmp_file"
    
    if [ -n "$out" ]; then
        local gp rt
        gp=$(echo "$out" | awk '{print $(NF-3)}')
        rt=$(echo "$out" | awk '{print $(NF-1)}')
        echo "$gp $rt"
    fi
}

# 计算丢包率
calc_loss_pct() {
    awk -v rt="$1" -v gp="$2" -v dur="$3" 'BEGIN{
        pk = gp*1000000*dur/8/1448
        if(pk < 1) pk = 1
        printf "%.4f", rt*100/pk
    }'
}

# 临时整形器（测试用）
apply_test_shaper() {
    local iface="$1" rate="$2"
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root handle 1: htb default 10
    tc class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" burst 32k cburst 32k
    tc qdisc add dev "$iface" parent 1:10 handle 10: fq limit 40960 maxrate "${rate}mbit"
}

qdisc_restore() { tc qdisc del dev "$(detect_iface)" root 2>/dev/null || true; }

sweep_knee() {
    local peer="$1" port="$2" bw="$3" iface="$4"
    local dur=10 step=$(( bw / 10 ))
    [ "$step" -lt 10 ] && step=10
    
    _info "Starting Policer Sweep against ${peer}:${port}..."
    _info "Unshaped probe first (1 stream, ${dur}s)..."
    
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root fq
    
    local res; res=$(run_iperf "$peer" "$port" "$dur" 1)
    qdisc_restore
    
    if [ -z "$res" ]; then
        _die "Initial probe failed. Check if iperf3 server $peer:$port is reachable."
    fi
    
    local ug rt ulp
    ug=$(echo "$res" | awk '{print $1}')
    rt=$(echo "$res" | awk '{print $2}')
    ulp=$(calc_loss_pct "$rt" "$ug" "$dur")
    
    _info "Unshaped result: ${ug} Mbps, Retrans: ${rt}, Loss: ${ulp}%"
    if awk -v l="$ulp" 'BEGIN{exit !(l <= 0.1)}'; then
        _ok "No policer detected (Loss <= 0.1%). Shaping not required."
        return 0
    fi
    
    _warn "Policer present! High loss detected. Beginning downward sweep..."
    local cur_rate=$(( ${ug%.*} ))
    local best_rate=""
    
    # 向下探测，寻找丢包率降至 0.1% 以下的拐点
    while [ "$cur_rate" -gt 10 ]; do
        apply_test_shaper "$iface" "$cur_rate"
        res=$(run_iperf "$peer" "$port" "$dur" 1)
        
        if [ -n "$res" ]; then
            local cg crt clp
            cg=$(echo "$res" | awk '{print $1}')
            crt=$(echo "$res" | awk '{print $2}')
            clp=$(calc_loss_pct "$crt" "$cg" "$dur")
            
            if awk -v l="$clp" 'BEGIN{exit !(l <= 0.1)}'; then
                best_rate="$cur_rate"
                _ok "Knee found at ${cur_rate} Mbps! Loss dropped to ${clp}%."
                break
            else
                _info "Tested ${cur_rate} Mbps -> Loss: ${clp}% (still hitting policer)"
            fi
        fi
        cur_rate=$(( cur_rate - step ))
    done
    
    qdisc_restore
    
    if [ -n "$best_rate" ]; then
        # 扣除安全余量 (Margin)
        local final_rate=$(( best_rate - 10 ))
        [ "$final_rate" -lt 1 ] && final_rate=$best_rate
        echo "$final_rate" > "$STATE_DIR/recommend_rate"
        _ok "Recommended egress rate with margin: ${final_rate} Mbps"
    else
        _warn "Could not pinpoint a clean knee. Link might be inherently lossy."
    fi
}

# ==========================================
# 5. 固化出向整形 (HTB + FQ Systemd)
# ==========================================
apply_permanent_shaping() {
    local iface="$1" rate="$2"
    _info "Applying permanent HTB+FQ shaping at ${rate} Mbps on $iface..."

    cat > "$QDISC_SCRIPT" <<EOF
#!/bin/bash
IF=\$1
RATE=${rate}
tc qdisc del dev \$IF root 2>/dev/null
tc qdisc add dev \$IF root handle 1: htb default 10
tc class add dev \$IF parent 1: classid 1:10 htb rate \${RATE}mbit ceil \${RATE}mbit burst 32k cburst 32k
tc qdisc add dev \$IF parent 1:10 handle 10: fq limit 40960 maxrate \${RATE}mbit
EOF
    chmod +x "$QDISC_SCRIPT"

    # 使用 @ 模板，精准绑定网卡状态，解决虚拟网卡重启失效问题
    cat > "$QDISC_UNIT" <<EOF
[Unit]
Description=TCPFit Egress Shaper on %I
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$QDISC_SCRIPT %I

[Install]
WantedBy=sys-subsystem-net-devices-%i.device
EOF
    systemctl daemon-reload
    systemctl enable --now "proxy-qdisc@${iface}.service" 2>/dev/null || true
    _ok "Egress shaping service applied and enabled."
}


# ==========================================
# 入口逻辑
# ==========================================
usage() {
    echo "Usage: $0 [options]"
    echo "  --bw <mbps>       Nominal bandwidth of your server (e.g., 500)"
    echo "  --peer <ip:port>  iperf3 server to sweep against (e.g., 1.1.1.1:5201)"
    echo "  --shape <mbps>    Directly apply shaping without sweeping"
    echo "  --tune-only       Only apply sysctl & initcwnd, no shaping/sweeping"
    exit 1
}

[ "$#" -eq 0 ] && usage
[ "$(id -u)" = 0 ] || _die "Must be run as root."

mkdir -p "$STATE_DIR"
IFACE=$(detect_iface)
[ -n "$IFACE" ] || _die "Could not detect default interface."

BW=""
PEER=""
PORT="5201"
SHAPE_RATE=""
TUNE_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bw) BW="$2"; shift 2 ;;
        --peer) 
            PEER="${2%:*}"
            [[ "$2" == *":"* ]] && PORT="${2##*:}"
            shift 2 ;;
        --shape) SHAPE_RATE="$2"; shift 2 ;;
        --tune-only) TUNE_ONLY=1; shift ;;
        *) usage ;;
    esac
done

[ -z "$BW" ] && _die "--bw is required to calculate BDP."

_info "Active Interface: $IFACE"
apply_base_tune "$BW" "$IFACE"

if [ "$TUNE_ONLY" -eq 1 ]; then
    _ok "Base tune applied. Exiting as requested."
    exit 0
fi

check_tc_capability "$IFACE"

if [ -n "$SHAPE_RATE" ]; then
    apply_permanent_shaping "$IFACE" "$SHAPE_RATE"
    exit 0
fi

if [ -n "$PEER" ]; then
    if ! command -v iperf3 >/dev/null; then
        _die "iperf3 is required for sweeping. Please install it."
    fi
    sweep_knee "$PEER" "$PORT" "$BW" "$IFACE"
    
    if [ -f "$STATE_DIR/recommend_rate" ]; then
        REC_RATE=$(cat "$STATE_DIR/recommend_rate")
        apply_permanent_shaping "$IFACE" "$REC_RATE"
    fi
else
    _warn "No --peer provided. Skipping policer sweep and shaping."
fi

_ok "All optimization processes completed!"
