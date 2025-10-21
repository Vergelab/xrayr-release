#!/usr/bin/env bash
set -e

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
cur_dir=$(pwd)

# ---------- 0) Root & OS checks ----------
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用 root 用户运行！" && exit 1

if [[ -f /etc/redhat-release ]]; then
  release="centos"
elif grep -Eqi "debian" /etc/issue /proc/version 2>/dev/null; then
  release="debian"
elif grep -Eqi "ubuntu" /etc/issue /proc/version 2>/dev/null; then
  release="ubuntu"
elif grep -Eqi "centos|red hat|redhat" /etc/issue /proc/version 2>/dev/null; then
  release="centos"
else
  echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}"; exit 1
fi

arch=$(arch)
case "$arch" in
  x86_64|x64|amd64)  MACHINE="64";   GOARCH="amd64" ;;
  aarch64|arm64)     MACHINE="arm64-v8a"; GOARCH="arm64" ;;
  s390x)             MACHINE="s390x"; GOARCH="s390x" ;;
  *) MACHINE="64"; GOARCH="amd64"; echo -e "${yellow}未知架构，默认按 x86_64 处理${plain}";;
esac
echo "架构: $arch (go: $GOARCH)"

# OS version
os_version=""
[[ -f /etc/os-release ]] && os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
[[ -z "$os_version" && -f /etc/lsb-release ]] && os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
if [[ x"${release}" == x"centos" ]]; then
  [[ ${os_version} -le 6 ]] && echo -e "${red}请使用 CentOS 7+ ${plain}" && exit 1
elif [[ x"${release}" == x"ubuntu" ]]; then
  [[ ${os_version} -lt 16 ]] && echo -e "${red}请使用 Ubuntu 16+ ${plain}" && exit 1
elif [[ x"${release}" == x"debian" ]]; then
  [[ ${os_version} -lt 8  ]] && echo -e "${red}请使用 Debian 8+ ${plain}" && exit 1
fi

# ---------- 1) Base deps ----------
install_base() {
  if [[ x"${release}" == x"centos" ]]; then
    yum install -y epel-release
    yum install -y wget curl unzip tar cronie socat git make gcc gcc-c++ golang || true
    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start crond  >/dev/null 2>&1 || true
  else
    apt update -y
    apt install -y wget curl unzip tar cron socat git build-essential golang || true
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron  >/dev/null 2>&1 || true
  fi
}
install_base

# ---------- 2) figure latest tag from GitLab (VergeLab/XrayR) ----------
GL_PROJECT="VergeLab/XrayR"
LATEST_TAG=""
# 2a) try GitLab API (若服务器能访问 API，无需登录)
if command -v jq >/dev/null 2>&1; then
  LATEST_TAG=$(curl -sL "https://gitlab.com/api/v4/projects/$(python3 - <<'PY'
import urllib.parse; print(urllib.parse.quote("VergeLab/XrayR",""))
PY
)/repository/tags" | jq -r '.[0].name' || true)
fi
# 2b) fallback：抓 tags 页面 HTML 解析第一个以 v 开头的 tag
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
  LATEST_TAG=$(curl -sL "https://gitlab.com/VergeLab/XrayR/-/tags" | grep -oE 'v[0-9][^< ]+' | head -n1 || true)
fi
# 2c) 再不行就用 master
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
  echo -e "${yellow}未能从 GitLab 获取 tag，将使用 master 分支源码${plain}"
fi

# ---------- 3) prepare dir ----------
rm -rf /usr/local/XrayR
mkdir -p /usr/local/XrayR
cd /usr/local/XrayR

# ---------- 4) download source & build ----------
SRC_TGZ=""
if [[ -n "$LATEST_TAG" ]]; then
  SRC_TGZ="XrayR-${LATEST_TAG}.tar.gz"
  echo -e "${green}检测到最新版本：${LATEST_TAG}${plain}，开始下载源码并构建"
  curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/${LATEST_TAG}/XrayR-${LATEST_TAG}.tar.gz" -o "${SRC_TGZ}" || LATEST_TAG=""
fi

if [[ -z "$LATEST_TAG" ]]; then
  SRC_TGZ="XrayR-master.tar.gz"
  echo -e "${yellow}下载 tag 失败，转为使用 master 源码${plain}"
  curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/master/XrayR-master.tar.gz" -o "${SRC_TGZ}"
fi

tar xf "${SRC_TGZ}"
SRC_DIR=$(tar tf "${SRC_TGZ}" | head -n1 | cut -d/ -f1)
cd "${SRC_DIR}"

# go env（某些发行版需显式设置）
export GO111MODULE=on
export CGO_ENABLED=0
export GOOS=linux
export GOARCH=${GOARCH}

echo "开始编译 XrayR （这一步与 CPU/内存有关，需耐心等待）"
# 尝试常规构建
go mod download
go build -trimpath -ldflags "-s -w" -o XrayR ./ || { echo -e "${red}go build 失败，请检查 golang 版本或网络${plain}"; exit 1; }

