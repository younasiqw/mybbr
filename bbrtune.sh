#!/usr/bin/env bash
# tcpfit-proxy — 专为跨国代理服务器优化的 TCP 动态调优与流量整形脚本
# 严格基于 BBR + FQ 策略

set -uo pipefail
umask 022

VERSION="1.0.0-ProxyOptimized"
STATE_DIR="/var/lib/tcpfit"
SYSCTL_FILE="/etc/sysctl.d/99-tcpfit.conf"
QDISC_SCRIPT="/usr/local/sbin/tcpfit-qdisc.sh"
QDISC_UNIT="/etc/systemd/system/tcpfit-qdisc.service"

# ── 终端 UI 工具 ────────────────────────────────────────────────────────
green=$'\033[0;32m'; red=$'\033[0;31m'; yellow=$'\033[0;33m'
blue=$'\033[0;36m'; bold=$'\033[1m'; plain=$'\033[0m'

info(){ printf '%s %s\n' "${blue}[*]${plain}" "$*"; }
ok(){   printf '%s %s\n' "${green}[+]${plain}" "$*"; }
warn(){ printf '%s %s\n' "${yellow}[!]${plain}" "$*" >&2; }
die(){  printf '%s %s\n' "${red}[x]${plain}" "$*" >&2; exit "${2:-1}"; }

need_root(){ [ "$(id -u)" = 0 ] || die "需要 root 权限"; }
mkdir -p "$STATE_DIR"

ask(){
  local q="$1" d="${2:-}" a
  if [ -n "$d" ]; then printf '%s [%s]: ' "$q" "$d" >&2; else printf '%s: ' "$q" >&2; fi
  read -r a </dev/tty || a=""
  echo "${a:-$d}"
}

confirm(){
  local d="${2:-n}" a p
  [ "$d" = y ] && p="(Y/n)" || p="(y/N)"
  a=$(ask "$1 $p" "$d")
  [[ "$a" =~ ^[Yy] ]]
}

# ── 核心环境检测 ────────────────────────────────────────────────────────
detect_iface(){
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || \
  ip -6 route show default 2>/dev/null | awk '{print $5; exit}'
}

detect_ram_mb(){ awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }

check_tc_support(){
  local iface="$1"
  tc qdisc add dev "$iface" root handle 1: htb 2>/dev/null
  if [ $? -eq 0 ]; then
    tc qdisc del dev "$iface" root 2>/dev/null
    return 0
  else
    return 1
  fi
}

# ── 动态参数推导 (BDP 与内存自适应) ─────────────────────────────────────
# 默认按 150ms 推算 BDP，覆盖绝大多数跨国代理场景
calc_bdp(){ awk -v b="$1" 'BEGIN{printf "%d", b*1000000/8*(150/1000)}'; }

# 严控 tcp_mem，防止海量连接代理 OOM
calc_tcp_mem(){
  local ram_mb="$1"
  awk -v m="$ram_mb" 'BEGIN{
    pg=m*1024/4; 
    low=int(pg/16); pres=int(pg/8); max=int(pg/4);
    if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384;
    printf "%d %d %d", low, pres, max
  }'
}

# 缓冲区上限 = 2×BDP，但约束在单 socket 不超过内存 1/32
calc_buf_max(){
  awk -v b="$1" -v m="$2" 'BEGIN{
    v = b*2
    cap = m*32768
    if(cap > 268435456) cap = 268435456
    if(v > cap) v = cap
    if(v < 4194304) v = 4194304
    printf "%d", v
  }'
}

# 丢包率计算 (重传/总发包数)
loss_pct(){
  awk -v rt="$1" -v gp="$2" -v d="$3" 'BEGIN{
    pk = gp*1000000*d/8/1448
    if(pk < 1) pk = 1
    printf "%.4f", rt*100/pk
  }'
}

