#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

RELEASE_BASE="https://github.com/Vergelab/xrayr-release/releases"
SCRIPT_URL="https://raw.githubusercontent.com/Vergelab/xrayr-release/master/XrayR.sh"
SERVICE_URL="https://raw.githubusercontent.com/Vergelab/xrayr-release/master/XrayR.service"

release=""
arch=""
raw_arch=""

# check root
[[ ${EUID} -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

die() {
    echo -e "${red}$*${plain}"
    exit 1
}

detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        die "未检测到系统版本，请联系 Vergelab！"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    release=""
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
        die "未检测到系统版本，请联系 Vergelab！"
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
                die "请使用 CentOS 7 或更高版本的系统！"
            fi
            ;;
        ubuntu)
            if (( os_version < 16 )); then
                die "请使用 Ubuntu 16 或更高版本的系统！"
            fi
            ;;
        debian)
            if (( os_version < 8 )); then
                die "请使用 Debian 8 或更高版本的系统！"
            fi
            ;;
        *)
            ;;
    esac
}

detect_arch() {
    raw_arch="$(uname -m)"
    case "${raw_arch}" in
        x86_64|amd64|x64)
            arch="64"
            ;;
        aarch64|arm64)
            arch="arm64-v8a"
            ;;
        s390x)
            arch="s390x"
            ;;
        i386|i686|x86)
            echo -e "${red}本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系 Vergelab${plain}"
            exit 2
            ;;
        *)
            die "不支持的架构: ${raw_arch}"
            ;;
    esac
    echo "架构: ${arch}"
}

