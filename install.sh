#!/usr/bin/env bash
# argo-fanout 交互式一键安装脚本
# 支持 bash <(curl ...) 在线运行，会自动 clone 仓库到本地。

set -euo pipefail

# === 基础配置 ===
REPO_URL="https://github.com/liu200320/argo-fanout.git"
INSTALL_DIR="/opt/argo-fanout"

# 颜色与样式
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { printf "${GREEN}[信息]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[警告]${NC} %s\n" "$*"; }
log_err()  { printf "${RED}[错误]${NC} %s\n" "$*" >&2; }
log_step() { printf "\n${CYAN}==> %s${NC}\n" "$*"; }

# 交互输入包装：如果标准输入被占（比如 bash <(curl)），就强制从 /dev/tty 读
ask() {
  local prompt="$1"
  local default="${2:-}"
  local var_name="$3"
  local val
  
  if [ -n "$default" ]; then
    printf "${BOLD}%s${NC} [%s]: " "$prompt" "$default"
  else
    printf "${BOLD}%s${NC}: " "$prompt"
  fi
  
  if [ -t 0 ]; then
    read -r val
  else
    read -r val </dev/tty
  fi
  
  [ -z "$val" ] && val="$default"
  eval "$var_name=\"\$val\""
}

# === 阶段 1：环境检查与自举 ===
bootstrap() {
  log_step "环境检查与获取源码"
  
  if [ "$EUID" -ne 0 ]; then
    log_err "必须使用 root 权限运行此脚本"
    exit 1
  fi
  
  if [ ! -c /dev/net/tun ]; then
    log_err "缺少 /dev/net/tun 设备，fanout 无法创建隧道"
    log_warn "如果你在使用 LXC/OpenVZ 容器，请联系主机商开启 TUN 选项"
    exit 1
  fi
  
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) log_err "不支持的架构: $arch，fanout 仅支持 amd64 / arm64"; exit 1 ;;
  esac
  
  # 判断运行方式：如果当前目录没有 vendor，说明是在线运行，需要 clone
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  if [ ! -d "${SCRIPT_DIR}/vendor/fanout" ]; then
    log_info "检测到在线运行，准备下载源码..."
    if ! command -v git >/dev/null 2>&1; then
      log_err "未找到 git，在线安装必须先把仓库 clone 到本地"
      log_err ""
      log_err "请按你的系统安装 git 后重试："
      log_err "  Debian/Ubuntu : apt update && apt install -y git"
      log_err "  CentOS/RHEL   : yum install -y git   (或 dnf install -y git)"
      log_err "  Alpine        : apk add git bash    (必须连 bash 一起装)"
      log_err "  Arch/Manjaro  : pacman -S --noconfirm git"
      log_err "  openSUSE      : zypper --non-interactive install git"
      log_err ""
      log_err "也可以改用本地安装：git clone 后进入仓库目录跑 bash install.sh"
      exit 1
    fi
    
    if [ -d "$INSTALL_DIR" ]; then
      log_info "目录 $INSTALL_DIR 已存在，更新代码..."
      (cd "$INSTALL_DIR" && git pull --quiet)
    else
      log_info "正在克隆仓库到 $INSTALL_DIR ..."
      git clone --quiet "$REPO_URL" "$INSTALL_DIR"
    fi
    
    log_info "转交控制权给本地安装脚本..."
    exec bash "${INSTALL_DIR}/install.sh" "$@"
    exit 0
  fi
  
  # 如果走到这里，说明是本地执行，且在仓库根目录
  export ARGO_FANOUT_ROOT="$SCRIPT_DIR"
}

