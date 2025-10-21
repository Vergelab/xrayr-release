#!/usr/bin/env bash
set -e

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
cur_dir=$(pwd)

need_root() { [[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用 root 用户运行！" && exit 1; }
need_root

# ===================== 0) OS / Arch 检测 =====================
if [[ -f /etc/redhat-release ]]; then
  release="centos"
elif grep -Eqi "debian" /etc/issue /proc/version 2>/dev/null; then
  release="debian"
elif grep -Eqi "ubuntu" /etc/issue /proc/version 2>/dev/null; then
  release="ubuntu"
elif grep -Eqi "centos|red hat|redhat" /etc/issue /proc/version 2>/dev/null; then
  release="centos"
else
  echo -e "${red}未检测到受支持的系统版本${plain}"; exit 1
fi

arch=$(uname -m)
case "$arch" in
  x86_64|amd64)  GOARCH="amd64";  GO_TARBALL_ARCH="amd64" ;;
  aarch64|arm64) GOARCH="arm64";  GO_TARBALL_ARCH="arm64" ;;
  s390x)         GOARCH="s390x";  GO_TARBALL_ARCH="s390x" ;;
  *)             GOARCH="amd64";  GO_TARBALL_ARCH="amd64"; echo -e "${yellow}未知架构，按 amd64 处理${plain}";;
esac
echo "架构: $arch (goarch: $GOARCH)"

# ===================== 1) 依赖安装 =====================
install_base() {
  if [[ x"${release}" == x"centos" ]]; then
    yum install -y epel-release
    yum install -y curl wget tar unzip socat git make gcc gcc-c++ cronie || true
    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start  crond >/dev/null 2>&1 || true
  else
    apt update -y
    apt install -y curl wget tar unzip socat git build-essential cron || true
    systemctl enable cron  >/dev/null 2>&1 || true
    systemctl start  cron  >/dev/null 2>&1 || true
  fi
}
install_base

# ===================== 2) Go 环境（>=1.23）与 go.mod 兼容 =====================
ensure_go() {
  local want_major=1 want_minor=23
  local has_go=0 major=0 minor=0

  if command -v go >/dev/null 2>&1; then
    has_go=1
    local ver
    ver=$(go version | awk '{print $3}' | sed 's/^go//')
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
  fi

  if [[ $has_go -eq 1 && $major -ge $want_major && $minor -ge $want_minor ]]; then
    echo -e "${green}检测到 Go：$(go version)，满足 >=1.23${plain}"
    return 0
  fi

  echo -e "${yellow}未检测到 Go 或版本低于 1.23，安装官方 Go 1.23.2${plain}"
  if [[ x"${release}" == x"centos" ]]; then
    yum remove -y golang 2>/dev/null || true
  else
    apt remove -y golang-go golang 2>/dev/null || true
  fi

  cd /usr/local
  rm -rf /usr/local/go
  curl -fL "https://go.dev/dl/go1.23.2.linux-${GO_TARBALL_ARCH}.tar.gz" -o go.tar.gz
  tar -C /usr/local -xzf go.tar.gz
  rm -f go.tar.gz

  if ! grep -q '/usr/local/go/bin' /etc/profile 2>/dev/null; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
  fi
  # shellcheck disable=SC1091
  source /etc/profile

  if ! command -v go >/dev/null 2>&1; then
    echo -e "${red}Go 安装失败${plain}"; exit 1
  fi
  echo -e "${green}Go 安装完成：$(go version)${plain}"
}
ensure_go

# ===================== 3) 目录准备 =====================
rm -rf /usr/local/XrayR
mkdir -p /usr/local/XrayR
cd /usr/local/XrayR

# ===================== 4) 拉取 VergeLab/XrayR 源码（优先最新 tag，失败回退 master） =====================
GL_TAG=""
GL_TAG=$(curl -sL "https://gitlab.com/VergeLab/XrayR/-/tags" | grep -oE 'v[0-9][0-9a-zA-Z\.\-]+' | head -n1 || true)
if [[ -z "$GL_TAG" ]]; then
  echo -e "${yellow}未获取到 tag，将使用 master${plain}"
fi

