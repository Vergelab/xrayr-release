#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

INSTALL_URL="https://raw.githubusercontent.com/Vergelab/xrayr-release/master/install.sh"
SCRIPT_URL="https://raw.githubusercontent.com/Vergelab/xrayr-release/master/XrayR.sh"

# check root
[[ ${EUID} -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        echo -e "${red}未检测到系统版本，请联系 Vergelab！${plain}\n" && exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    local release=""
    case "${ID:-}" in
        debian|ubuntu|centos|rhel|almalinux|rocky)
            release="${ID}"
            ;;
        *)
            local like_ids=()
            local like=""
            read -r -a like_ids <<< "${ID_LIKE:-}"
            for like in "${like_ids[@]}"; do
                case "${like}" in
                    debian|ubuntu)
                        release="${like}"
                        break
                        ;;
                    rhel|centos|fedora)
                        release="centos"
                        break
                        ;;
                    *)
                        ;;
                esac
            done
            ;;
    esac

    if [[ -z "${release}" ]]; then
        echo -e "${red}未检测到系统版本，请联系 Vergelab！${plain}\n" && exit 1
    fi

    local os_version=""
    if [[ -n "${VERSION_ID:-}" ]]; then
        os_version="${VERSION_ID%%.*}"
    fi
    if [[ -z "${os_version}" ]]; then
        echo -e "${yellow}未检测到 VERSION_ID（例如 Debian testing/sid），已跳过版本下限检查${plain}"
        return 0
    fi
    if [[ ! "${os_version}" =~ ^[0-9]+$ ]]; then
        echo -e "${yellow}无法解析系统版本号 ${VERSION_ID}，已跳过版本下限检查${plain}"
        return 0
    fi

    case "${release}" in
        centos|rhel|almalinux|rocky)
            if (( os_version <= 6 )); then
                echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
            fi
            ;;
        ubuntu)
            if (( os_version < 16 )); then
                echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
            fi
            ;;
        debian)
            if (( os_version < 8 )); then
                echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
            fi
            ;;
        *)
            ;;
    esac
}

detect_os