# === 阶段 2：交互收集参数 ===
collect_params() {
  log_step "配置选项"
  
  echo "这个安装器包含两个组件："
  echo "  1) sing-box-argo-lite：负责接受入站连接并提供 Argo 隧道"
  echo "  2) fanout：负责提供 VPNGate 出站节点，并将入站流量导向对应出口"
  echo
  
  # === sb-argo 配置 ===
  printf "${BLUE}--- sing-box-argo-lite 配置 ---${NC}\n"
  ask "运行用户 (默认用 root 部署，最简单)" "root" SB_USER
  if [ "$SB_USER" != "root" ] && ! id "$SB_USER" >/dev/null 2>&1; then
    ask "用户 $SB_USER 不存在，是否创建？(y/n)" "y" CREATE_USER
    if [ "$CREATE_USER" != "y" ]; then
      log_err "已取消安装"
      exit 1
    fi
  fi
  
  ask "本地监听端口 (1024-65535，fanout 会接管此端口)" "40001" SB_PORT
  ask "UUID (留空自动生成)" "" SB_UUID
  ask "WebSocket 路径 (留空自动生成)" "" SB_PATH
  ask "订阅节点名称" "NAT-Argo-Fanout" SB_NODE_NAME
  
  echo
  ask "是否将节点链接发布到 GitHub Gist？(y/n，选 y 需要 GitHub Token)" "n" SB_SUBSCRIBE
  SB_TOKEN=""
  if [ "$SB_SUBSCRIBE" = "y" ]; then
    printf "${BOLD}请输入具备 gist 权限的 GitHub Token (输入不显示): ${NC}"
    if [ -t 0 ]; then
      read -rs SB_TOKEN
    else
      read -rs SB_TOKEN </dev/tty
    fi
    echo
    if [ -z "$SB_TOKEN" ]; then
      log_warn "未输入 Token，将退回仅本地生成订阅模式"
      SB_SUBSCRIBE="n"
    fi
  fi
  echo
  
  # === fanout 配置 ===
  printf "${BLUE}--- fanout 配置 ---${NC}\n"
  ask "fanout Web 管理后台端口" "8899" FO_WEB_PORT
  
  echo
  printf "${YELLOW}确认配置无误后按回车键开始安装...${NC}"
  if [ -t 0 ]; then read -r _; else read -r _ </dev/tty; fi
}