# ── 模块 1: 基础调优 (Base Tuning) ──────────────────────────────────────
cmd_tune(){
  local bw="$1"
  local iface=$(detect_iface)
  local ram=$(detect_ram_mb)
  
  local bdp=$(calc_bdp "$bw")
  local buf_max=$(calc_buf_max "$bdp" "$ram")
  local tcp_mem=$(calc_tcp_mem "$ram")
  # 代理模式保守起步，防止瞬间吃光内存
  local buf_def=1048576 

  info "目标带宽: ${bw} Mbps | 内存: ${ram} MB | 模式: Proxy"

  modprobe tcp_bbr 2>/dev/null
  echo tcp_bbr > /etc/modules-load.d/tcpfit-bbr.conf

  cat > "$SYSCTL_FILE" <<EOF
# 由 tcpfit-proxy 生成
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
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535
EOF

  sysctl -qp "$SYSCTL_FILE" >/dev/null 2>&1
  ok "Sysctl BBR 及自适应缓冲区已应用"

  # IPv4 initcwnd 跃升
  local gw4=$(ip -4 route show default | awk '{print $3; exit}')
  if [ -n "$gw4" ]; then
    ip -4 route replace default via "$gw4" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
    ok "IPv4 initcwnd/initrwnd = 32"
  fi

  # IPv6 initcwnd 跃升 (新增增强)
  local gw6=$(ip -6 route show default | awk '{print $3; exit}')
  if [ -n "$gw6" ]; then
    ip -6 route replace default via "$gw6" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
    ok "IPv6 initcwnd/initrwnd = 32"
  fi
}

# ── 模块 2: 限速器扫描 (Policer Sweep) ──────────────────────────────────
run_iperf(){
  local peer="$1" port="$2" dur="$3" par="$4"
  local tmp=$(mktemp)
  > "$STATE_DIR/iperf.pid"
  
  # 追踪 PID 以严格防僵尸进程
  timeout --foreground $((dur+5)) iperf3 -c "$peer" -p "$port" -t "$dur" -P "$par" -f m >"$tmp" 2>&1 &
  local pid=$!
  echo "$pid" > "$STATE_DIR/iperf.pid"
  wait "$pid" 2>/dev/null
  
  local raw=$(cat "$tmp"); rm -f "$tmp"
  local out=$(echo "$raw" | grep -E "$( [ "$par" -gt 1 ] && echo 'SUM.*sender' || echo 'sender' )" | tail -1)
  [ -z "$out" ] && return
  
  local sg=$(echo "$out" | awk '{print $(NF-3)}')
  local rt=$(echo "$out" | awk '{print $(NF-1)}')
  printf '%s %s\n' "$sg" "$rt"
}

cmd_sweep(){
  local peer="$1" port="${2:-5201}" nominal="$3"
  local iface=$(detect_iface)
  local thresh=0.1 # 0.1% 丢包作为跳变阈值

  info "向 $peer:$port 发起限速器突刺测试 (无整形)..."
  tc qdisc del dev "$iface" root 2>/dev/null
  tc qdisc add dev "$iface" root fq 2>/dev/null

  local res=$(run_iperf "$peer" "$port" 10 1)
  tc qdisc del dev "$iface" root 2>/dev/null

  if [ -z "$res" ]; then
    die "测试失败，检查对端 iperf3 是否在线且无防火墙阻挡。"
  fi

  local gp=$(echo "$res" | awk '{print $1}')
  local rt=$(echo "$res" | awk '{print $2}')
  local lp=$(loss_pct "$rt" "$gp" 10)

  printf "  实测吞吐: %s Mbps | 重传: %s | 丢包率: %s%%\n" "$gp" "$rt" "$lp"

  if awk -v l="$lp" -v t="$thresh" 'BEGIN{exit !(l > t)}'; then
    warn "发现显著丢包！由于本工具侧重出向一键整形，将基于探测吞吐量下调约 10% 避开 ISP 令牌桶。"
    local shape_rate=$(awk -v g="$gp" 'BEGIN{printf "%d", g*0.9}')
    echo "$shape_rate" > "$STATE_DIR/recommend.txt"
    ok "推荐整形目标: ${shape_rate} Mbit"
  else
    ok "线路纯净，未探测到明显的 ISP 尾部丢包。"
    echo "0" > "$STATE_DIR/recommend.txt"
  fi
}

