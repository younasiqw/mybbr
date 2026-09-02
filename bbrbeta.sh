#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"

# 权限与系统检查
[[ $EUID -ne 0 ]] && echo -e "${Error} 请使用 root 用户运行此脚本！" && exit 1

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        echo -e "${Error} 本脚本仅支持 Debian 和 Ubuntu 系统！"
        exit 1
    fi
else
    echo -e "${Error} 无法检测系统类型，请在 Debian/Ubuntu 上运行！"
    exit 1
fi

apply_bbr_and_sysctl() {
    echo -e "${Info} 开始清理旧的网络配置并应用静态参数..."
    
    # 清理可能导致冲突的旧参数
    local params=(
        "net.ipv4.tcp_no_metrics_save" "net.ipv4.tcp_ecn" "net.ipv4.tcp_frto"
        "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_sack"
        "net.ipv4.tcp_fack" "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale"
        "net.ipv4.tcp_moderate_rcvbuf" "net.core.rmem_max" "net.core.wmem_max"
        "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min" "net.core.default_qdisc" "net.ipv4.tcp_congestion_control"
    )
    for p in "${params[@]}"; do
        sed -i "/^$p/d" /etc/sysctl.conf
    done

    # 严格写入你提供的参数块，无任何删改
    cat >> /etc/sysctl.conf << EOF
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.ip_forward=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=10485760
net.core.wmem_max=10485760
net.ipv4.tcp_rmem=4096 16384 10485760
net.ipv4.tcp_wmem=4096 87380 10485760
net.ipv4.udp_rmem_min=4096
net.ipv4.udp_wmem_min=4096
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p
    
    echo -e "${Info} 静态内核参数已应用。"
    check_bbr_status
}

smart_bbr_tuning() {
    echo -e "${Info} 启动智能 BBR 缓冲区调优 (基于 BDP 带宽延迟乘积)..."
    
    read -p "请输入到此服务器的平均延迟 (ms) [默认: 150]: " latency
    latency=${latency:-150}
    
    read -p "请输入你预期的最大网速上限 (Mbps) [默认: 1000]: " bandwidth
    bandwidth=${bandwidth:-1000}
    
    # 留存 15% 的宽带冗余，计算实际可用带宽
    local real_bandwidth=$(( bandwidth * 85 / 100 ))
    
    # 计算 BDP (Bandwidth-Delay Product)
    # BDP (bytes) = 实际可用带宽 (Mbps) * 1000000 / 8 * Latency (ms) / 1000 = 实际可用带宽 * Latency * 125
    local bdp_bytes=$(( real_bandwidth * latency * 125 ))
    
    # 追求无丢包与稳定性：最大缓冲区设置为 BDP 的 4 倍
    local max_buffer=$(( bdp_bytes * 4 ))
    
    # 设定安全底线，防止由于用户输入太小导致连接断流 (最低6MB)
    if [ "$max_buffer" -lt 6291456 ]; then
        max_buffer=6291456
    fi
    
    # 防止内存溢出：获取系统总物理内存，最高允许占用 10% 作为单路 TCP 极限缓冲区
    local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    # 计算内存的 10% 的字节数（1024 / 10 约等于 102，使用该常数避免数值过大引发 Bash 溢出）
    local max_mem_limit=$(( total_mem_kb * 102 ))
    if [ "$max_buffer" -gt "$max_mem_limit" ]; then
        max_buffer=$max_mem_limit
        echo -e "${Info} 触发内存保护机制，最大缓冲区已限制为系统内存的 10% ($max_buffer Bytes)"
    fi
    
    # 设定默认缓冲区，恢复采用系统中间数，避免中间数值过大
    local rmem_default=16384
    local wmem_default=87380

    echo -e "${Info} 留存 15% 宽带冗余后，计算得出的基础 BDP 为: $bdp_bytes Bytes"
    echo -e "${Info} 动态分配的最大 TCP 缓冲区 为: $max_buffer Bytes"

    local params=(
        "net.ipv4.tcp_no_metrics_save" "net.ipv4.tcp_ecn" "net.ipv4.tcp_frto"
        "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_sack"
        "net.ipv4.tcp_fack" "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale"
        "net.ipv4.tcp_moderate_rcvbuf" "net.core.rmem_max" "net.core.wmem_max"
        "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min" "net.core.default_qdisc" "net.ipv4.tcp_congestion_control"
    )
    for p in "${params[@]}"; do
        sed -i "/^$p/d" /etc/sysctl.conf
    done

    # 写入智能调优参数块 (开启 mtu_probing 防丢包)
    cat >> /etc/sysctl.conf << EOF
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=0
net.ipv4.ip_forward=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=$max_buffer
net.core.wmem_max=$max_buffer
net.ipv4.tcp_rmem=4096 $rmem_default $max_buffer
net.ipv4.tcp_wmem=4096 $wmem_default $max_buffer
net.ipv4.udp_rmem_min=4096
net.ipv4.udp_wmem_min=4096
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p
    
    echo -e "${Info} 智能 BBR 调优内核参数已应用。"
    check_bbr_status
}

check_bbr_status() {
    if lsmod | grep -q bbr; then
        echo -e "${Info} BBR 拥塞控制算法已成功启动！"
    else
        echo -e "${Error} 未检测到 BBR 模块。如果是最新版 Ubuntu，BBR 已默认内置，属于正常现象。"
    fi
}