# === 阶段 3：执行安装 ===
install_components() {
  # --- 安装 sb-argo ---
  log_step "正在安装 sing-box-argo-lite"
  
  if [ "$SB_USER" != "root" ] && ! id "$SB_USER" >/dev/null 2>&1; then
    log_info "创建用户 $SB_USER ..."
    useradd -m -s /bin/bash "$SB_USER"
  fi
  
  local sb_home
  if [ "$SB_USER" = "root" ]; then
    sb_home="/root"
  else
    sb_home=$(eval echo "~$SB_USER")
  fi
  
  local sb_conf_dir="${sb_home}/.config/sb-argo"
  mkdir -p "$sb_conf_dir"
  
  # 生成 config.conf（使用 sb-argo 的标准格式）
  local conf_file="${sb_conf_dir}/config.conf"
  
  # 转换 y/n 为 true/false
  local subscribe_bool="false"
  [ "$SB_SUBSCRIBE" = "y" ] && subscribe_bool="true"
  
  cat > "$conf_file" <<EOF
LOCAL_PORT=$(printf '%q' "$SB_PORT")
UUID=$(printf '%q' "$SB_UUID")
WS_PATH=$(printf '%q' "$SB_PATH")
NODE_NAME=$(printf '%q' "$SB_NODE_NAME")
SUBSCRIBE=$(printf '%q' "$subscribe_bool")
ENABLE_CRON='true'
SB_MEMORY='18MiB'
CF_MEMORY='24MiB'
EOF
  
  # 如果有 Token，写入 secrets.conf
  if [ -n "$SB_TOKEN" ]; then
    cat > "${sb_conf_dir}/secrets.conf" <<EOF
GITHUB_TOKEN=$(printf '%q' "$SB_TOKEN")
EOF
    chmod 600 "${sb_conf_dir}/secrets.conf"
    chown "$SB_USER:" "${sb_conf_dir}/secrets.conf"
  fi
  
  chmod 600 "$conf_file"
  chown -R "$SB_USER:" "$sb_conf_dir"
  
  local sb_src="${ARGO_FANOUT_ROOT}/vendor/sing-box-argo-lite/install.sh"
  
  # 以目标用户身份运行安装脚本
  if [ "$SB_USER" = "root" ]; then
    bash "$sb_src" install
  else
    su - "$SB_USER" -c "bash '$sb_src' install"
  fi
  
  log_info "sing-box-argo-lite 安装完成"
  
  # --- 安装 fanout ---
  log_step "正在安装 fanout"
  
  local fo_bin_src="${ARGO_FANOUT_ROOT}/bin/fanout-linux-${GOARCH}"
  if [ -x "$fo_bin_src" ]; then
    log_info "找到随仓库附带的二进制 (${GOARCH})，无需编译。"
    export FANOUT_PREBUILT="$fo_bin_src"
  else
    log_warn "未找到对应架构的预编译二进制，将触发源码编译 (需要服务器有 Go 环境)。"
  fi
  
  export WEB_PORT="$FO_WEB_PORT"
  export FANOUT_PANEL_MODE="sing-box-argo-lite"
  
  pushd "${ARGO_FANOUT_ROOT}/vendor/fanout" >/dev/null
  bash install.sh
  popd >/dev/null
  
  log_info "fanout 安装完成"
  
  # --- 绑定与重启 ---
  log_step "正在绑定后端模式"

  local fo_mode_file="/var/lib/fanout/panel_mode"
  if [ -d "/var/lib/fanout" ]; then
    echo "sing-box-argo-lite" > "$fo_mode_file"
    chmod 600 "$fo_mode_file"
    log_info "已将 fanout 节点后端锁定为 sing-box-argo-lite。"

    # 关键：fanout 只在进程启动时读一次 panel_mode，
    # 必须重启让新进程读到。重启失败不能吞掉，否则面板仍停留在自建模式。
    local restarted=false
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl restart fanout 2>/dev/null; then
        restarted=true
      else
        log_warn "systemctl restart fanout 失败"
      fi
    elif command -v rc-service >/dev/null 2>&1; then
      if rc-service fanout restart; then
        restarted=true
      else
        log_warn "rc-service fanout restart 失败"
      fi
    fi

    if [ "$restarted" != "true" ]; then
      log_warn "未能自动重启 fanout 服务，面板可能仍是自建模式。请手动执行："
      log_warn "  systemctl restart fanout   （或 OpenRC 下 rc-service fanout restart）"
      log_warn "重启后 fanout 才会读取 panel_mode，切到 sing-box-argo-lite 后端。"
    fi
  else
    log_warn "未找到 fanout 数据目录，未能自动锁定后端模式。请稍后在 Web 界面中手动选择。"
  fi
}

# === 阶段 4：结果汇总 ===
print_summary() {
  log_step "安装完成！"
  
  local sb_home
  if [ "$SB_USER" = "root" ]; then
    sb_home="/root"
  else
    sb_home=$(eval echo "~$SB_USER")
  fi
  
  local node_info="${sb_home}/.local/share/sb-argo/state/node-info.txt"
  
  if [ -f "$node_info" ]; then
    printf "${BLUE}--- sing-box 节点信息 ---${NC}\n"
    cat "$node_info"
    echo
  else
    log_warn "未找到节点信息文件，请稍后运行: sb-argo show"
  fi
  
  printf "${BLUE}--- fanout 管理面板 ---${NC}\n"
  local ip bp pw
  ip=$(curl -s --max-time 8 http://api.ipify.org 2>/dev/null || echo "<本机IP>")
  bp=$(cat /var/lib/fanout/basepath 2>/dev/null || echo "未知路径")
  pw=$(cat /var/lib/fanout/password 2>/dev/null || echo "未知密码")
  
  echo "管理地址:  http://${ip}:${FO_WEB_PORT}/${bp}/"
  echo "访问口令:  ${pw}"
  echo "终端命令:  输入 f 打开管理菜单"
  echo
  printf "${YELLOW}使用提示：${NC}\n"
  echo "1. 登录 fanout 面板后，点击"新建出口"选择一个 VPNGate 节点。"
  echo "2. 在"未绑定出口的入站"中找到 vless-ws，将其出口指向刚建好的隧道。"
  echo "3. 客户端连接上面的节点链接，流量即会通过指定的 VPNGate 出口访问外网。"
}

main() {
  bootstrap "$@"
  collect_params
  install_components
  print_summary
}

main "$@"
