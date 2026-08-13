#!/usr/bin/env bash
# TCPFit-Lite: 高阶单机 TCP 调优与出向流量整形系统 (Proxy 专用)
# 针对跨境代理高延迟、易触发 ISP 限速器 (Policer) 场景优化

set -uo pipefail

VERSION="1.0.0-Lite"
STATE_DIR="/var/lib/tcpfit-lite"
SYSCTL_FILE="/etc/sysctl.d/99-tcpfit-lite.conf"
IPERF_PIDS_FILE="/tmp/tcpfit_iperf_pids"
DEFAULT_RTT=150 # 默认假定 150ms 延迟，覆盖绝大多数跨境场景

# 公益 iperf3 服务器池 (格式: 域名|地区|提供商)
PEER_POOL="
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.sea11.us.leaseweb.net|西雅图|Leaseweb
"

# --- 界面与基础功能 ---
green=$'\033[0;32m'; red=$'\033[0;31m'; yellow=$'\033[0;33m'; cyan=$'\033[0;36m'; plain=$'\033[0m'
info() { echo -e "${cyan}[*]${plain} $1"; }
ok() { echo -e "${green}[+]${plain} $1"; }
warn() { echo -e "${yellow}[!]${plain} $1" >&2; }
die() { echo -e "${red}[x]${plain} $1" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "需要 root 权限"; }
mkdir -p "$STATE_DIR"

# 精准 PID 管理，防止测速产生僵尸进程
record_pid() { echo "$1" >> "$IPERF_PIDS_FILE"; }
reap_iperf() {
    if [ -f "$IPERF_PIDS_FILE" ]; then
        xargs -r kill -9 < "$IPERF_PIDS_FILE" 2>/dev/null || true
        rm -f "$IPERF_PIDS_FILE"
    fi
    pkill -x iperf3 2>/dev/null || true
}

# 捕获 Ctrl+C 恢复网络状态
trap 'echo; warn "操作被中断，正在清理进程和恢复网卡..."; clear_qdisc "$(detect_iface)"; reap_iperf; exit 130' INT TERM

# --- 环境检测 ---
detect_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || \
    ip -6 route show default 2>/dev/null | awk '{print $5; exit}'
}

detect_ram_mb() { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
have_ipv4() { ip -4 route get 1.1.1.1 >/dev/null 2>&1; }

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
    # burst 压至 32k 是防止微突发打穿运营商 Policer 的关键
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
    
    # 代理角色并发极高，起步缓冲区设保守值 1MB，大文件传输可设 4MB
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

    # 路由层提速：提升 initcwnd，大幅缩短首屏握手延迟
    local gw4=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    local gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}')
    [ -n "$gw4" ] && ip -4 route change default via "$gw4" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
    [ -n "$gw6" ] && ip -6 route change default via "$gw6" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
    ok "出站路由 initcwnd/initrwnd 已提速至 32 (IPv4/IPv6)"
}

# --- 测速对端自动选择 ---
auto_pick_peer() {
    command -v ping >/dev/null || die "缺少 ping，无法自动选点。请安装 iputils-ping"
    info "正在并发 Ping 测试全球公益 iperf3 节点..."
    local tmpf=$(mktemp)
    while IFS='|' read -r host name prov; do
        [ -z "$host" ] && continue
        (
            rtt=$(ping -c 2 -W 2 "$host" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
            [ -n "$rtt" ] && echo "$rtt $host $name" >> "$tmpf"
        ) &
    done <<< "$PEER_POOL"
    wait
    
    local best=$(sort -n "$tmpf" | head -n 1)
    rm -f "$tmpf"
    
    if [ -n "$best" ]; then
        local rtt=$(echo "$best" | awk '{print $1}')
        local host=$(echo "$best" | awk '{print $2}')
        local loc=$(echo "$best" | awk '{print $3}')
        ok "自动选中延迟最低节点: $host ($loc) - 延迟: ${rtt}ms"
        echo "$host"
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
    
    # 提取总吞吐量和重传数
    local grep_str=$([ "$threads" -gt 1 ] && echo 'SUM.*sender' || echo 'sender')
    local out=$(grep -E "$grep_str" "$logf" | tail -1)
    rm -f "$logf"
    
    if [ -n "$out" ]; then
        local bitrate=$(echo "$out" | awk '{print $(NF-3)}')
        local retrans=$(echo "$out" | awk '{print $(NF-1)}')
        echo "$bitrate $retrans"
    fi
}

# 计算丢包率
loss_pct() {
    awk -v r="$1" -v b="$2" -v t="$3" 'BEGIN{
        pk = b*1000000*t/8/1448
        if(pk<1) pk=1
        printf "%.4f", r*100/pk
    }'
}