# 安装二进制
install -m 0755 XrayR /usr/local/XrayR/XrayR

# ---------- 5) geodata ----------
mkdir -p /etc/XrayR
# 使用 Loyalsoldier 最新 geodata
curl -fL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"   -o /etc/XrayR/geoip.dat
curl -fL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o /etc/XrayR/geosite.dat

# ---------- 6) systemd ----------
# 从你的 GitLab release 仓库取服务单元文件
curl -fL "https://gitlab.com/VergeLab/xrayr-release/-/raw/master/XrayR.service" -o /etc/systemd/system/XrayR.service
systemctl daemon-reload
systemctl stop XrayR 2>/dev/null || true
systemctl enable XrayR

# ---------- 7) config ----------
if [[ ! -f /etc/XrayR/config.yml ]]; then
  cat >/etc/XrayR/config.yml <<'YML'
# 最小可运行模板：请按需修改（面板类型、API地址、Token、节点ID等）
Log:
  Level: warning
DnsConfigPath: ""
RouteConfigPath: ""
InboundConfigPath: ""
OutboundConfigPath: ""
ConnetionConfig: {}
Nodes:
  - PanelType: "V2board"         # 或 "SSpanel","ProxyPanel","GoV2Panel" 等
    ApiConfig:
      ApiHost: "https://your-panel.example.com"
      ApiKey: "REPLACE_WITH_PANEL_TOKEN"
      NodeID:  1
      NodeType: V2ray
      Timeout: 60
      EnableVless: true
      RuleListPath: ""
    ControllerConfig:
      ListenIP: 0.0.0.0
      UpdatePeriodic: 60
      EnableDNS: true
      CertConfig:
        CertMode: none
        CertDomain: ""
        Email: ""
        Provider: ""
        DNSEnv: []
YML
  echo -e "${yellow}已生成 /etc/XrayR/config.yml（模板），请根据面板实际信息修改后再启动${plain}"
fi

# ---------- 8) helper CLI ----------
cat >/usr/bin/XrayR <<'SH'
#!/usr/bin/env bash
case "$1" in
  start)    systemctl start XrayR ;;
  stop)     systemctl stop XrayR ;;
  restart)  systemctl restart XrayR ;;
  status)   systemctl status XrayR --no-pager ;;
  enable)   systemctl enable XrayR ;;
  disable)  systemctl disable XrayR ;;
  log)      journalctl -u XrayR -e --no-pager ;;
  config)   ${PAGER:-cat} /etc/XrayR/config.yml ;;
  update)
    echo "拉取最新源码重新编译..."
    systemctl stop XrayR || true
    TMP=$(mktemp -d); cd "$TMP"
    curl -sL "https://gitlab.com/VergeLab/XrayR/-/tags" | grep -oE 'v[0-9][^< ]+' | head -n1 >.tag
    TAG=$(cat .tag)
    if [[ -n "$TAG" ]]; then
      curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/${TAG}/XrayR-${TAG}.tar.gz" -o src.tgz || TAG=""
    fi
    if [[ -z "$TAG" ]]; then
      echo "获取 tag 失败，使用 master"
      curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/master/XrayR-master.tar.gz" -o src.tgz
    fi
    tar xf src.tgz; cd XrayR-*
    export GO111MODULE=on CGO_ENABLED=0 GOOS=linux
    # 自动探测 GOARCH
    case "$(uname -m)" in
      x86_64|amd64) export GOARCH=amd64;;
      aarch64|arm64) export GOARCH=arm64;;
      s390x) export GOARCH=s390x;;
      *) export GOARCH=amd64;;
    esac
    go mod download && go build -trimpath -ldflags "-s -w" -o XrayR ./
    install -m 0755 XrayR /usr/local/XrayR/XrayR
    systemctl start XrayR
    echo "已更新并重启 XrayR"
    ;;
  version)  /usr/local/XrayR/XrayR -version 2>/dev/null || echo "自编译版本" ;;
  *) echo "用法: XrayR {start|stop|restart|status|enable|disable|log|config|update|version}";;
esac
SH
chmod +x /usr/bin/XrayR
ln -sf /usr/bin/XrayR /usr/bin/xrayr 2>/dev/null || true

cd "$cur_dir"
echo -e "${green}XrayR 安装步骤完成${plain}"
echo "------------------------------------------"
echo "常用命令："
echo "XrayR          - 显示帮助"
echo "XrayR config   - 查看配置（请先修改面板参数再启动）"
echo "XrayR start    - 启动"
echo "XrayR stop     - 停止"
echo "XrayR restart  - 重启"
echo "XrayR status   - 状态"
echo "XrayR log      - 查看日志"
echo "XrayR update   - 拉取最新源码并重新编译"
echo "------------------------------------------"

