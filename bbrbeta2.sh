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
        "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_recovery" "net.core.netdev_max_backlog" "net.core.somaxconn"
        "net.ipv4.tcp_max_syn_backlog"
    )
    for p in "${params[@]}"; do
        sed -i "/^$p/d" /etc/sysctl.conf
    done

    # 针对跨国代理与无 -b 打流防重传优化参数块
    cat >> /etc/sysctl.conf << EOF
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=0
net.ipv4.ip_forward=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_recovery=1
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
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
    
    # 追求无丢包与稳定性：最大缓冲区设置为 BDP 的 2 倍，避免过大 buffer 引发微突发排队重传
    local max_buffer=$(( bdp_bytes * 2 ))
    
    # 设定安全底线，防止由于用户输入太小导致连接断流 (最低8MB)
    if [ "$max_buffer" -lt 8388608 ]; then
        max_buffer=8388608
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
    local rmem_default=87380
    local wmem_default=65536

    echo -e "${Info} 留存 15% 宽带冗余后，计算得出的基础 BDP 为: $bdp_bytes Bytes"
    echo -e "${Info} 动态分配的最大 TCP 缓冲区 为: $max_buffer Bytes"

    local params=(
        "net.ipv4.tcp_no_metrics_save" "net.ipv4.tcp_ecn" "net.ipv4.tcp_frto"
        "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_sack"
        "net.ipv4.tcp_fack" "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale"
        "net.ipv4.tcp_moderate_rcvbuf" "net.core.rmem_max" "net.core.wmem_max"
        "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min" "net.core.default_qdisc" "net.ipv4.tcp_congestion_control"
        "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_recovery" "net.core.netdev_max_backlog" "net.core.somaxconn"
        "net.ipv4.tcp_max_syn_backlog"
    )
    for p in "${params[@]}"; do
        sed -i "/^$p/d" /etc/sysctl.conf
    done

    # 写入智能调优参数块 (开启 mtu_probing 防丢包，配合 notsent_lowat 防打流重传)
    cat >> /etc/sysctl.conf << EOF
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=0
net.ipv4.ip_forward=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_recovery=1
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
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
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == *"bbr"* ]] || lsmod | grep -q bbr; then
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
    echo -e "#                  Swap 虚拟内存管理                        #"
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

install_bbrv3() {
    echo -e "${Info} 开始安装 BBRv3 XanMod 内核..."

    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        echo -e "${Error} XanMod 官方源仅支持 x86_64 架构，当前系统架构为: $arch"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 检查 CPU 支持的微架构级别
    local ld_so=""
    for p in /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2; do
        if [ -f "$p" ]; then
            ld_so="$p"
            break
        fi
    done

    local pkg="linux-xanmod-lts-x64v2"
    if [ -n "$ld_so" ] && $ld_so --help 2>/dev/null | grep -q "x86-64-v3 (supported"; then
        pkg="linux-xanmod-lts-x64v3"
    fi
    echo -e "${Info} 检测到适配的内核版本包为: $pkg"

    # 安装依赖并添加官方软件源
    echo -e "${Info} 正在配置 XanMod 官方源与密钥..."
    apt-get update -y
    apt-get install -y wget gpg ca-certificates
    install -d -m 0755 /etc/apt/keyrings
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org noble main' > /etc/apt/sources.list.d/xanmod-release.list
    apt-get update -y

    # 安装内核
    echo -e "${Info} 正在下载并安装 $pkg 内核，请耐心等待..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
    if [ $? -ne 0 ]; then
        echo -e "${Error} $pkg 安装失败，请检查网络连接或源配置！"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 检查新内核是否已存在于 /boot 中
    if ! ls /boot/vmlinuz*xanmod* >/dev/null 2>&1; then
        echo -e "${Error} 未在 /boot 中检测到 XanMod 内核文件，为防止系统损坏，已中止卸载旧内核操作！"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 卸载旧内核（只保留 xanmod）
    echo -e "${Info} XanMod 内核安装成功，正在清理所有旧内核..."
    local old_kernels=$(dpkg -l | grep -E '^ii[[:space:]]+linux-(image|modules|headers)' | grep -v 'xanmod' | awk '{print $2}')
    if [ -n "$old_kernels" ]; then
        echo -e "${Info} 检测到以下旧内核包，准备清理:"
        echo "$old_kernels"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y $old_kernels
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge
    else
        echo -e "${Info} 未发现需要清理的旧内核。"
    fi

    # 更新 GRUB 引导
    update-grub

    # 应用静态 BBR 与网络优化参数至 /etc/sysctl.conf
    echo -e "${Info} 正在配置 BBRv3 与网络优化参数至 /etc/sysctl.conf..."
    apply_bbr_and_sysctl

    echo -e "\n${Info} BBRv3 XanMod 内核安装与配置已全部完成！系统必须重启才能加载新内核。"
    read -p "是否立即重启服务器？[y/N]: " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo -e "${Info} 正在重启服务器..."
        reboot
    else
        echo -e "${Info} 已取消重启，请稍后手动执行 reboot 生效。"
        read -p "按回车键返回主菜单..."
    fi
}