install_base() {
    if [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get update -y; then
            die "更新软件源失败"
        fi
        if ! apt-get install -y ca-certificates curl unzip tar; then
            die "安装依赖失败"
        fi
    else
        local pm=""
        local -a pkgs=()
        if command -v dnf >/dev/null 2>&1; then
            pm="dnf"
        elif command -v yum >/dev/null 2>&1; then
            pm="yum"
        else
            die "未找到 dnf 或 yum，无法安装依赖"
        fi
        # RHEL 系常预装 curl-minimal，它和 curl 包互相冲突。已经有 curl 时不要替换。
        pkgs=(ca-certificates unzip tar)
        if ! command -v curl >/dev/null 2>&1; then
            pkgs+=(curl)
        fi
        if ! "${pm}" install -y "${pkgs[@]}"; then
            if command -v curl >/dev/null 2>&1; then
                die "安装依赖失败"
            fi
            if ! "${pm}" install -y ca-certificates curl-minimal unzip tar; then
                die "安装依赖失败"
            fi
        fi
    fi
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

# 成功时向标准输出打印 tag，例如 v0.2
resolve_latest_version() {
    local effective=""
    local tag=""
    if ! effective=$(curl -fsSL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' "${RELEASE_BASE}/latest"); then
        return 1
    fi
    tag=$(printf '%s\n' "${effective}" | grep -oE 'v[0-9][0-9A-Za-z.-]+' | head -n 1 || true)
    if [[ -z "${tag}" ]]; then
        return 1
    fi
    printf '%s' "${tag}"
}

# 标准输出只打印 HTTP 状态码。仅当 200 且目标文件非空时返回 0。
download_file() {
    local url="$1"
    local dest="$2"
    local http_code=""
    local rc=0
    http_code=$(curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" -w '%{http_code}' "${url}") || rc=$?
    if [[ ${rc} -eq 0 && "${http_code}" == "200" && -s "${dest}" ]]; then
        printf '%s' "200"
        return 0
    fi
    rm -f "${dest}"
    http_code=$(printf '%s' "${http_code}" | tr -cd '0-9')
    if [[ -z "${http_code}" ]]; then
        http_code="000"
    fi
    printf '%s' "${http_code}"
    return 1
}

verify_checksum() {
    local url="$1"
    local file="$2"
    local asset="$3"
    local sha_path="${file}.sha256"
    local code=""
    local dl_rc=0
    local expected=""
    local actual=""

    code=$(download_file "${url}.sha256" "${sha_path}") || dl_rc=$?
    if [[ ${dl_rc} -ne 0 ]]; then
        if [[ "${code}" == "404" ]]; then
            echo -e "${yellow}警告：发布中没有 ${asset}.sha256（HTTP 404），已跳过完整性校验并继续安装。请维护者上传该校验文件。${plain}"
            return 0
        fi
        echo -e "${red}下载 ${asset}.sha256 失败（HTTP ${code}），已中止安装，原安装未改动${plain}"
        return 1
    fi

    expected=$(awk 'NF { gsub(/\r/, "", $1); print $1; exit }' "${sha_path}")
    if [[ ! "${expected}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo -e "${red}校验文件格式不正确，已中止安装，原安装未改动${plain}"
        return 1
    fi
    if ! actual=$(sha256sum "${file}"); then
        echo -e "${red}计算 SHA256 失败，已中止安装，原安装未改动${plain}"
        return 1
    fi
    actual="${actual%% *}"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        echo -e "${red}SHA256 校验失败，已中止安装，原安装未改动${plain}"
        echo -e "${red}期望 ${expected}${plain}"
        echo -e "${red}实际 ${actual}${plain}"
        return 1
    fi
    echo -e "${green}SHA256 校验通过${plain}"
    return 0
}

copy_config_file() {
    local name="$1"
    local overwrite="$2"
    if [[ ! -f "/usr/local/XrayR/${name}" ]]; then
        return 0
    fi
    if [[ "${overwrite}" -eq 1 || ! -f "/etc/XrayR/${name}" ]]; then
        if ! cp -f "/usr/local/XrayR/${name}" "/etc/XrayR/${name}"; then
            echo -e "${red}复制 ${name} 失败${plain}"
            return 1
        fi
    fi
    return 0
}

restore_previous() {
    local unit_backup="$1"
    echo -e "${yellow}正在恢复上一版本${plain}"
    systemctl stop XrayR >/dev/null 2>&1 || true
    rm -rf /usr/local/XrayR
    if [[ ! -d /usr/local/XrayR.bak ]]; then
        echo -e "${red}没有可恢复的备份${plain}"
        return 1
    fi
    if ! mv /usr/local/XrayR.bak /usr/local/XrayR; then
        echo -e "${red}恢复旧程序目录失败${plain}"
        return 1
    fi
    if [[ -n "${unit_backup}" && -f "${unit_backup}" ]]; then
        cp -f "${unit_backup}" /etc/systemd/system/XrayR.service || true
    fi
    systemctl daemon-reload || true
    if ! systemctl start XrayR; then
        echo -e "${red}恢复后启动命令失败${plain}"
        return 1
    fi
    sleep 3
    if systemctl is-active --quiet XrayR; then
        echo -e "${green}已恢复旧版本并重新启动${plain}"
        return 0
    fi
    echo -e "${red}已恢复旧版本，但重新启动失败${plain}"
    return 1
}

abort_swapped() {
    local msg="$1"
    local prev="$2"
    local unit_backup="$3"
    echo -e "${red}${msg}${plain}"
    if [[ "${prev}" -eq 1 ]]; then
        restore_previous "${unit_backup}" || true
    fi
    exit 1
}

install_XrayR() {
    local requested="${1:-}"
    local last_version=""
    local asset=""
    local url=""
    local work=""
    local stage=""
    local zip_path=""
    local unit_tmp=""
    local unit_backup=""
    local script_tmp=""
    local code=""
    local dl_rc=0
    local had_previous=0
    local config_existed=0
    local name=""
    local status_rc=0

    if [[ -n "${requested}" ]]; then
        if [[ "${requested}" == v* ]]; then
            last_version="${requested}"
        else
            last_version="v${requested}"
        fi
        echo -e "开始安装 XrayR ${last_version}"
    else
        # 连不上 GitHub 时直接退出，不使用写死的版本号，也不改动现有安装
        if ! last_version=$(resolve_latest_version); then
            die "无法连接 GitHub"
        fi
        echo -e "检测到 XrayR 最新版本：${last_version}，开始安装"
    fi

    asset="XrayR-linux-${arch}.zip"
    url="${RELEASE_BASE}/download/${last_version}/${asset}"
    work=$(mktemp -d) || die "创建临时目录失败"
    # shellcheck disable=SC2064
    trap "rm -rf '${work}'" EXIT
    stage="${work}/stage"
    zip_path="${work}/${asset}"
    unit_tmp="${work}/XrayR.service"
    script_tmp="${work}/XrayR.sh"

    code=$(download_file "${url}" "${zip_path}") || dl_rc=$?
    if [[ ${dl_rc} -ne 0 ]]; then
        if [[ "${code}" == "404" && "${arch}" != "64" ]]; then
            die "当前架构 ${raw_arch}（安装包 ${asset}）尚未发布，已中止安装，不会改用 x86-64 包。"
        fi
        if [[ "${code}" == "404" && -n "${requested}" && "${arch}" == "64" ]]; then
            echo -e "${yellow}未找到 XrayR ${last_version} 的安装包，改为下载最新版本${plain}"
            if ! last_version=$(resolve_latest_version); then
                die "无法连接 GitHub"
            fi
            asset="XrayR-linux-${arch}.zip"
            url="${RELEASE_BASE}/download/${last_version}/${asset}"
            zip_path="${work}/${asset}"
            dl_rc=0
            code=$(download_file "${url}" "${zip_path}") || dl_rc=$?
            if [[ ${dl_rc} -ne 0 ]]; then
                if [[ "${code}" == "404" ]]; then
                    die "未找到 XrayR ${last_version} 的安装包，原安装未改动"
                fi
                die "无法连接 GitHub"
            fi
            echo -e "改为安装实际发布的版本：${last_version}"
        elif [[ "${code}" == "404" ]]; then
            die "未找到安装包 ${asset}（版本 ${last_version}），原安装未改动"
        else
            die "无法连接 GitHub"
        fi
    fi

    if ! verify_checksum "${url}" "${zip_path}" "${asset}"; then
        exit 1
    fi

    if ! unzip -tqq "${zip_path}"; then
        die "安装包损坏，unzip 校验未通过，已取消安装，原安装未改动"
    fi
    mkdir -p "${stage}" || die "创建暂存目录失败"
    if ! unzip -q "${zip_path}" -d "${stage}"; then
        die "解压安装包失败，已取消安装，原安装未改动"
    fi
    if [[ ! -f "${stage}/XrayR" ]]; then
        die "安装包中没有 XrayR 可执行文件，已取消安装，原安装未改动"
    fi
    if ! chmod +x "${stage}/XrayR"; then
        die "设置 XrayR 可执行权限失败，已取消安装，原安装未改动"
    fi
    if ! (
        cd "${stage}" || exit 1
        ./XrayR version
    ); then
        die "新版本无法执行（XrayR version 失败），已取消安装，原安装未改动"
    fi

    dl_rc=0
    code=$(download_file "${SERVICE_URL}" "${unit_tmp}") || dl_rc=$?
    if [[ ${dl_rc} -ne 0 ]]; then
        die "下载 systemd 单元失败（HTTP ${code}），已取消安装，原安装未改动"
    fi
    if [[ ! -s "${unit_tmp}" ]]; then
        die "systemd 单元文件为空，已取消安装，原安装未改动"
    fi

    # 先把管理脚本下到临时文件并做语法检查，失败时不覆盖 /usr/bin/XrayR
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${script_tmp}" "${SCRIPT_URL}"; then
        die "下载管理脚本失败，已取消安装，原安装未改动"
    fi
    if ! bash -n "${script_tmp}"; then
        die "管理脚本语法检查失败，已取消安装，原安装未改动"
    fi

    # 以上任何失败都还没有停止服务或移动 /usr/local/XrayR
    if [[ -d /usr/local/XrayR ]]; then
        had_previous=1
    fi
    if [[ -f /etc/XrayR/config.yml ]]; then
        config_existed=1
    fi
    if [[ -f /etc/systemd/system/XrayR.service ]]; then
        unit_backup="${work}/XrayR.service.bak"
        if ! cp -a /etc/systemd/system/XrayR.service "${unit_backup}"; then
            die "备份当前 systemd 单元失败，原安装未改动"
        fi
        check_status
        status_rc=$?
        if [[ ${status_rc} -eq 0 ]]; then
            if ! systemctl stop XrayR; then
                echo -e "${yellow}停止 XrayR 时出现错误，将确认进程是否已经退出${plain}"
            fi
            sleep 1
            if systemctl is-active --quiet XrayR; then
                die "无法停止正在运行的 XrayR，已取消安装，原安装未改动"
            fi
        fi
    fi

    if [[ -d /usr/local/XrayR.bak ]]; then
        if ! rm -rf /usr/local/XrayR.bak; then
            die "清理旧备份 /usr/local/XrayR.bak 失败，原安装未改动"
        fi
    fi
    if [[ ${had_previous} -eq 1 ]]; then
        if ! mv /usr/local/XrayR /usr/local/XrayR.bak; then
            die "备份当前安装失败，原目录仍保留"
        fi
    fi
    if ! mv "${stage}" /usr/local/XrayR; then
        echo -e "${red}放入新版本失败，正在恢复${plain}"
        if [[ ${had_previous} -eq 1 ]]; then
            mv /usr/local/XrayR.bak /usr/local/XrayR || true
            if [[ -n "${unit_backup}" && -f "${unit_backup}" ]]; then
                cp -f "${unit_backup}" /etc/systemd/system/XrayR.service || true
                systemctl daemon-reload || true
                systemctl start XrayR || true
            fi
        fi
        exit 1
    fi

    if ! mkdir -p /etc/systemd/system; then
        abort_swapped "创建 /etc/systemd/system 失败" "${had_previous}" "${unit_backup}"
    fi
    if ! install -m644 "${unit_tmp}" /etc/systemd/system/XrayR.service; then
        abort_swapped "安装 systemd 单元失败，正在恢复" "${had_previous}" "${unit_backup}"
    fi
    if [[ ! -s /etc/systemd/system/XrayR.service ]]; then
        echo -e "${red}systemd 单元文件为空，正在恢复${plain}"
        if [[ ${had_previous} -eq 1 ]]; then
            restore_previous "${unit_backup}" || true
        fi
        exit 1
    fi
    if ! systemctl daemon-reload; then
        echo -e "${red}systemd 重新加载失败，正在恢复${plain}"
        if [[ ${had_previous} -eq 1 ]]; then
            restore_previous "${unit_backup}" || true
        fi
        exit 1
    fi
    if ! systemctl enable XrayR; then
        echo -e "${red}设置开机自启失败${plain}"
        if [[ ${had_previous} -eq 1 ]]; then
            restore_previous "${unit_backup}" || true
        fi
        exit 1
    fi

    if ! mkdir -p /etc/XrayR; then
        abort_swapped "创建 /etc/XrayR 失败" "${had_previous}" "${unit_backup}"
    fi
    if ! copy_config_file geoip.dat 1; then
        abort_swapped "复制 geoip.dat 失败，正在恢复" "${had_previous}" "${unit_backup}"
    fi
    if ! copy_config_file geosite.dat 1; then
        abort_swapped "复制 geosite.dat 失败，正在恢复" "${had_previous}" "${unit_backup}"
    fi
    if [[ ${config_existed} -eq 0 ]]; then
        if ! copy_config_file config.yml 0; then
            abort_swapped "复制 config.yml 失败，正在恢复" "${had_previous}" "${unit_backup}"
        fi
    fi
    for name in dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
        if ! copy_config_file "${name}" 0; then
            abort_swapped "复制 ${name} 失败，正在恢复" "${had_previous}" "${unit_backup}"
        fi
    done
    if ! chmod 700 /etc/XrayR; then
        abort_swapped "设置 /etc/XrayR 权限失败" "${had_previous}" "${unit_backup}"
    fi
    if [[ -f /etc/XrayR/config.yml ]]; then
        if ! chmod 600 /etc/XrayR/config.yml; then
            abort_swapped "设置 /etc/XrayR/config.yml 权限失败" "${had_previous}" "${unit_backup}"
        fi
    fi

    if ! install -m755 "${script_tmp}" /usr/bin/XrayR; then
        abort_swapped "安装管理脚本失败" "${had_previous}" "${unit_backup}"
    fi
    if ! ln -sfn /usr/bin/XrayR /usr/bin/xrayr; then
        abort_swapped "创建 /usr/bin/xrayr 链接失败" "${had_previous}" "${unit_backup}"
    fi

    if [[ ${had_previous} -eq 1 ]]; then
        if ! systemctl start XrayR; then
            echo -e "${red}启动 XrayR 失败，正在恢复旧版本${plain}"
            restore_previous "${unit_backup}" || true
            exit 1
        fi
        sleep 3
        if ! systemctl is-active --quiet XrayR; then
            echo -e "${red}XrayR 启动后未处于运行状态，正在恢复旧版本${plain}"
            restore_previous "${unit_backup}" || true
            exit 1
        fi
        echo -e "${green}XrayR 重启成功${plain}"
    else
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/Vergelab/XrayR，配置必要的内容"
    fi

    echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置开机自启"
    echo "已安装版本: ${last_version}"
    if [[ -d /usr/local/XrayR.bak ]]; then
        echo "旧版本已保留在 /usr/local/XrayR.bak"
    fi
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
detect_os
detect_arch
install_base
if ! command -v unzip >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    die "依赖未就绪：需要 unzip 和 curl"
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    die "依赖未就绪：需要 sha256sum"
fi
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    install_XrayR "$1"
else
    install_XrayR
fi
