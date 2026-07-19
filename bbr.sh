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
    echo -e "${Info} 开始清理旧的网络配置并应用新参数..."
    
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
    
    echo -e "${Info} 内核参数已应用。"
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
    echo -e "${Info} 请输入需要添加的 Swap 虚拟内存大小 (单位: MB) [例如输入 2048 代表 2G]:"
    read -p "大小(MB): " swap_size
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 输入有误，请输入正整数！"
        sleep 2
        manage_swap
        return
    fi

    echo -e "${Info} 正在创建 ${swap_size}MB 的 Swap 文件，这可能需要一点时间，请稍候..."
    
    # 如果已经存在旧的swap，先清除避免冲突
    if grep -q "/swapfile" /etc/fstab || ls -l /swapfile >/dev/null 2>&1; then
        swapoff /swapfile >/dev/null 2>&1
        rm -f /swapfile
        sed -i '/swapfile/d' /etc/fstab
    fi

    dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 写入 /etc/fstab 保证重启生效
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    echo -e "${Info} Swap 虚拟内存 (大小: ${swap_size}MB) 创建成功，并且重启后将持续生效！"
    
    echo -e "\n按任意键返回上级菜单..."
    read -n 1 -s -r -p ""
    manage_swap
}

clear_swap() {
    echo -e "${Info} 正在清除 Swap 虚拟内存..."
    swapoff /swapfile >/dev/null 2>&1
    rm -f /swapfile
    sed -i '/swapfile/d' /etc/fstab
    echo -e "${Info} Swap 虚拟内存已清除！"
    
    echo -e "\n按任意键返回上级菜单..."
    read -n 1 -s -r -p ""
    manage_swap
}

manage_swap() {
    clear
    echo -e "#############################################################"
    echo -e "#                  Swap 虚拟内存管理                        #"
    echo -e "#############################################################"
    echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增 Swap 虚拟内存"
    echo -e "${Green_font_prefix}2.${Font_color_suffix} 清除 Swap 虚拟内存"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
    echo -e ""
    read -p "请输入选项 [0-2]: " swap_num
    case "$swap_num" in
        1) add_swap ;;
        2) clear_swap ;;
        0) menu ;;
        *) echo -e "${Error} 请输入正确的数字 [0-2]"; sleep 2; manage_swap ;;
    esac
}

menu() {
    clear
    echo -e "#############################################################"
    echo -e "#            Linux 一键安装BBR与Fail2Ban脚本                #"
    echo -e "#############################################################"
    echo -e "${Green_font_prefix}1.${Font_color_suffix} 应用 BBR 与指定网络内核优化参数"
    echo -e "${Green_font_prefix}2.${Font_color_suffix} 安装并自定义配置 Fail2Ban (SSH 防爆破)"
    echo -e "${Green_font_prefix}3.${Font_color_suffix} 一键执行: 应用 BBR + 安装 Fail2Ban"
    echo -e "${Green_font_prefix}4.${Font_color_suffix} swap虚拟内存"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出脚本"
    echo -e ""
    read -p "请输入选项 [0-4]: " num
    case "$num" in
        1) apply_bbr_and_sysctl ;;
        2) install_fail2ban ;;
        3) apply_bbr_and_sysctl; install_fail2ban ;;
        4) manage_swap ;;
        0) exit 0 ;;
        *) echo -e "${Error} 请输入正确的数字 [0-4]"; sleep 2; menu ;;
    esac
}

menu