iperf3_benchmark() {
    clear
    echo -e "#############################################################"
    echo -e "#            iperf3 网络打流测试与重传/流量统计             #"
    echo -e "#    数据源参照: https://iperf3serverlist.net/ 权威测速节点 #"
    echo -e "#############################################################"

    # 依赖检查与安装
    local deps=("iperf3" "curl" "jq" "iputils-ping")
    local need_install=()
    for dep in "${deps[@]}"; do
        local check_bin="$dep"
        [[ "$dep" == "iputils-ping" ]] && check_bin="ping"
        if ! command -v "$check_bin" &>/dev/null; then
            need_install+=("$dep")
        fi
    done

    if [ ${#need_install[@]} -gt 0 ]; then
        echo -e "${Info} 检测到缺失依赖: ${need_install[*]}，正在自动安装..."
        apt-get update -y && apt-get install -y "${need_install[@]}"
    fi

    # 权威免费 iperf3 服务器池
    # 格式: Host|StartPort|EndPort|CountryCode|CountryName|CityName
    local server_pool=(
        "fra.speedtest.clouvider.net|5201|5209|DE|Germany|Frankfurt"
        "speedtest.fra1.de.leaseweb.net|5201|5210|DE|Germany|Frankfurt"
        "a209.speedtest.wobcom.de|5201|5201|DE|Germany|Berlin"
        "ams.speedtest.clouvider.net|5201|5209|NL|Netherlands|Amsterdam"
        "speedtest.ams1.nl.leaseweb.net|5201|5210|NL|Netherlands|Amsterdam"
        "par.speedtest.clouvider.net|5201|5209|FR|France|Paris"
        "ping.online.net|5201|5209|FR|France|Paris"
        "lon.speedtest.clouvider.net|5201|5209|GB|United Kingdom|London"
        "speedtest.lon1.gb.leaseweb.net|5201|5210|GB|United Kingdom|London"
        "speedsrv.multinet24.pl|5301|5310|PL|Poland|Debica"
        "speedtest.vno1.lt.leaseweb.net|5201|5210|LT|Lithuania|Vilnius"
        "la.speedtest.clouvider.net|5200|5209|US|United States|Los Angeles"
        "speedtest.lax12.us.leaseweb.net|5201|5209|US|United States|Los Angeles"
        "nyc.speedtest.clouvider.net|5201|5209|US|United States|New York"
        "dal.speedtest.clouvider.net|5201|5209|US|United States|Dallas"
        "speedtest.masnet.ec|5201|5209|EC|Ecuador|Santa Ana"
        "akl.linetest.nz|5301|5309|NZ|New Zealand|Auckland"
        "speedtest.tyo11.jp.leaseweb.net|5201|5210|JP|Japan|Tokyo"
        "sgp.proof.ovh.net|5201|5209|SG|Singapore|Singapore"
        "speedtest.sin1.sg.leaseweb.net|5201|5209|SG|Singapore|Singapore"
        "speedtest.hkg12.hk.leaseweb.net|5201|5210|HK|Hong Kong|Hong Kong"
        "189.25.98.63|30001|30009|TW|TaiPei|TaiWan"
    )

    echo -e "${Info} 正在检测本地 IP 地理位置信息..."
    local ip_json
    ip_json=$(curl -s --connect-timeout 4 http://ip-api.com/json 2>/dev/null)
    local local_country=$(echo "$ip_json" | jq -r '.countryCode // empty' 2>/dev/null)
    local local_country_name=$(echo "$ip_json" | jq -r '.country // empty' 2>/dev/null)
    local local_city=$(echo "$ip_json" | jq -r '.city // empty' 2>/dev/null)

    if [[ -n "$local_country" ]]; then
        echo -e "${Info} 本机定位: ${Green_font_prefix}${local_country_name:-未知} - ${local_city:-未知} (${local_country})${Font_color_suffix}"
    else
        echo -e "${Info} 未能自动获取准确位置，将直接通过全网延迟测速排序。"
    fi

    # 测试参数设置
    echo -e ""
    echo -e "--- 测试参数设置 ---"
    read -p "是否需要开启 8 线程打流？[y/N] (默认: N 单线程): " multi_choice
    local threads=1
    if [[ "$multi_choice" =~ ^[Yy]$ ]]; then
        threads=8
        echo -e "${Info} 已设置为: 8 线程并发打流"
    else
        echo -e "${Info} 已设置为: 单线程打流"
    fi

    read -p "是否增加 UDP 打流测试？[y/N] (默认: N 仅测试 TCP): " udp_choice
    local test_udp=0
    if [[ "$udp_choice" =~ ^[Yy]$ ]]; then
        test_udp=1
        echo -e "${Info} 已启用: TCP + UDP 打流测试"
    else
        echo -e "${Info} 已设置为: 仅进行 TCP 打流测试"
    fi

    read -p "请输入单项打流测试时长 (秒) [默认: 10]: " test_duration
    test_duration=${test_duration:-10}

    echo -e ""
    echo -e "--- 选择 iperf3 服务器 ---"
    echo -e "1. 自动智能选择（优先匹配本土/同城，若全端口繁忙则自动顺延切换下一个最优节点）"
    echo -e "2. 手动在预置服务器列表中选择"
    echo -e "3. 手动输入自定义 iperf3 服务器地址与起始端口"
    read -p "请输入选择 [1-3, 默认 1]: " server_mode
    server_mode=${server_mode:-1}

    local target_servers=()

    if [ "$server_mode" == "2" ]; then
        echo -e "\n可选服务器列表："
        local i=1
        for s in "${server_pool[@]}"; do
            IFS='|' read -r h sp ep cc cn ct <<< "$s"
            printf "${Green_font_prefix}%2d.${Font_color_suffix} [%s - %-10s] %-34s (端口: %s-%s)\n" "$i" "$cc" "$ct" "$h" "$sp" "$ep"
            i=$((i + 1))
        done
        read -p "请选择服务器序号 [1-${#server_pool[@]}]: " s_idx
        if [[ "$s_idx" =~ ^[0-9]+$ ]] && [ "$s_idx" -ge 1 ] && [ "$s_idx" -le "${#server_pool[@]}" ]; then
            target_servers+=("${server_pool[$((s_idx - 1))]}")
        else
            echo -e "${Error} 输入有误，默认切换至自动选择！"
            server_mode=1
        fi
    elif [ "$server_mode" == "3" ]; then
        read -p "请输入 iperf3 服务器域名或 IP: " custom_host
        read -p "请输入起始端口 [默认: 5201]: " custom_sp
        custom_sp=${custom_sp:-5201}
        read -p "请输入最大后备尝试端口 [默认: $((custom_sp + 8))]: " custom_ep
        custom_ep=${custom_ep:-$((custom_sp + 8))}
        target_servers+=("${custom_host}|${custom_sp}|${custom_ep}|CUSTOM|自定义|服务器")
    fi

    # 自动模式：构建有序候选服务器队列
    if [ "$server_mode" == "1" ]; then
        echo -e "${Info} 正在自动对可用节点进行延迟探测与优先级排序..."
        local city_matches=()
        local country_matches=()
        local other_matches=()

        for s in "${server_pool[@]}"; do
            IFS='|' read -r h sp ep cc cn ct <<< "$s"
            local ping_res
            ping_res=$(ping -c 2 -W 1 "$h" 2>/dev/null | awk -F'/' 'END{print $5}')
            local lat_int=9999
            if [[ -n "$ping_res" ]]; then
                lat_int=${ping_res%.*}
                [[ -z "$lat_int" ]] && lat_int=9999
                echo -e "   - 探测节点: ${cn} - ${ct} ($h) 延迟: ${ping_res} ms"
            else
                echo -e "   - 探测节点: ${cn} - ${ct} ($h) Ping 超时 (作为备用候选)"
            fi

            # 存储格式: latency_int|full_record
            if [[ -n "$local_country" && "${cc,,}" == "${local_country,,}" ]]; then
                if [[ -n "$local_city" && "${ct,,}" =~ "${local_city,,}" ]]; then
                    city_matches+=("${lat_int}|${s}")
                else
                    country_matches+=("${lat_int}|${s}")
                fi
            else
                other_matches+=("${lat_int}|${s}")
            fi
        done

        # 排序函数：按延迟数字升序
        sort_by_latency() {
            for item in "$@"; do
                echo "$item"
            done | sort -t'|' -k1 -n | cut -d'|' -f2-
        }

        # 依次加载同城优先、同国次之、其他临近兜底
        if [ ${#city_matches[@]} -gt 0 ]; then
            while IFS= read -r line; do [[ -n "$line" ]] && target_servers+=("$line"); done < <(sort_by_latency "${city_matches[@]}")
        fi
        if [ ${#country_matches[@]} -gt 0 ]; then
            while IFS= read -r line; do [[ -n "$line" ]] && target_servers+=("$line"); done < <(sort_by_latency "${country_matches[@]}")
        fi
        if [ ${#other_matches[@]} -gt 0 ]; then
            while IFS= read -r line; do [[ -n "$line" ]] && target_servers+=("$line"); done < <(sort_by_latency "${other_matches[@]}")
        fi

        echo -e "${Info} 已自动优选出 ${Green_font_prefix}${#target_servers[@]}${Font_color_suffix} 个备用打流服务器队列。"
    fi

    local tmp_json="/tmp/iperf3_res_$$.json"
    local active_host=""
    local active_port=""
    local active_location=""
    local up_bytes=0
    local up_retrans=0
    local up_bps=0
    local down_bytes=0
    local down_retrans=0
    local down_bps=0
    local udp_up_bytes=0
    local udp_up_loss="0%"
    local udp_down_bytes=0
    local udp_down_loss="0%"

    # 尝试在特定服务器上运行打流 (包含端口递增机制)
    # 参数: $1: host, $2: start_port, $3: end_port, $4: direction (up/down), $5: proto (tcp/udp), $6: locked_port (可选)
    execute_stream() {
        local h="$1"
        local sp="$2"
        local ep="$3"
        local dir="$4"
        local proto="$5"
        local forced_port="$6"

        [[ -z "$ep" || "$ep" -lt "$sp" ]] && ep=$((sp + 8))

        local p_list=()
        if [[ -n "$forced_port" && "$forced_port" =~ ^[0-9]+$ ]]; then
            p_list=("$forced_port")
        else
            for ((p=sp; p<=ep; p++)); do
                p_list+=("$p")
            done
        fi

        for curr_port in "${p_list[@]}"; do
            echo -e "${Info} 正在向 [${h}:${Green_font_prefix}${curr_port}${Font_color_suffix}] 发起 ${proto^^} ${dir^^} 打流..."
            rm -f "$tmp_json"

            local cmd=("iperf3" "-c" "$h" "-p" "$curr_port" "-t" "$test_duration" "-J")
            if [ "$dir" == "down" ]; then
                cmd+=("-R")
            fi
            if [ "$proto" == "udp" ]; then
                cmd+=("-u" "-b" "0")
            fi
            if [ "$threads" -gt 1 ]; then
                cmd+=("-P" "$threads")
            fi

            # 执行打流并将标准输出与错误完全隔离重定向至临时文件，保证终端不被吞噬
            "${cmd[@]}" > "$tmp_json" 2>&1

            # 检测是否成功产生合法的 .end 报告
            if jq -e '.end' "$tmp_json" >/dev/null 2>&1; then
                export LAST_ACTIVE_PORT="$curr_port"
                return 0
            fi

            # 抓取错误特征
            local err_msg
            err_msg=$(jq -r '.error // empty' "$tmp_json" 2>/dev/null)
            [[ -z "$err_msg" ]] && err_msg=$(head -n 2 "$tmp_json" | tr '\n' ' ')

            if echo "$err_msg" | grep -qiE "busy|try again|unable to connect|refused|interrupt|broken pipe"; then
                echo -e "${Error} 端口 $curr_port 繁忙或被他人占用 (${err_msg})，自动尝试后一位端口..."
            else
                echo -e "${Error} 端口 $curr_port 连接异常 (${err_msg})，尝试后一位端口..."
            fi
            sleep 1
        done

        return 1
    }

    echo -e "\n==================== 开始执行打流测试 ===================="
    local test_passed=0

    # 服务器级故障转移主循环
    for srv in "${target_servers[@]}"; do
        IFS='|' read -r s_host s_sp s_ep _ s_cn s_ct <<< "$srv"
        echo -e "\n${Info} 当前选定服务器: ${Green_font_prefix}${s_host}${Font_color_suffix} (${s_cn} - ${s_ct})"

        # 1. 尝试 TCP 上传打流
        echo -e "${Info} [1/2] 正在进行 TCP 【上传】打流测试..."
        if ! execute_stream "$s_host" "$s_sp" "$s_ep" "up" "tcp"; then
            echo -e "${Error} 服务器 [${s_host}] 所有测试端口均繁忙或无法连接，正在自动切换至下一个最优服务器..."
            continue
        fi

        local current_succ_port="$LAST_ACTIVE_PORT"

        # 解析上传数据
        up_bytes=$(jq -r '(.end.sum_sent.bytes // .end.sum.bytes // 0)' "$tmp_json" 2>/dev/null)
        up_retrans=$(jq -r '(.end.sum_sent.retransmits // .end.sum.retransmits // 0)' "$tmp_json" 2>/dev/null)
        up_bps=$(jq -r '(.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0)' "$tmp_json" 2>/dev/null)
        [[ -z "$up_retrans" || "$up_retrans" == "null" ]] && up_retrans=0

        # 2. 尝试 TCP 下载打流 (Reverse 模式)
        echo -e "${Info} [2/2] 正在进行 TCP 【下载】打流测试 (Reverse 模式)..."
        # 优先使用刚刚上传成功的端口，若遇突发繁忙则在全端口段顺延
        if ! execute_stream "$s_host" "$s_sp" "$s_ep" "down" "tcp" "$current_succ_port"; then
            echo -e "${Error} 下载端口被占用，尝试在该服务器全范围端口重新握手..."
            if ! execute_stream "$s_host" "$s_sp" "$s_ep" "down" "tcp"; then
                echo -e "${Error} 服务器 [${s_host}] 下载阶段异常，自动切换至下一个最优服务器重新开始..."
                continue
            fi
        fi

        # 解析下载数据
        down_bytes=$(jq -r '(.end.sum_received.bytes // .end.sum.bytes // 0)' "$tmp_json" 2>/dev/null)
        down_retrans=$(jq -r '(.end.sum_sent.retransmits // .end.sum.retransmits // 0)' "$tmp_json" 2>/dev/null)
        down_bps=$(jq -r '(.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0)' "$tmp_json" 2>/dev/null)
        [[ -z "$down_retrans" || "$down_retrans" == "null" ]] && down_retrans=0

        # 3. 可选 UDP 测试
        if [ "$test_udp" -eq 1 ]; then
            echo -e "\n${Info} 正在进行 UDP 【上传】打流测试..."
            if execute_stream "$s_host" "$s_sp" "$s_ep" "up" "udp" "$current_succ_port"; then
                udp_up_bytes=$(jq -r '(.end.sum.bytes // 0)' "$tmp_json" 2>/dev/null)
                local loss_val
                loss_val=$(jq -r '(.end.sum.lost_percent // 0)' "$tmp_json" 2>/dev/null)
                udp_up_loss=$(awk -v l="$loss_val" 'BEGIN{printf "%.2f%%", l}')
            fi

            echo -e "${Info} 正在进行 UDP 【下载】打流测试..."
            if execute_stream "$s_host" "$s_sp" "$s_ep" "down" "udp" "$current_succ_port"; then
                udp_down_bytes=$(jq -r '(.end.sum.bytes // 0)' "$tmp_json" 2>/dev/null)
                local loss_val2
                loss_val2=$(jq -r '(.end.sum.lost_percent // 0)' "$tmp_json" 2>/dev/null)
                udp_down_loss=$(awk -v l="$loss_val2" 'BEGIN{printf "%.2f%%", l}')
            fi
        fi

        # 测试全部成功，记录节点信息并跳出
        active_host="$s_host"
        active_port="$current_succ_port"
        active_location="${s_cn} - ${s_ct}"
        test_passed=1
        break
    done

    rm -f "$tmp_json"

    if [ "$test_passed" -ne 1 ]; then
        echo -e "\n${Error} 所有候选服务器均不可用或被他人占用，测试中止！"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 计算流量数值转换 (GB 与 Mbps)
    [[ -z "$up_bytes" || "$up_bytes" == "null" ]] && up_bytes=0
    [[ -z "$down_bytes" || "$down_bytes" == "null" ]] && down_bytes=0
    [[ -z "$up_bps" || "$up_bps" == "null" ]] && up_bps=0
    [[ -z "$down_bps" || "$down_bps" == "null" ]] && down_bps=0

    local up_gb=$(awk -v b="$up_bytes" 'BEGIN{printf "%.4f", b / 1073741824}')
    local up_mbps=$(awk -v b="$up_bps" 'BEGIN{printf "%.2f", b / 1000000}')
    local down_gb=$(awk -v b="$down_bytes" 'BEGIN{printf "%.4f", b / 1073741824}')
    local down_mbps=$(awk -v b="$down_bps" 'BEGIN{printf "%.2f", b / 1000000}')

    # 展示测试报告
    echo -e "\n#############################################################"
    echo -e "#                  iperf3 打流测试报告统计                  #"
    echo -e "#############################################################"
    echo -e " 目标节点       : ${Green_font_prefix}${active_host}${Font_color_suffix} (${active_location})"
    echo -e " 成功通讯端口   : ${Green_font_prefix}${active_port}${Font_color_suffix}"
    echo -e " 测试模式       : TCP $([ "$threads" -gt 1 ] && echo "8 线程" || echo "单线程") | 时长: ${test_duration}s"
    echo -e "-------------------------------------------------------------"
    echo -e " 【上传测试结果】 (Client -> Server):"
    echo -e "   - 消耗上传流量 : ${Green_font_prefix}${up_gb} GB${Font_color_suffix} (${up_bytes} Bytes)"
    echo -e "   - 上传重传总数 : ${Green_font_prefix}${up_retrans}${Font_color_suffix} 次 (Retransmits)"
    echo -e "   - 平均上传速度 : ${Green_font_prefix}${up_mbps} Mbps${Font_color_suffix}"
    echo -e "-------------------------------------------------------------"
    echo -e " 【下载测试结果】 (Server -> Client):"
    echo -e "   - 消耗下载流量 : ${Green_font_prefix}${down_gb} GB${Font_color_suffix} (${down_bytes} Bytes)"
    echo -e "   - 下载重传总数 : ${Green_font_prefix}${down_retrans}${Font_color_suffix} 次 (Retransmits)"
    echo -e "   - 平均下载速度 : ${Green_font_prefix}${down_mbps} Mbps${Font_color_suffix}"
    
    if [ "$test_udp" -eq 1 ]; then
        local udp_up_gb=$(awk -v b="$udp_up_bytes" 'BEGIN{printf "%.4f", b / 1073741824}')
        local udp_down_gb=$(awk -v b="$udp_down_bytes" 'BEGIN{printf "%.4f", b / 1073741824}')
        echo -e "-------------------------------------------------------------"
        echo -e " 【UDP 打流结果】:"
        echo -e "   - UDP 上传流量 : ${udp_up_gb} GB | 丢包率: ${udp_up_loss}"
        echo -e "   - UDP 下载流量 : ${udp_down_gb} GB | 丢包率: ${udp_down_loss}"
    fi
    echo -e "#############################################################\n"

    read -p "按回车键返回主菜单..."
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
    echo -e "${Green_font_prefix}7.${Font_color_suffix} 安装 BBRv3 (XanMod 内核并清理旧内核)"
    echo -e "${Green_font_prefix}8.${Font_color_suffix} iperf3 打流测试 (自动就近本土/防占用自动换端口/统计流量与重传)"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出脚本"
    echo -e ""
    read -p "请输入选项 [0-8]: " num
    case "$num" in
        1) apply_bbr_and_sysctl ;;
        2) smart_bbr_tuning ;;
        3) install_fail2ban ;;
        4) apply_bbr_and_sysctl; install_fail2ban ;;
        5) smart_bbr_tuning; install_fail2ban ;;
        6) manage_swap ;;
        7) install_bbrv3 ;;
        8) iperf3_benchmark ;;
        0) exit 0 ;;
        *) echo -e "${Error} 请输入正确的数字 [0-8]"; sleep 2; menu ;;
    esac
}

menu
