#!/usr/bin/env bash
# proxy_tcpfit.sh — 专为跨境代理优化的 TCP/BBR/FQ 动态调优与整形脚本
# 仅依赖标准库工具, 纯 Bash 编写
set -uo pipefail

VERSION="1.0.0"
STATE_DIR="/var/lib/proxy_tcpfit"
SYSCTL_FILE="/etc/sysctl.d/99-proxy-tcpfit.conf"
TMP_DIR=$(mktemp -d)

# ====== 样式定义 ======
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
info()  { printf "${CYAN}[*] %s${PLAIN}\n" "$*"; }
ok()    { printf "${GREEN}[+] %s${PLAIN}\n" "$*"; }
warn()  { printf "${YELLOW}[!] %s${PLAIN}\n" "$*" >&2; }
die()   { printf "${RED}[x] %s${PLAIN}\n" "$*" >&2; exit 1; }

# ====== 清理与退出钩子 ======
cleanup() {
    rm -rf "$TMP_DIR"
    # 清理可能残留的后台 iperf3 进程
    if [ -f "$STATE_DIR/iperf.pid" ]; then
        kill -9 $(cat "$STATE_DIR/iperf.pid") 2>/dev/null || true
        rm -f "$STATE_DIR/iperf.pid"
    fi
}
trap cleanup EXIT INT TERM

# ====== 依赖与环境检测 ======
check_deps() {
    local missing=""
    for cmd in iperf3 ping tc ip awk curl; do
        command -v $cmd >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        warn "缺少依赖，正在尝试自动安装: $missing"
        if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y iperf3 iputils-ping iproute2 gawk curl
        elif command -v yum >/dev/null; then yum install -y epel-release && yum install -y iperf3 iputils iproute gawk curl
        else die "请手动安装缺失的依赖:$missing"; fi
    fi
    mkdir -p "$STATE_DIR"
}

get_iface() {
    ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}' || \
    ip -6 route show default 2>/dev/null | awk '/default/{print $5; exit}'
}

check_tc() {
    local iface=$(get_iface)
    tc qdisc add dev "$iface" root handle 1: htb 2>/dev/null && tc qdisc del dev "$iface" root 2>/dev/null
    return $?
}

# ====== 公益对端自动测速机制 ======
PEER_POOL="
speedtest.hkg12.hk.leaseweb.net|香港|5201-5210
speedtest.sin1.sg.leaseweb.net|新加坡|5201-5210
speedtest.tyo11.jp.leaseweb.net|东京|5201-5210
speedtest.syd12.au.leaseweb.net|悉尼|5201-5210
speedtest.lax12.us.leaseweb.net|洛杉矶|5201-5210
speedtest.fra1.de.leaseweb.net|法兰克福|5201-5210
ams.speedtest.clouvider.net|阿姆斯特丹|5200-5209
lon.speedtest.clouvider.net|伦敦|5200-5209
"