# ── 模块 3: 流量整形 (Egress Traffic Shaping) ───────────────────────────
cmd_shape(){
  local rate="$1"
  local iface=$(detect_iface)

  if [ "$rate" = "0" ] || [ -z "$rate" ]; then
    systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root fq 2>/dev/null
    ok "已恢复为纯 FQ 策略 (无带宽上限)"
    return
  fi

  if ! check_tc_support "$iface"; then
    die "当前内核或虚拟化环境（如限制版 LXC）不支持 HTB/FQ 流量整形模块。"
  fi

  # Systemd 绑定网卡设备，防止重启网卡漂移失效
  local sysd_iface=$(systemd-escape -p "$iface")
  
  cat > "$QDISC_SCRIPT" <<EOF
#!/bin/bash
tc qdisc del dev $iface root 2>/dev/null
tc qdisc add dev $iface root handle 1: htb default 10
tc class add dev $iface parent 1: classid 1:10 htb rate ${rate}mbit ceil ${rate}mbit burst 32k cburst 32k quantum 1514
tc qdisc add dev $iface parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate ${rate}mbit
EOF
  chmod +x "$QDISC_SCRIPT"

  cat > "$QDISC_UNIT" <<EOF
[Unit]
Description=tcpfit Proxy Egress Shaper
After=network-online.target sys-subsystem-net-devices-${sysd_iface}.device
BindsTo=sys-subsystem-net-devices-${sysd_iface}.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$QDISC_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now tcpfit-qdisc.service >/dev/null 2>&1
  ok "已对网卡 $iface 应用 ${rate} Mbit 的 HTB + FQ 流量整形。"
}

# ── 交互式 UI 菜单 ──────────────────────────────────────────────────────
banner(){
  clear
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  tcpfit-proxy - 跨国代理出向 TCP 优化与限速扫描器    ║"
  echo "║  严格遵循 BBR + FQ 策略 (支持多线程/单线程抗丢包)    ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo "  1. 一键全自动调优 (调优 + 扫限速器 + 自动应用整形)"
  echo "  2. 仅基础 TCP 调优 (BBR, Buffer, initcwnd)"
  echo "  3. 取消出向限速整形 (恢复为纯 FQ)"
  echo "  4. 查看当前状态"
  echo "  0. 退出"
  echo
}

menu_loop(){
  need_root
  command -v iperf3 >/dev/null || { warn "请先安装 iperf3 (apt install iperf3)"; exit 1; }
  
  while true; do
    banner
    local c=$(ask "请选择 [0-4]" "1")
    echo
    case "$c" in
      1)
        local bw=$(ask "请输入您的服务器标称出网带宽(Mbps，例: 500)" "500")
        cmd_tune "$bw"
        echo
        local peer=$(ask "请输入目标测试机 IP/域名 (留空使用默认公益测速点)" "speedtest.hkg12.hk.leaseweb.net")
        local port=$(ask "请输入 iperf3 端口" "5201")
        cmd_sweep "$peer" "$port" "$bw"
        
        if [ -f "$STATE_DIR/recommend.txt" ]; then
            local rec=$(cat "$STATE_DIR/recommend.txt")
            echo
            if [ "$rec" -gt 0 ] && confirm "是否立即应用建议的 ${rec} Mbit 限速整形避开丢包?" y; then
                cmd_shape "$rec"
            elif [ "$rec" -eq 0 ]; then
                cmd_shape "0"
            fi
        fi
        ;;
      2)
        local bw=$(ask "请输入您的服务器标称出网带宽(Mbps，例: 500)" "500")
        cmd_tune "$bw"
        cmd_shape "0"
        ;;
      3)
        cmd_shape "0"
        ;;
      4)
        local iface=$(detect_iface)
        info "系统内核: $(uname -r)"
        info "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
        info "默认队列: $(sysctl -n net.core.default_qdisc)"
        info "当前网卡: $iface"
        tc -s qdisc show dev "$iface" | grep -E 'qdisc htb|qdisc fq'
        ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
    echo
    ask "按回车键返回菜单..." "" >/dev/null
  done
}

case "${1:-}" in
  tune) shift; cmd_tune "$1" ;;
  shape) shift; cmd_shape "$1" ;;
  sweep) shift; cmd_sweep "$1" "$2" "$3" ;;
  *) menu_loop ;;
esac