SRC_TGZ=""
if [[ -n "$GL_TAG" ]]; then
  SRC_TGZ="XrayR-${GL_TAG}.tar.gz"
  echo -e "${green}检测到最新版本：${GL_TAG}${plain}"
  curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/${GL_TAG}/XrayR-${GL_TAG}.tar.gz" -o "${SRC_TGZ}" || GL_TAG=""
fi
if [[ -z "$GL_TAG" ]]; then
  SRC_TGZ="XrayR-master.tar.gz"
  curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/master/XrayR-master.tar.gz" -o "${SRC_TGZ}"
fi

tar xf "${SRC_TGZ}"
SRC_DIR=$(tar tf "${SRC_TGZ}" | head -n1 | cut -d/ -f1)
cd "${SRC_DIR}"

# ===================== 5) 构建（含 go.mod 规范化补丁） =====================
export GO111MODULE=on
export CGO_ENABLED=0
export GOOS=linux
export GOARCH=${GOARCH}

# 兼容旧版 go：将 `go 1.23.1` 规范为 `go 1.23`（对新版本 go 也无副作用）
if grep -q '^go 1\.23\.1$' go.mod 2>/dev/null; then
  sed -i 's/^go 1\.23\.1$/go 1.23/' go.mod || true
fi

echo -e "${green}开始编译 XrayR（如首次下载依赖会稍久）${plain}"
go mod download
go build -trimpath -ldflags "-s -w" -o XrayR ./ || { echo -e "${red}go build 失败${plain}"; exit 1; }

install -m 0755 XrayR /usr/local/XrayR/XrayR

# ===================== 6) geodata（Loyalsoldier） =====================
mkdir -p /etc/XrayR
curl -fL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"   -o /etc/XrayR/geoip.dat
curl -fL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o /etc/XrayR/geosite.dat

# ===================== 7) systemd 服务文件（来自 xrayr-release 仓库） =====================
curl -fL "https://gitlab.com/VergeLab/xrayr-release/-/raw/master/XrayR.service" -o /etc/systemd/system/XrayR.service
systemctl daemon-reload
systemctl stop XrayR 2>/dev/null || true
systemctl enable XrayR >/dev/null 2>&1 || true

# ===================== 8) 默认配置（若不存在才生成） =====================
if [[ ! -f /etc/XrayR/config.yml ]]; then
  cat >/etc/XrayR/config.yml <<'YML'
# 最小可运行模板：请按需修改（面板类型、API地址、Token、节点ID等）
Log:
  Level: warning
DnsConfigPath: ""
RouteConfigPath: ""
InboundConfigPath: ""
OutboundConfigPath: ""
ConnectionConfig: {}
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

# ===================== 9) 管理脚本 /usr/bin/XrayR =====================
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
    TAG=$(curl -sL "https://gitlab.com/VergeLab/XrayR/-/tags" | grep -oE 'v[0-9][0-9a-zA-Z\.\-]+' | head -n1 || true)
    if [[ -n "$TAG" ]]; then
      curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/${TAG}/XrayR-${TAG}.tar.gz" -o src.tgz || TAG=""
    fi
    if [[ -z "$TAG" ]]; then
      echo "获取 tag 失败，使用 master"
      curl -fL "https://gitlab.com/VergeLab/XrayR/-/archive/master/XrayR-master.tar.gz" -o src.tgz
    fi
    tar xf src.tgz; cd XrayR-*
    # 规范化 go.mod（与安装脚本一致）
    if grep -q '^go 1\.23\.1$' go.mod 2>/dev/null; then sed -i 's/^go 1\.23\.1$/go 1.23/' go.mod; fi
    export GO111MODULE=on CGO_ENABLED=0 GOOS=linux
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
  ""|help|-h|--help)
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
    ;;
  *)
    echo "未知子命令：$1"
    echo "使用：XrayR help 查看可用命令"
    exit 1
    ;;
esac
SH
chmod +x /usr/bin/XrayR
ln -sf /usr/bin/XrayR /usr/bin/xrayr 2>/dev/null || true

# ===================== 10) 结尾提示（保持原有风格） =====================
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