auto_pick_peer() {
    info "正在并发 Ping 公益 iperf3 测速池，寻找最佳路由节点..."
    while IFS='|' read -r host loc ports; do
        [ -z "$host" ] && continue
        (
            local rtt=$(ping -4 -c 2 -W 2 "$host" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
            if [ -n "$rtt" ]; then
                echo "$rtt|$host|$loc|$ports" >> "$TMP_DIR/ping_results"
            fi
        ) &
    done <<< "$PEER_POOL"
    wait

    [ -s "$TMP_DIR/ping_results" ] || return 1

    # 按延迟排序测试端口连通性
    for line in $(sort -n -t'|' -k1 "$TMP_DIR/ping_results"); do
        local rtt=$(echo "$line" | cut -d'|' -f1)
        local host=$(echo "$line" | cut -d'|' -f2)
        local loc=$(echo "$line" | cut -d'|' -f3)
        local port=$(echo "$line" | cut -d'|' -f4 | cut -d'-' -f1) # 取段首端口
        
        timeout 3 bash -c "</dev/tcp/$host/$port" 2>/dev/null
        if [ $? -eq 0 ]; then
            ok "自动选择最优节点: $host ($loc) - 延迟 ${rtt}ms" >&2
            echo "$host:$port"
            return 0
        fi
    done
    return 1
}

# ====== 流量整形与扫描引擎 ======
apply_shape() {
    local rate_mbit=$1
    local iface=$(get_iface)
    tc qdisc del dev "$iface" root 2>/dev/null
    if [ "$rate_mbit" -eq 0 ]; then
        tc qdisc add dev "$iface" root fq 2>/dev/null
        return 0
    fi
    # 严格的 HTB + FQ 控制，压制 32k 突发
    tc qdisc add dev "$iface" root handle 1: htb default 10
    tc class add dev "$iface" parent 1: classid 1:10 htb rate ${rate_mbit}mbit ceil ${rate_mbit}mbit burst 32k cburst 32k quantum 1514
    tc qdisc add dev "$iface" parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate ${rate_mbit}mbit
}

run_iperf() {
    local target=$1
    local port=$2
    local duration=$3
    local streams=$4
    local out_file="$TMP_DIR/iperf.log"

    # 执行并跟踪 PID，确保随时可以被 kill
    iperf3 -c "$target" -p "$port" -t "$duration" -P "$streams" -f m > "$out_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$STATE_DIR/iperf.pid"
    
    # 模拟转圈等待
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        printf "\r${CYAN}[%c] 测速运行中 (${duration}s, $streams 线程) -> $target:$port...${PLAIN}" "${spin:i++%4:1}" >&2
        sleep 0.2
    done
    printf "\r\033[K" >&2
    rm -f "$STATE_DIR/iperf.pid"

    # 解析 iperf3 结果
    # 提取 Sender 和 Receiver 结果，计算丢包率
    local sender=$(grep "sender" "$out_file" | tail -n 1)
    local receiver=$(grep "receiver" "$out_file" | tail -n 1)
    
    if [ -z "$sender" ]; then echo ""; return 1; fi
    
    # Mbps_Sender, Retransmits, Mbps_Receiver
    local smbps=$(echo "$sender" | awk '{print $(NF-3)}')
    local retrans=$(echo "$sender" | awk '{print $(NF-1)}')
    local rmbps=$(echo "$receiver" | awk '{print $(NF-2)}')
    
    [ -z "$rmbps" ] && rmbps=$smbps
    
    # 丢包率公式: 重传次数 / (吞吐量Mbps * 时间 / 8 / 1448字节MSS)
    local loss_pct=$(awk -v rt="$retrans" -v gp="$smbps" -v d="$duration" 'BEGIN{
        pk = gp*1000000*d/8/1448; if(pk<1) pk=1;
        printf "%.4f", rt*100/pk
    }')
    
    echo "$smbps $rmbps $retrans $loss_pct"
}

smart_sweep() {
    local peer_ip=$1
    local peer_port=$2
    local iface=$(get_iface)

    info "开始智能 ISP 限速器扫描 (Smart Policer Sweep)..."
    
    # 第一步：清空规则，跑裸测 (Unshaped)
    apply_shape 0
    local raw=$(run_iperf "$peer_ip" "$peer_port" 10 1)
    if [ -z "$raw" ]; then die "无法连接到 iperf3 服务器，请检查网络或更换节点。"; fi
    
    local smbps=$(echo "$raw" | awk '{print $1}')
    local rmbps=$(echo "$raw" | awk '{print $2}')
    local retrans=$(echo "$raw" | awk '{print $3}')
    local loss=$(echo "$raw" | awk '{print $4}')
    
    printf "  >> 不限速测试结果: 发送 %s Mbps, 接收 %s Mbps, 重传 %s (丢包率 %s%%)\n" "$smbps" "$rmbps" "$retrans" "$loss"
    
    # 阈值 0.1% 视为撞到了限速墙
    if awk -v l="$loss" 'BEGIN{exit !(l <= 0.1)}'; then
        ok "链路非常干净！没有探测到明显的运营商限速墙。"
        echo "$rmbps" > "$STATE_DIR/best_bw"
        return 0
    fi
    
    warn "检测到高达 ${loss}% 的丢包，触发 ISP 令牌桶限速机制，启动智能降级..."
    
    # 第二步：智能向下扫描 (Smart Step-down)
    # 取 Receiver (实际送达) 作为初始限速天花板，每次下调寻找干净区间
    local target=$(awk -v r="$rmbps" 'BEGIN{printf "%d", r}')
    local step=0
    local safe_rate=""
    
    while [ $step -lt 5 ]; do
        [ "$target" -lt 5 ] && target=5
        info "测试限速策略: ${target} Mbit/s ..."
        apply_shape "$target"
        
        local res=$(run_iperf "$peer_ip" "$peer_port" 8 1)
        local cur_loss=$(echo "$res" | awk '{print $4}')
        
        if awk -v l="$cur_loss" 'BEGIN{exit !(l <= 0.1)}'; then
            ok "找到黄金拐点！在 ${target} Mbps 下丢包率降至 ${cur_loss}%，链路恢复稳定。"
            safe_rate=$(awk -v t="$target" 'BEGIN{printf "%d", t*0.95}') # 退让 5% 作为安全余量
            break
        else
            warn "当前 ${target} Mbps 丢包仍为 ${cur_loss}%，继续下探..."
            target=$(awk -v t="$target" 'BEGIN{printf "%d", t*0.90}') # 下调 10%
        fi
        ((step++))
    done
    
    if [ -n "$safe_rate" ]; then
        echo "$safe_rate" > "$STATE_DIR/best_bw"
        apply_shape "$safe_rate"
    else
        warn "经过 5 轮下探仍未找到无丢包区间。对端可能本身存在网络拥堵。"
        apply_shape 0
    fi
}

# ====== 动态 BDP 与核心参数调优 ======
tune_sysctl() {
    local bw=$1 # Mbps
    local ram_mb=$(free -m | awk '/Mem:/{print $2}')
    local rtt=150 # 默认预估 150ms 以覆盖跨境常见 RTT
    
    info "根据服务器规格 (RAM: ${ram_mb}MB) 动态计算并下发调优参数..."
    
    # BDP 计算与 Socket 内存限制
    # 绝对上限受限于机器内存的 1/8（防止海量代理并发爆内存）
    local bdp=$(awk -v b="$bw" -v r="$rtt" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}')
    local buf_max=$(awk -v b="$bdp" -v m="$ram_mb" 'BEGIN{
        v = b*2
        cap = m*32768 # max budget per socket
        if(v > cap) v = cap
        if(v < 4194304) v = 4194304 # 兜底 4MB
        printf "%d", v
    }')
    local tcp_mem=$(awk -v m="$ram_mb" 'BEGIN{
        pg=m*1024/4; 
        l=int(pg/16); p=int(pg/8); mx=int(pg/4);
        if(l<4096) l=4096; if(p<8192) p=8192; if(mx<16384) mx=16384;
        printf "%d %d %d", l, p, mx
    }')

    # 加载 BBR 模块
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/proxy-bbr.conf

    cat > "$SYSCTL_FILE" <<EOF
# [Proxy TCPFit Dynamic Tuning]
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区边界限定 (Max: ${buf_max} bytes)
net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 $buf_max
net.ipv4.tcp_wmem = 4096 1048576 $buf_max

# 全局内存安全锁 (防止 OOM)
net.ipv4.tcp_mem = $tcp_mem

# 代理连接高频回收与起步优化
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF
    sysctl -qp "$SYSCTL_FILE" >/dev/null 2>&1
    ok "系统内核网络参数 (Sysctl) 已优化。"
    
    # Initcwnd 跃升优化 (IPv4 + IPv6)
    local iface=$(get_iface)
    local gw4=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    local gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}')
    
    if [ -n "$gw4" ]; then
        ip -4 route change default via "$gw4" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
        ok "IPv4 initcwnd/initrwnd 提升为 32 (首屏加速生效)"
    fi
    if [ -n "$gw6" ]; then
        ip -6 route change default via "$gw6" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null
        ok "IPv6 initcwnd/initrwnd 提升为 32 (首屏加速生效)"
    fi
}

