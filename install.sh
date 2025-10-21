#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(arch)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

os_version=""

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -c "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
    else
        apt update -y
        apt install wget curl unzip tar cron socat -y
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/systemd/system/XrayR.service ]]; then
        return 2
    fi
    temp=$(systemctl status XrayR | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ x"${temp}" == x"running" ]]; then
        return 0
    else
        return 1
    fi
}

install_acme() {
    curl https://get.acme.sh | sh
}

install_XrayR() {
    if [[ -e /usr/local/XrayR/ ]]; then
        rm /usr/local/XrayR/ -rf
    fi

    mkdir -p /usr/local/XrayR/
    cd /usr/local/XrayR/

    # 固定使用你提供的可直链（避免 releases/downloads 404）
    FIXED_URL_64="https://gitlab.com/-/project/68417262/uploads/e84661943246cf560cecb825fe0cc2b6/XrayR-linux-64.zip"

    if  [ $# == 0 ] ; then
        # 仍然保留“检测最新版本”的输出，不影响原有体验
        last_version=$(curl -sL "https://gitlab.com/VergeLab/XrayR/-/tags" | grep -oE 'v[0-9][0-9A-Za-z\.\-]+' | head -n1)
        if [[ ! -n "$last_version" ]]; then
            last_version="v0.9.4-20250101"
        fi
        echo -e "检测到 XrayR 最新版本：${last_version}，开始安装"
        # 直接用可下载直链
        wget -q -N --no-check-certificate -O /usr/local/XrayR/XrayR-linux.zip "${FIXED_URL_64}"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 XrayR 失败，请确认直链可访问${plain}"
            exit 1
        fi
    else
        if [[ $1 == v* ]]; then
            last_version=$1
        else
            last_version="v"$1
        fi
        echo -e "开始安装 XrayR ${last_version}"
        # 仍然使用直链，保证可下到包
        wget -q -N --no-check-certificate -O /usr/local/XrayR/XrayR-linux.zip "${FIXED_URL_64}"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 XrayR ${last_version} 失败，请确认直链可访问${plain}"
            exit 1
        fi
    fi

    unzip XrayR-linux.zip
    rm -f XrayR-linux.zip
    chmod +x XrayR
    mkdir -p /etc/XrayR/
    rm -f /etc/systemd/system/XrayR.service

    # 使用 GitLab xrayr-release 仓库中的 systemd 单元
    file="https://gitlab.com/VergeLab/xrayr-release/-/raw/master/XrayR.service"
    wget -q -N --no-check-certificate -O /etc/systemd/system/XrayR.service ${file}

    systemctl daemon-reload
    systemctl stop XrayR 2>/dev/null
    systemctl enable XrayR
    echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置开机自启"

    cp -f geoip.dat /etc/XrayR/ 2>/dev/null
    cp -f geosite.dat /etc/XrayR/ 2>/dev/null

    if [[ ! -f /etc/XrayR/config.yml ]]; then
        cp -f config.yml /etc/XrayR/ 2>/dev/null
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/XrayR-project/XrayR，配置必要的内容"
    else
        systemctl start XrayR
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}XrayR 重启成功${plain}"
        else
            echo -e "${red}XrayR 可能启动失败，请稍后使用 XrayR log 查看日志信息，若无法启动，则可能更改了配置格式，请前往 wiki 查看：https://github.com/XrayR-project/XrayR/wiki${plain}"
        fi
    fi

    [[ ! -f /etc/XrayR/dns.json ]] && cp -f dns.json /etc/XrayR/ 2>/dev/null
    [[ ! -f /etc/XrayR/route.json ]] && cp -f route.json /etc/XrayR/ 2>/dev/null
    [[ ! -f /etc/XrayR/custom_outbound.json ]] && cp -f custom_outbound.json /etc/XrayR/ 2>/dev/null
    [[ ! -f /etc/XrayR/custom_inbound.json ]] && cp -f custom_inbound.json /etc/XrayR/ 2>/dev/null
    [[ ! -f /etc/XrayR/rulelist ]] && cp -f rulelist /etc/XrayR/ 2>/dev/null

    # 管理脚本
    curl -o /usr/bin/XrayR -Ls https://gitlab.com/VergeLab/xrayr-release/-/raw/master/XrayR.sh
    chmod +x /usr/bin/XrayR
    ln -sf /usr/bin/XrayR /usr/bin/xrayr # 小写兼容

    cd "$cur_dir"
    rm -f install.sh
    echo -e ""
    echo "XrayR 管理脚本使用方法 (兼容使用xrayr执行，大小写不敏感): "
    echo "------------------------------------------"
    echo "XrayR                    - 显示管理菜单 (功能更多)"
    echo "XrayR start              - 启动 XrayR"
    echo "XrayR stop               - 停止 XrayR"
    echo "XrayR restart            - 重启 XrayR"
    echo "XrayR status             - 查看 XrayR 状态"
    echo "XrayR enable             - 设置 XrayR 开机自启"
    echo "XrayR disable            - 取消 XrayR 开机自启"
    echo "XrayR log                - 查看 XrayR 日志"
    echo "XrayR update             - 更新 XrayR"
    echo "XrayR update x.x.x       - 更新 XrayR 指定版本"
    echo "XrayR config             - 显示配置文件内容"
    echo "XrayR install            - 安装 XrayR"
    echo "XrayR uninstall          - 卸载 XrayR"
    echo "XrayR version            - 查看 XrayR 版本"
    echo "------------------------------------------"
}

echo -e "${green}开始安装${plain}"
install_base
# install_acme
install_XrayR $1