confirm() {
    local temp=""
    if (( $# > 1 )); then
        echo && read -r -p "$1 [默认$2]: " temp
        if [[ -z "${temp}" ]]; then
            temp="$2"
        fi
    else
        read -r -p "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    fi
    return 1
}

confirm_restart() {
    if confirm "是否重启XrayR" "y"; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    local temp=""
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read -r temp
    show_menu
}

fetch_install_script() {
    local dest="$1"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${INSTALL_URL}"; then
        echo -e "${red}无法连接 GitHub${plain}"
        return 1
    fi
    if ! bash -n "${dest}"; then
        echo -e "${red}安装脚本语法检查失败，已保留当前版本${plain}"
        return 1
    fi
    return 0
}

install() {
    local tmp=""
    local rc=0
    tmp=$(mktemp) || {
        echo -e "${red}创建临时文件失败${plain}"
        return 1
    }
    if ! fetch_install_script "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    bash "${tmp}"
    rc=$?
    rm -f "${tmp}"
    if [[ ${rc} -ne 0 ]]; then
        return "${rc}"
    fi
    if [[ $# -eq 0 ]]; then
        start
    else
        start 0
    fi
}

update() {
    local version=""
    local tmp=""
    local log=""
    local rc=0
    local installed=""

    if [[ $# -eq 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read -r version
    else
        # 调用形式为 update 0 <version>；省略版本号表示安装 latest
        version="${2:-}"
    fi

    tmp=$(mktemp) || {
        echo -e "${red}创建临时文件失败${plain}"
        return 1
    }
    if ! fetch_install_script "${tmp}"; then
        rm -f "${tmp}"
        if [[ $# -eq 0 ]]; then
            before_show_menu
        fi
        return 1
    fi

    log=$(mktemp) || {
        rm -f "${tmp}"
        echo -e "${red}创建临时文件失败${plain}"
        return 1
    }
    if [[ -n "${version}" ]]; then
        # shellcheck disable=SC2312 # 退出码用 PIPESTATUS 读取，不能拆开这条管道
        bash "${tmp}" "${version}" 2>&1 | tee "${log}"
    else
        # shellcheck disable=SC2312 # 退出码用 PIPESTATUS 读取，不能拆开这条管道
        bash "${tmp}" 2>&1 | tee "${log}"
    fi
    rc=${PIPESTATUS[0]}
    installed=$(sed -n 's/^已安装版本: //p' "${log}" | tail -n 1 || true)
    rm -f "${tmp}" "${log}"

    if [[ ${rc} -eq 0 ]]; then
        if [[ -n "${installed}" ]]; then
            echo -e "${green}更新完成，当前版本 ${installed}，已自动重启 XrayR，请使用 XrayR log 查看运行日志${plain}"
        else
            echo -e "${green}更新完成，已自动重启 XrayR，请使用 XrayR log 查看运行日志${plain}"
        fi
        exit 0
    fi

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
    return 1
}

config() {
    local yn=""
    local st=0
    echo "XrayR在修改配置后会自动尝试重启"
    vi /etc/XrayR/config.yml
    sleep 2
    check_status
    st=$?
    case ${st} in
        0)
            echo -e "XrayR状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动XrayR或XrayR自动重启失败，是否查看日志？[Y/n]" && echo
            read -r -e -p "(默认: y):" yn
            [[ -z "${yn}" ]] && yn="y"
            if [[ "${yn}" == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "XrayR状态: ${red}未安装${plain}"
            ;;
        *)
            echo -e "XrayR状态: ${red}未知${plain}"
            ;;
    esac
}

uninstall() {
    if ! confirm "确定要卸载 XrayR 吗?" "n"; then
        if [[ $# -eq 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ -d /etc/XrayR ]]; then
        local backup=""
        backup="/root/XrayR-config-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        if confirm "是否将配置备份到 ${backup} ?" "y"; then
            if ! tar -czf "${backup}" -C /etc XrayR; then
                echo -e "${red}备份失败，已中止卸载，配置未删除${plain}"
                return 1
            fi
            echo -e "${green}配置已备份到 ${backup}${plain}"
        else
            echo -e "${yellow}已跳过配置备份${plain}"
        fi
    fi

    systemctl stop XrayR || true
    systemctl disable XrayR || true
    rm -f /etc/systemd/system/XrayR.service
    systemctl daemon-reload || true
    systemctl reset-failed || true
    rm -rf /etc/XrayR
    rm -rf /usr/local/XrayR
    rm -rf /usr/local/XrayR.bak
    rm -f /usr/bin/XrayR /usr/bin/xrayr

    echo ""
    echo -e "${green}卸载成功${plain}，程序、配置和管理脚本已删除"
    echo ""

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

start() {
    local st=0
    check_status
    st=$?
    if [[ ${st} -eq 0 ]]; then
        echo ""
        echo -e "${green}XrayR已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        systemctl start XrayR
        sleep 2
        check_status
        st=$?
        if [[ ${st} -eq 0 ]]; then
            echo -e "${green}XrayR 启动成功，请使用 XrayR log 查看运行日志${plain}"
        else
            echo -e "${red}XrayR可能启动失败，请稍后使用 XrayR log 查看日志信息${plain}"
        fi
    fi

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

stop() {
    local st=0
    systemctl stop XrayR
    sleep 2
    check_status
    st=$?
    if [[ ${st} -eq 1 ]]; then
        echo -e "${green}XrayR 停止成功${plain}"
    else
        echo -e "${red}XrayR停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

restart() {
    local st=0
    systemctl restart XrayR
    sleep 2
    check_status
    st=$?
    if [[ ${st} -eq 0 ]]; then
        echo -e "${green}XrayR 重启成功，请使用 XrayR log 查看运行日志${plain}"
    else
        echo -e "${red}XrayR可能启动失败，请稍后使用 XrayR log 查看日志信息${plain}"
    fi
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

status() {
    systemctl status XrayR --no-pager -l
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if systemctl enable XrayR; then
        echo -e "${green}XrayR 设置开机自启成功${plain}"
    else
        echo -e "${red}XrayR 设置开机自启失败${plain}"
    fi

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if systemctl disable XrayR; then
        echo -e "${green}XrayR 取消开机自启成功${plain}"
    else
        echo -e "${red}XrayR 取消开机自启失败${plain}"
    fi

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

error_path_from_config() {
    local line=""
    local value=""
    if [[ ! -f /etc/XrayR/config.yml ]]; then
        return 0
    fi
    line=$(grep -E '^[[:space:]]*ErrorPath:' /etc/XrayR/config.yml | head -n 1 || true)
    if [[ -z "${line}" ]]; then
        return 0
    fi
    value="${line#*:}"
    value="${value%%#*}"
    value=$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    printf '%s' "${value}"
}

show_log() {
    local error_path=""
    if ! journalctl -u XrayR -n 200 --no-pager; then
        echo -e "${yellow}读取 journalctl 日志失败${plain}"
    fi
    error_path=$(error_path_from_config)
    if [[ -n "${error_path}" ]]; then
        if [[ -f "${error_path}" ]]; then
            echo "---------- ErrorPath: ${error_path} ----------"
            if ! tail -n 200 -- "${error_path}"; then
                echo -e "${yellow}读取 ErrorPath 失败${plain}"
            fi
        else
            echo -e "${yellow}配置了 ErrorPath 但文件不存在: ${error_path}${plain}"
        fi
    fi
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

install_bbr() {
    local kver=""
    local major=""
    local minor=""
    local rest=""
    local cc=""
    local apply_rc=0

    kver=$(uname -r)
    major="${kver%%.*}"
    rest="${kver#*.}"
    minor="${rest%%.*}"
    major="${major%%[^0-9]*}"
    minor="${minor%%[^0-9]*}"
    if [[ -z "${major}" || -z "${minor}" ]]; then
        echo -e "${yellow}警告：无法解析内核版本 ${kver}${plain}"
    elif (( major < 4 || (major == 4 && minor < 9) )); then
        echo -e "${yellow}警告：当前内核 ${kver} 低于 4.9，可能无法启用 BBR${plain}"
    fi

    if ! mkdir -p /etc/sysctl.d; then
        echo -e "${red}创建 /etc/sysctl.d 失败${plain}"
        return 1
    fi
    if ! cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    then
        echo -e "${red}写入 /etc/sysctl.d/99-bbr.conf 失败${plain}"
        return 1
    fi

    sysctl --system || apply_rc=$?
    if [[ ${apply_rc} -ne 0 ]]; then
        echo -e "${red}sysctl --system 执行失败，BBR 可能未生效${plain}"
    fi
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    echo "当前拥塞控制: ${cc:-未知}"
    if [[ ${apply_rc} -eq 0 && "${cc}" == "bbr" ]]; then
        echo -e "${green}BBR 已启用${plain}"
    elif [[ ${apply_rc} -eq 0 ]]; then
        echo -e "${yellow}已写入配置，但当前拥塞控制不是 bbr${plain}"
    fi

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
    return "${apply_rc}"
}

update_shell() {
    local tmp=""
    # 下载到临时文件，语法检查通过后才替换。任何一步失败都保留原来的 /usr/bin/XrayR。
    if tmp=$(mktemp) && curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}" "${SCRIPT_URL}" && bash -n "${tmp}" && install -m755 "${tmp}" /usr/bin/XrayR; then
        rm -f "${tmp}"
        ln -sfn /usr/bin/XrayR /usr/bin/xrayr || true
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}"
        exit 0
    fi
    rm -f "${tmp}"
    echo ""
    echo -e "${red}下载脚本失败，请检查本机能否连接 Github。当前脚本未改动。${plain}"
    if [[ "${1:-}" == "menu" ]]; then
        before_show_menu
    fi
    return 1
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/systemd/system/XrayR.service ]]; then
        return 2
    fi
    if systemctl is-active --quiet XrayR; then
        return 0
    fi
    return 1
}

check_enabled() {
    local temp=""
    temp=$(systemctl is-enabled XrayR 2>/dev/null || true)
    if [[ "${temp}" == "enabled" ]]; then
        return 0
    fi
    return 1
}

check_uninstall() {
    local st=0
    check_status
    st=$?
    if [[ ${st} -ne 2 ]]; then
        echo ""
        echo -e "${red}XrayR已安装，请不要重复安装${plain}"
        if [[ $# -eq 0 ]]; then
            before_show_menu
        fi
        return 1
    fi
    return 0
}

check_install() {
    local st=0
    check_status
    st=$?
    if [[ ${st} -eq 2 ]]; then
        echo ""
        echo -e "${red}请先安装XrayR${plain}"
        if [[ $# -eq 0 ]]; then
            before_show_menu
        fi
        return 1
    fi
    return 0
}

show_status() {
    local st=0
    check_status
    st=$?
    case ${st} in
        0)
            echo -e "XrayR状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "XrayR状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "XrayR状态: ${red}未安装${plain}"
            ;;
        *)
            echo -e "XrayR状态: ${red}未知${plain}"
            ;;
    esac
}

show_enable_status() {
    if check_enabled; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

show_XrayR_version() {
    echo -n "XrayR 版本："
    if [[ -x /usr/local/XrayR/XrayR ]]; then
        /usr/local/XrayR/XrayR version
    else
        echo -e "${red}未找到 XrayR 程序${plain}"
    fi
    echo ""
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

show_usage() {
    echo "XrayR 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "XrayR              - 显示管理菜单 (功能更多)"
    echo "XrayR start        - 启动 XrayR"
    echo "XrayR stop         - 停止 XrayR"
    echo "XrayR restart      - 重启 XrayR"
    echo "XrayR status       - 查看 XrayR 状态"
    echo "XrayR enable       - 设置 XrayR 开机自启"
    echo "XrayR disable      - 取消 XrayR 开机自启"
    echo "XrayR log          - 查看 XrayR 日志"
    echo "XrayR update       - 更新 XrayR"
    echo "XrayR update x.x.x - 更新 XrayR 指定版本"
    echo "XrayR install      - 安装 XrayR"
    echo "XrayR uninstall    - 卸载 XrayR"
    echo "XrayR version      - 查看 XrayR 版本"
    echo "XrayR bbr          - 启用 BBR（不安装新内核）"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}XrayR 后端管理脚本，${plain}${red}不适用于docker${plain}
--- https://github.com/Vergelab/XrayR ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 XrayR
  ${green}2.${plain} 更新 XrayR
  ${green}3.${plain} 卸载 XrayR
————————————————
  ${green}4.${plain} 启动 XrayR
  ${green}5.${plain} 停止 XrayR
  ${green}6.${plain} 重启 XrayR
  ${green}7.${plain} 查看 XrayR 状态
  ${green}8.${plain} 查看 XrayR 日志
————————————————
  ${green}9.${plain} 设置 XrayR 开机自启
 ${green}10.${plain} 取消 XrayR 开机自启
————————————————
 ${green}11.${plain} 启用 BBR（不更换内核）
 ${green}12.${plain} 查看 XrayR 版本
 ${green}13.${plain} 升级维护脚本
 "
    show_status
    local num=""
    echo && read -r -p "请输入选择 [0-13]: " num

    case "${num}" in
        0) config
        ;;
        1) check_uninstall && install
        ;;
        2) check_install && update
        ;;
        3) check_install && uninstall
        ;;
        4) check_install && start
        ;;
        5) check_install && stop
        ;;
        6) check_install && restart
        ;;
        7) check_install && status
        ;;
        8) check_install && show_log
        ;;
        9) check_install && enable
        ;;
        10) check_install && disable
        ;;
        11) install_bbr
        ;;
        12) check_install && show_XrayR_version
        ;;
        13) update_shell menu
        ;;
        *) echo -e "${red}请输入正确的数字 [0-13]${plain}"
        ;;
    esac
}

if (( $# > 0 )); then
    case "$1" in
        "start") check_install 0 && start 0
        ;;
        "stop") check_install 0 && stop 0
        ;;
        "restart") check_install 0 && restart 0
        ;;
        "status") check_install 0 && status 0
        ;;
        "enable") check_install 0 && enable 0
        ;;
        "disable") check_install 0 && disable 0
        ;;
        "log") check_install 0 && show_log 0
        ;;
        "update") check_install 0 && update 0 "${2:-}"
        ;;
        "config") config "$@"
        ;;
        "install") check_uninstall 0 && install 0
        ;;
        "uninstall") check_install 0 && uninstall 0
        ;;
        "version") check_install 0 && show_XrayR_version 0
        ;;
        "bbr") install_bbr 0
        ;;
        "update_shell") update_shell
        ;;
        *) show_usage
    esac
else
    show_menu
fi