# ====== UI 与 菜单 ======
menu() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║     Proxy TCPFit - 跨境代理流量整形与内核自适应调优系统 ║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "║ ${GREEN}1. 一键智能测速 + 流量整形调优 (推荐)${PLAIN}              ║"
    echo -e "║ ${GREEN}2. 仅进行内核 BDP 计算与路由优化 (不测速不整形)${PLAIN}      ║"
    echo -e "║ ${YELLOW}3. 清除流量整形，恢复原始 FQ 队列${PLAIN}                  ║"
    echo -e "║ 0. 退出                                              ║"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${PLAIN}"
    
    read -p "请输入选择 [0-3]: " choice
    case $choice in
        1)
            check_deps
            if ! check_tc; then
                die "当前系统架构(可能为 LXC/OpenVZ)不支持 TC 流量整形，请退回菜单使用模式 2！"
            fi
            
            echo ""
            info "请指定用于测试的 iperf3 服务器对端："
            echo "  [直接回车] : 自动 Ping 挑选最优公益 iperf3 测速服务器"
            echo "  [输入 IP:端口] : 使用自定义对端 (如 1.2.3.4:5201)"
            read -p "对端地址: " custom_peer
            
            if [ -z "$custom_peer" ]; then
                local peer_str=$(auto_pick_peer)
                if [ $? -ne 0 ]; then die "自动获取公益节点失败，请重试或指定自定义对端。"; fi
                peer_ip="${peer_str%:*}"
                peer_port="${peer_str##*:}"
            else
                peer_ip="${custom_peer%:*}"
                peer_port="${custom_peer##*:}"
                [ -z "$peer_port" ] || [ "$peer_port" == "$peer_ip" ] && peer_port=5201
            fi
            
            smart_sweep "$peer_ip" "$peer_port"
            
            local final_bw=1000
            if [ -f "$STATE_DIR/best_bw" ]; then
                final_bw=$(cat "$STATE_DIR/best_bw")
                ok "已将网卡流量整形界限固化在: ${final_bw} Mbps"
            fi
            
            tune_sysctl "$final_bw"
            ok "一切就绪！现在你的代理软件将运行得更加丝滑稳定。"
            ;;
            
        2)
            check_deps
            read -p "请输入你购买服务器的标称最大带宽 (Mbps，如 1000): " input_bw
            [ -z "$input_bw" ] && input_bw=1000
            apply_shape 0
            tune_sysctl "$input_bw"
            ok "调优完毕！"
            ;;
            
        3)
            local iface=$(get_iface)
            tc qdisc del dev "$iface" root 2>/dev/null || true
            tc qdisc add dev "$iface" root fq 2>/dev/null || true
            ok "已移除出向限速策略，恢复原始纯 FQ。"
            ;;
            
        0) exit 0 ;;
        *) warn "输入错误" ; sleep 1 ; menu ;;
    esac
}

# 必须为 root 运行
if [ "$(id -u)" != "0" ]; then die "此脚本必须以 root 权限运行 (sudo -i)。"; fi

menu
