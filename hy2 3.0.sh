#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

[[ $EUID -ne 0 ]] && red "错误: 请在 root 用户下运行本脚本！" && exit 1

# 系统检测及包管理器判定
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon linux" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "目前暂不支持你的系统！" && exit 1

# 动态识别官方服务名（兼容模板服务与独立服务）
get_service_name(){
    if systemctl list-unit-files 2>/dev/null | grep -q "hysteria-server@"; then
        SERVICE_NAME="hysteria-server@config"
    elif [[ -f /etc/systemd/system/hysteria-server@.service || -f /lib/systemd/system/hysteria-server@.service ]]; then
        SERVICE_NAME="hysteria-server@config"
    else
        SERVICE_NAME="hysteria-server"
    fi
}

# 多接口轮询与本地网卡回退，彻底解决 IP 为空问题
realip(){
    ip=""
    ip=$(curl -s4m5 https://api.ipify.org 2>/dev/null) || \
    ip=$(curl -s4m5 https://ip.sb 2>/dev/null) || \
    ip=$(curl -s4m5 https://ifconfig.me 2>/dev/null) || \
    ip=$(curl -s6m5 https://api64.ipify.org 2>/dev/null) || \
    ip=$(curl -s6m5 https://ip.sb 2>/dev/null)

    if [[ -z $ip ]]; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7}')
    fi
    if [[ -z $ip ]]; then
        ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{print $7}')
    fi

    if [[ -z $ip ]]; then
        red "无法自动获取外网 IP 地址！"
        read -rp "请手动输入此 VPS 的公网 IP 地址: " ip
        while [[ -z $ip ]]; do
            read -rp "IP 不能为空，请重新输入: " ip
        done
    fi
    green "当前识别到的公网 IP: $ip"
}

# 内核 UDP 缓冲区及 BBR 调优
tune_sysctl(){
    cat > /etc/sysctl.d/99-hy2.conf << EOF
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl --system >/dev/null 2>&1
}

# 防火墙持久化保存
save_iptables(){
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/sysconfig
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
        ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null
    fi
}

clean_jump_iptables(){
    iptables -t nat -S PREROUTING 2>/dev/null | grep 'HY2_JUMP' | while read -r line; do
        rule="${line#-A }"
        iptables -t nat -D $rule 2>/dev/null
    done
    ip6tables -t nat -S PREROUTING 2>/dev/null | grep 'HY2_JUMP' | while read -r line; do
        rule="${line#-A }"
        ip6tables -t nat -D $rule 2>/dev/null
    done
    save_iptables
}

fix_permissions(){
    if id "hysteria" &>/dev/null; then
        chown -R hysteria:hysteria /etc/hysteria 2>/dev/null
    fi
    chmod 755 /etc/hysteria
    chmod 644 /etc/hysteria/config.yaml 2>/dev/null
    chmod 644 "$cert_path" 2>/dev/null
    chmod 644 "$key_path" 2>/dev/null
}

inst_cert(){
    green "Hysteria 2 协议证书申请方式："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 必应自签证书 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} Acme 脚本自动申请"
    echo -e " ${GREEN}3.${PLAIN} 自定义证书路径"
    echo ""
    read -rp "请输入选项 [1-3]: " certInput
    mkdir -p /etc/hysteria

    if [[ $certInput == 2 ]]; then
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"

        if [[ -f /etc/hysteria/cert.crt && -f /etc/hysteria/private.key ]] && [[ -s /etc/hysteria/cert.crt && -s /etc/hysteria/private.key ]] && [[ -f /etc/hysteria/ca.log ]]; then
            domain=$(cat /etc/hysteria/ca.log)
            green "检测到原有域名：$domain 的证书，正在应用"
            hy_domain=$domain
        else
            realip
            read -rp "请输入需要申请证书的域名：" domain
            [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
            green "已输入的域名：$domain" && sleep 1
            domainIP=$(curl -sm8 https://ipget.net/?ip="${domain}")
            if [[ $domainIP == $ip ]]; then
                ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl
                if [[ $SYSTEM == "CentOS" ]]; then
                    ${PACKAGE_INSTALL[int]} cronie
                    systemctl start crond && systemctl enable crond
                else
                    ${PACKAGE_INSTALL[int]} cron
                    systemctl start cron && systemctl enable cron
                fi
                curl https://get.acme.sh | sh -s email="$(date +%s%N | md5sum | cut -c 1-16)@gmail.com"
                bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                if [[ $ip =~ : ]]; then
                    bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
                else
                    bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure
                fi
                bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc
                if [[ -f $cert_path && -f $key_path && -s $cert_path && -s $key_path ]]; then
                    echo "$domain" > /etc/hysteria/ca.log
                    green "证书申请成功并安装至 /etc/hysteria/"
                    hy_domain=$domain
                else
                    red "证书申请失败，请排查端口 80 是否开放或被占用！" && exit 1
                fi
            else
                red "解析 IP ($domainIP) 与当前 VPS 真实 IP ($ip) 不匹配！"
                exit 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -rp "请输入公钥文件 crt 的路径：" cert_path
        read -rp "请输入私钥文件 key 的路径：" key_path
        read -rp "请输入证书绑定的域名 (SNI)：" domain
        hy_domain=$domain
    else
        green "使用必应自签证书"
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port(){
    read -rp "设置 Hysteria 2 主端口 [1-65535]（回车随机）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        red "端口 $port 已被占用，请更换！"
        read -rp "设置 Hysteria 2 主端口 [1-65535]（回车随机）：" port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    done
    yellow "主端口确认为：$port"
    inst_jump
}

inst_jump(){
    green "端口模式："
    echo -e " ${GREEN}1.${PLAIN} 单端口 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 端口跳跃"
    echo ""
    read -rp "请输入选项 [1-2]: " jumpInput
    clean_jump_iptables
    if [[ $jumpInput == 2 ]]; then
        while true; do
            read -rp "起始端口 (10000-65535): " firstport
            read -rp "末尾端口 (需大于起始端口): " endport
            if [[ $firstport -lt $endport && $firstport -ge 1 && $endport -le 65535 ]]; then
                break
            fi
            red "端口范围不合规，请重新输入！"
        done
        iptables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -m comment --comment "HY2_JUMP" -j DNAT --to-destination ":$port"
        ip6tables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -m comment --comment "HY2_JUMP" -j DNAT --to-destination ":$port" 2>/dev/null
        save_iptables
    else
        firstport=""
        endport=""
        yellow "使用单端口模式"
    fi
}

inst_pwd(){
    read -rp "设置 Hysteria 2 密码（回车随机）：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-12)
    yellow "密码为：$auth_pwd"
}

inst_site(){
    read -rp "设置伪装网站（去除 https://）[默认: en.snu.ac.kr]：" proxysite
    [[ -z $proxysite ]] && proxysite="en.snu.ac.kr"
    yellow "伪装网站为：$proxysite"
}

write_client_files(){
    [[ -z $ip ]] && realip
    mkdir -p /root/hy
    local final_ip="$ip"
    [[ $final_ip =~ : ]] && final_ip="[$ip]"

    if [[ -n $firstport && -n $endport ]]; then
        last_port="$port,$firstport-$endport"
    else
        last_port="$port"
    fi

    # 客户端 YAML
    cat << EOF > /root/hy/hy-client.yaml
server: $final_ip:$last_port

auth: $auth_pwd

tls:
  sni: $hy_domain
  insecure: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

fastOpen: true

socks5:
  listen: 127.0.0.1:5678

transport:
  udp:
    hopInterval: 30s
EOF

    # 客户端 JSON
    cat << EOF > /root/hy/hy-client.json
{
  "server": "$final_ip:$last_port",
  "auth": "$auth_pwd",
  "tls": {
    "sni": "$hy_domain",
    "insecure": true
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  },
  "transport": {
    "udp": {
      "hopInterval": "30s"
    }
  }
}
EOF

    # 节点链接
    echo "hysteria2://$auth_pwd@$final_ip:$last_port/?insecure=1&sni=$hy_domain#Hysteria2-Node" > /root/hy/url.txt
}

insthysteria(){
    realip
    tune_sysctl

    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo procps iptables iptables-persistent netfilter-persistent 2>/dev/null || ${PACKAGE_INSTALL[int]} curl wget sudo procps iptables

    # 安装官方 Hysteria 核心
    bash <(curl -fsSL https://get.hy2.sh/)

    if ! command -v hysteria &>/dev/null; then
        red "Hysteria 2 安装失败，请检查网络或官方脚本源！" && exit 1
    fi
    green "Hysteria 2 核心安装完成！"

    inst_cert
    inst_port
    inst_pwd
    inst_site

    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: $auth_pwd

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF

    fix_permissions
    write_client_files

    systemctl daemon-reload
    get_service_name

    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        green "Hysteria 2 服务启动成功！"
    else
        red "Hysteria 2 启动失败！"
        yellow "调试信息: 正在测试配置文件..."
        hysteria server -c /etc/hysteria/config.yaml
        red "请根据上方报错信息排查，脚本退出。"
        exit 1
    fi

    showconf
}

unsthysteria(){
    get_service_name
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria /root/hy /etc/sysctl.d/99-hy2.conf
    clean_jump_iptables
    green "Hysteria 2 与相关配置文件已完全卸载！"
}

starthysteria(){
    get_service_name
    systemctl start "$SERVICE_NAME"
    green "Hysteria 2 已启动！"
}

stophysteria(){
    get_service_name
    systemctl stop "$SERVICE_NAME"
    yellow "Hysteria 2 已停止！"
}

restarthysteria(){
    get_service_name
    systemctl restart "$SERVICE_NAME"
    green "Hysteria 2 重启完成！"
}

hysteriaswitch(){
    yellow "控制面板："
    echo -e " ${GREEN}1.${PLAIN} 启动"
    echo -e " ${GREEN}2.${PLAIN} 停止"
    echo -e " ${GREEN}3.${PLAIN} 重启"
    echo ""
    read -rp "请选择 [1-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) restarthysteria ;;
        * ) exit 1 ;;
    esac
}

read_current_config(){
    port=$(grep -E '^[[:space:]]*listen:' /etc/hysteria/config.yaml | awk '{print $2}' | sed 's/://g')
    auth_pwd=$(grep -E '^[[:space:]]*password:' /etc/hysteria/config.yaml | awk '{print $2}')
    cert_path=$(grep -E '^[[:space:]]*cert:' /etc/hysteria/config.yaml | awk '{print $2}')
    key_path=$(grep -E '^[[:space:]]*key:' /etc/hysteria/config.yaml | awk '{print $2}')
    proxysite=$(grep -E '^[[:space:]]*url:' /etc/hysteria/config.yaml | awk '{print $2}' | sed 's#https://##')
    hy_domain=$(grep -E '^[[:space:]]*sni:' /root/hy/hy-client.yaml | awk '{print $2}')
}

changeport(){
    read_current_config
    inst_port
    sed -i "s|^[[:space:]]*listen:.*|listen: :$port|" /etc/hysteria/config.yaml
    write_client_files
    restarthysteria
    showconf
}

changepasswd(){
    read_current_config
    inst_pwd
    sed -i "s|^[[:space:]]*password:.*|  password: $auth_pwd|" /etc/hysteria/config.yaml
    write_client_files
    restarthysteria
    showconf
}

change_cert(){
    read_current_config
    inst_cert
    sed -i "s|^[[:space:]]*cert:.*|  cert: $cert_path|" /etc/hysteria/config.yaml
    sed -i "s|^[[:space:]]*key:.*|  key: $key_path|" /etc/hysteria/config.yaml
    fix_permissions
    write_client_files
    restarthysteria
    showconf
}

changeproxysite(){
    read_current_config
    inst_site
    sed -i "s|^[[:space:]]*url:.*|    url: https://$proxysite|" /etc/hysteria/config.yaml
    restarthysteria
    green "伪装域名修改完成！"
}

changeconf(){
    [[ ! -f /etc/hysteria/config.yaml ]] && red "未检测到配置文件，请先安装！" && return
    green "配置修改："
    echo -e " ${GREEN}1.${PLAIN} 修改监听端口 / 端口跳跃"
    echo -e " ${GREEN}2.${PLAIN} 修改认证密码"
    echo -e " ${GREEN}3.${PLAIN} 重新申请或更换证书"
    echo -e " ${GREEN}4.${PLAIN} 修改伪装网站"
    echo ""
    read -rp "请选择 [1-4]: " confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changepasswd ;;
        3 ) change_cert ;;
        4 ) changeproxysite ;;
        * ) exit 1 ;;
    esac
}

showconf(){
    [[ ! -f /root/hy/url.txt ]] && red "未找到客户端配置文件，请确认是否已完成安装！" && return
    echo ""
    echo -e "=================================================================="
    green "Hysteria 2 配置信息"
    echo -e "=================================================================="
    yellow "客户端 YAML 配置路径: /root/hy/hy-client.yaml"
    red "$(cat /root/hy/hy-client.yaml)"
    echo -e "------------------------------------------------------------------"
    yellow "客户端 JSON 配置路径: /root/hy/hy-client.json"
    red "$(cat /root/hy/hy-client.json)"
    echo -e "------------------------------------------------------------------"
    yellow "节点分享链接路径: /root/hy/url.txt"
    green "$(cat /root/hy/url.txt)"
    echo -e "=================================================================="
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                  ${GREEN}Hysteria 2 管理脚本 (最终版)${PLAIN}             #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装 Hysteria 2"
    echo -e " ${RED}2.${PLAIN} 卸载 Hysteria 2"
    echo " ------------------------------------------------------------"
    echo -e " 3. 服务控制 (启动/停止/重启)"
    echo -e " 4. 修改配置 (端口/密码/证书/伪装)"
    echo -e " 5. 查看配置与连接信息"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-5]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        * ) exit 0 ;;
    esac
}

menu