# --- 限速器扫描 (Policer Sweep) ---
sweep_policer() {
    local peer="$1" bw="$2" iface="$3"
    local port=5201
    
    info "开始扫描 ISP 限速拐点 (目标: $peer, 基准带宽: ${bw}Mbps)..."
    
    # 第一步：不限速裸测 (单线程，探测最真实的丢包)
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
    
    # 定义扫描区间
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
        
        # 判断重传跳变 (阈值 0.1%)
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
        # 预留 5% 作为晚高峰安全余量
        local final_rate=$(awk -v k="$last_ok" 'BEGIN{print int(k*0.95)}')
        ok "探测到干净上限为 ${last_ok}Mbit，留余量后建议整形值：${final_rate}Mbit"
        set_qdisc "$iface" "$final_rate"
        ok "已应用 HTB 出向整形 (速率: ${final_rate}Mbit)，代理将彻底告别断流！"
    else
        warn "未能在扫描区间找到绝对干净的速率点。将保留仅 FQ 的基础 BBR 配置。"
    fi
}

# --- 交互界面菜单 ---
main() {
    need_root
    command -v iperf3 >/dev/null || { info "正在安装 iperf3..."; apt-get install -y iperf3 2>/dev/null || yum install -y iperf3 2>/dev/null; }
    
    clear
    echo "========================================================="
    echo " TCPFit-Lite 跨境网络代理加速与动态整形脚本 v${VERSION}"
    echo " 核心: BBR + FQ Pacing + 动态 BDP + ISP Policer 嗅探"
    echo "========================================================="
    echo
    
    read -p "1. 请输入服务器可用带宽 (Mbps, 推荐填商家标称值): " bw
    [[ "$bw" =~ ^[0-9]+$ ]] || die "必须输入数字！"
    
    read -p "2. 机器用途 (1=代理Proxy/并发多, 2=大文件/并发少) [默认 1]: " role_input
    local role=$([ "$role_input" = "2" ] && echo "bulk" || echo "proxy")
    
    echo
    echo "3. iperf3 测速对端选择:"
    echo "   [回车] 自动 Ping 测速公益节点池，选取最低延迟"
    echo "   [手动] 输入你自己的 iperf3 服务端 IP (如 1.2.3.4)"
    read -p "请输入对端 (默认回车): " peer_input
    
    local peer=""
    if [ -z "$peer_input" ]; then
        peer=$(auto_pick_peer)
        [ -z "$peer" ] && die "无法自动获取公益节点，请重新运行并手动输入。"
    else
        peer="$peer_input"
        ok "使用自定义测速节点: $peer"
    fi
    
    echo "========================================================="
    info "阶段 1/3：应用基础动态内核调优..."
    apply_sysctl "$bw" "$role"
    
    info "阶段 2/3：ISP 限速拐点嗅探与出向流量整形..."
    local iface=$(detect_iface)
    sweep_policer "$peer" "$bw" "$iface"
    
    echo "========================================================="
    ok "所有网络底层调优操作已完成！"
    info "BBR 拥塞控制、自适应 TCP Buffer、FQ Pacing 均已就绪。"
}

main "$@"