install_fail2ban() {
    echo -e "${Info} 正在安装 Fail2Ban..."
    apt-get update -y
    apt-get install fail2ban -y

    echo -e "\n${Info} 开始配置 SSH 防护参数，请按提示输入（直接回车将使用默认值）："
    
    read -p "请输入 SSH 端口号 [默认: 22]: " ssh_port
    ssh_port=${ssh_port:-22}
    
    read -p "请输入最大尝试次数 (maxretry) [默认: 5]: " max_retry
    max_retry=${max_retry:-5}
    
    read -p "请输入检测周期 (findtime，例如 10m, 1h) [默认: 10m]: " find_time
    find_time=${find_time:-10m}
    
    read -p "请输入封禁时长 (bantime，例如 1h, 1d, -1代表永久) [默认: 1h]: " ban_time
    ban_time=${ban_time:-1h}

    # 将自定义配置写入优先级最高的 jail.local 文件
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = $ban_time
findtime = $find_time
maxretry = $max_retry

[sshd]
enabled = true
port = $ssh_port
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${Info} Fail2Ban 已配置并启动！(端口=$ssh_port, 尝试=$max_retry 次, 周期=$find_time, 封禁=$ban_time)"
}

add_swap() {
    echo -e "${Info} 请输入需要新增的 Swap 虚拟内存大小（单位：MB）。"
    read -p "例如输入 2048 代表 2GB: " swap_size
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 输入有误，请输入纯数字！"
        sleep 2
        manage_swap
        return
    fi

    # 清除可能存在的旧 Swap
    if grep -q "swapfile" /etc/fstab; then
        echo -e "${Info} 检测到已存在 Swap 配置，正在覆盖清理..."
        swapoff /swapfile >/dev/null 2>&1
        sed -i '/swapfile/d' /etc/fstab
        rm -f /swapfile
    fi

    echo -e "${Info} 正在创建 ${swap_size}MB 大小的 Swap 文件，这可能需要几十秒，请稍候..."
    dd if=/dev/zero of=/swapfile bs=1M count=${swap_size} status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 写入 fstab 实现开机自启
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    
    echo -e "${Info} Swap 虚拟内存添加成功！配置已写入 /etc/fstab，重启仍会生效。"
    echo -e "${Info} 当前系统内存状态如下："
    free -m
    echo -e ""
    read -p "按回车键返回上级菜单..."
    manage_swap
}

remove_swap() {
    if grep -q "swapfile" /etc/fstab || [ -f /swapfile ]; then
        echo -e "${Info} 正在关闭并清除 Swap 虚拟内存..."
        swapoff /swapfile >/dev/null 2>&1
        sed -i '/swapfile/d' /etc/fstab
        rm -f /swapfile
        echo -e "${Info} Swap 虚拟内存已成功清除！"
    else
        echo -e "${Error} 系统中未检测到由本脚本创建的 /swapfile 虚拟内存。"
    fi
    echo -e "${Info} 当前系统内存状态如下："
    free -m
    echo -e ""
    read -p "按回车键返回上级菜单..."
    manage_swap
}

manage_swap() {
    clear
    echo -e "#############################################################"
    echo -e "#                 Swap 虚拟内存管理                         #"
    echo -e "#############################################################"
    echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增 Swap 虚拟内存大小 (重启持续生效)"
    echo -e "${Green_font_prefix}2.${Font_color_suffix} 清除 Swap 虚拟内存"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
    echo -e ""
    read -p "请输入选项 [0-2]: " swap_num
    case "$swap_num" in
        1) add_swap ;;
        2) remove_swap ;;
        0) menu ;;
        *) echo -e "${Error} 请输入正确的数字 [0-2]"; sleep 2; manage_swap ;;
    esac
}

menu() {
    clear
    echo -e "#############################################################"
    echo -e "#            Linux 一键安装 BBR 与 Fail2Ban 脚本            #"
    echo -e "#############################################################"
    echo -e "${Green_font_prefix}1.${Font_color_suffix} 应用 BBR 与指定网络内核优化参数 (静态模式)"
    echo -e "${Green_font_prefix}2.${Font_color_suffix} 智能调优 BBR 缓冲区 (针对 iperf3 无丢包定制极速模式)"
    echo -e "${Green_font_prefix}3.${Font_color_suffix} 安装并自定义配置 Fail2Ban (SSH 防爆破)"
    echo -e "${Green_font_prefix}4.${Font_color_suffix} 一键执行: 静态 BBR + 安装 Fail2Ban"
    echo -e "${Green_font_prefix}5.${Font_color_suffix} 一键执行: 智能 BBR + 安装 Fail2Ban"
    echo -e "${Green_font_prefix}6.${Font_color_suffix} Swap 虚拟内存管理"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出脚本"
    echo -e ""
    read -p "请输入选项 [0-6]: " num
    case "$num" in
        1) apply_bbr_and_sysctl ;;
        2) smart_bbr_tuning ;;
        3) install_fail2ban ;;
        4) apply_bbr_and_sysctl; install_fail2ban ;;
        5) smart_bbr_tuning; install_fail2ban ;;
        6) manage_swap ;;
        0) exit 0 ;;
        *) echo -e "${Error} 请输入正确的数字 [0-6]"; sleep 2; menu ;;
    esac
}

menu
