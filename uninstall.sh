#!/usr/bin/env bash
# argo-fanout 卸载脚本

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { printf "${GREEN}[信息]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[警告]${NC} %s\n" "$*"; }
log_err()  { printf "${RED}[错误]${NC} %s\n" "$*" >&2; }
log_step() { printf "\n${CYAN}==> %s${NC}\n" "$*"; }

ask_confirm() {
  local prompt="$1"
  local answer
  printf "${BOLD}%s (y/n): ${NC}" "$prompt"
  if [ -t 0 ]; then
    read -r answer
  else
    read -r answer </dev/tty
  fi
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

if [ "$EUID" -ne 0 ]; then
  log_err "必须使用 root 权限运行此脚本"
  exit 1
fi

log_step "argo-fanout 卸载向导"

echo "请选择卸载范围："
echo "  1) 仅卸载 fanout (保留 sing-box-argo-lite)"
echo "  2) 仅卸载 sing-box-argo-lite (保留 fanout)"
echo "  3) 完全卸载 (删除 fanout + sing-box-argo-lite)"
echo "  4) 取消"
echo

printf "${BOLD}请输入选项 [1-4]: ${NC}"
if [ -t 0 ]; then
  read -r choice
else
  read -r choice </dev/tty
fi

case "$choice" in
  1)
    UNINSTALL_FANOUT=1
    UNINSTALL_SBA=0
    ;;
  2)
    UNINSTALL_FANOUT=0
    UNINSTALL_SBA=1
    ;;
  3)
    UNINSTALL_FANOUT=1
    UNINSTALL_SBA=1
    ;;
  4)
    log_info "已取消卸载"
    exit 0
    ;;
  *)
    log_err "无效的选项: $choice"
    exit 1
    ;;
esac

# === 卸载 fanout ===
if [ "$UNINSTALL_FANOUT" = "1" ]; then
  log_step "正在卸载 fanout"
  
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet fanout; then
      log_info "停止 fanout 服务..."
      systemctl stop fanout
    fi
    if systemctl is-enabled --quiet fanout 2>/dev/null; then
      systemctl disable fanout
    fi
    if [ -f /etc/systemd/system/fanout.service ]; then
      rm -f /etc/systemd/system/fanout.service
      systemctl daemon-reload
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    if rc-service fanout status >/dev/null 2>&1; then
      rc-service fanout stop
    fi
    if [ -f /etc/init.d/fanout ]; then
      rc-update del fanout default 2>/dev/null || true
      rm -f /etc/init.d/fanout
    fi
  fi
  
  [ -f /usr/local/bin/fanout ] && rm -f /usr/local/bin/fanout
  [ -f /usr/local/bin/f ] && rm -f /usr/local/bin/f
  
  if ask_confirm "是否删除 fanout 数据目录 /var/lib/fanout (包含隧道状态、面板口令等)"; then
    rm -rf /var/lib/fanout
    log_info "已删除 /var/lib/fanout"
  else
    log_warn "保留了 /var/lib/fanout，重新安装时可恢复"
  fi
  
  log_info "fanout 已卸载"
fi

# === 卸载 sing-box-argo-lite ===
if [ "$UNINSTALL_SBA" = "1" ]; then
  log_step "正在卸载 sing-box-argo-lite"
  
  # 尝试查找 sb-argo 命令
  local sb_cmd=""
  for user_home in /root /home/*; do
    [ -d "$user_home" ] || continue
    local candidate="${user_home}/.local/bin/sb-argo"
    if [ -x "$candidate" ]; then
      sb_cmd="$candidate"
      local sb_user=$(stat -c '%U' "$user_home" 2>/dev/null || echo "root")
      break
    fi
  done
  
  if [ -n "$sb_cmd" ]; then
    if [ "$sb_user" = "root" ]; then
      bash "$sb_cmd" uninstall || log_warn "sb-argo uninstall 执行失败，继续手动清理"
    else
      su - "$sb_user" -c "bash '$sb_cmd' uninstall" || log_warn "sb-argo uninstall 执行失败，继续手动清理"
    fi
  else
    log_warn "未找到 sb-argo 命令，尝试手动清理..."
  fi
  
  # 手动清理残留
  for user_home in /root /home/*; do
    [ -d "$user_home" ] || continue
    local state_dir="${user_home}/.local/share/sb-argo"
    local config_dir="${user_home}/.config/sb-argo"
    local bin_file="${user_home}/.local/bin/sb-argo"
    
    if [ -d "$state_dir" ] || [ -d "$config_dir" ] || [ -f "$bin_file" ]; then
      log_info "清理 $user_home 下的 sb-argo 残留..."
      rm -rf "$state_dir" "$config_dir" "$bin_file"
    fi
  done
  
  log_info "sing-box-argo-lite 已卸载"
fi

log_step "卸载完成"

if [ "$UNINSTALL_FANOUT" = "1" ] && [ "$UNINSTALL_SBA" = "1" ]; then
  echo "已完全卸载 argo-fanout 部署的所有组件。"
  if ask_confirm "是否删除安装目录 /opt/argo-fanout"; then
    rm -rf /opt/argo-fanout
    log_info "已删除 /opt/argo-fanout"
  fi
fi
