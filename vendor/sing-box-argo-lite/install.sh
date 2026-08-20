#!/usr/bin/env bash
set -u

APP_DIR="${HOME}/.local/share/sb-argo"
BIN_DIR="${APP_DIR}/bin"
STATE_DIR="${APP_DIR}/state"
LOG_DIR="${APP_DIR}/logs"
CONFIG_DIR="${HOME}/.config/sb-argo"

MANAGER="${HOME}/.local/bin/sb-argo"
SAVED_CONFIG="${CONFIG_DIR}/config.conf"
SECRET_CONFIG="${CONFIG_DIR}/secrets.conf"

SB_BIN="${BIN_DIR}/sing-box"
CF_BIN="${BIN_DIR}/cloudflared"
SB_CONFIG="${CONFIG_DIR}/sing-box.json"

SB_PID_FILE="${STATE_DIR}/sing-box.pid"
CF_PID_FILE="${STATE_DIR}/cloudflared.pid"
NODE_FILE="${STATE_DIR}/node-info.txt"
SUB_FILE="${STATE_DIR}/subscription.txt"

SB_LOG="${LOG_DIR}/sing-box.log"
CF_LOG="${LOG_DIR}/cloudflared.log"

ACTION="install"
CONF_SOURCE=""

usage() {
  cat <<'EOF'
用法:
  install.sh [-f 配置文件或URL] [install|start|restart|stop|status|show|logs|doctor|update|tg-test|uninstall]

示例:
  bash install.sh
  bash install.sh -f config.conf
  sb-argo show
  sb-argo restart
  sb-argo doctor    # 自愈：进程掉了自动拉起，域名变了自动刷新订阅
  sb-argo tg-test   # 测试 Telegram 节点推送配置
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--config)
      [ "$#" -ge 2 ] || {
        printf '错误: -f 后面缺少配置文件\n' >&2
        exit 1
      }
      CONF_SOURCE="$2"
      shift 2
      ;;
    install|start|restart|stop|status|show|logs|doctor|update|tg-test|uninstall)
      ACTION="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '错误: 未知参数 %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

LOCAL_PORT="${LOCAL_PORT:-40001}"
WS_PATH="${WS_PATH:-}"
UUID="${UUID:-}"
NODE_NAME="${NODE_NAME:-NAT-Argo-VLESS-WS-TLS}"

SUBSCRIBE="${SUBSCRIBE:-true}"
GIST_PUBLIC="${GIST_PUBLIC:-false}"
GIST_ID="${GIST_ID:-}"
GIST_OWNER="${GIST_OWNER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

ENABLE_CRON="${ENABLE_CRON:-true}"
SB_MEMORY="${SB_MEMORY:-18MiB}"
CF_MEMORY="${CF_MEMORY:-24MiB}"
GH_PROXY="${GH_PROXY:-}"
SB_VERSION="${SB_VERSION:-}"
# sing-box 1.12 暂时兼容旧版 domain_strategy 配置；后续迁移配置后可移除。
ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS="${ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS:-true}"
# 自愈：等于 true 时安装器会添加 crontab，定期执行 sb-argo doctor。
# doctor 发现 sing-box 或 cloudflared 挂掉会自动拉起；临时域名变化时自动刷新订阅。
ENABLE_DOCTOR="${ENABLE_DOCTOR:-true}"

# Telegram 节点推送：等于 true 时，每次节点链接更新后自动发到你的 Telegram。
# 安装交互中会询问 Bot Token / Chat ID；Token 保存在 secrets.conf（chmod 600）。
# 留空表示未配置（下次交互安装会询问）；false 表示明确不启用（不再询问）。
TG_NOTIFY="${TG_NOTIFY:-}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

mkdir -p "$BIN_DIR" "$STATE_DIR" "$LOG_DIR" "$CONFIG_DIR" \
  "$(dirname "$MANAGER")"

chmod 700 "$APP_DIR" "$CONFIG_DIR"

fetch() {
  fetch_url="$1"
  fetch_output="$2"

  case "$fetch_url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      fetch_url="${GH_PROXY}${fetch_url}"
      ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-delay 2 \
      --connect-timeout 20 -o "$fetch_output" "$fetch_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=5 --timeout=30 -O "$fetch_output" "$fetch_url"
  else
    printf '错误: 需要 curl 或 wget\n' >&2
    return 1
  fi
}

load_config() {
  [ -s "$SAVED_CONFIG" ] && . "$SAVED_CONFIG"
  [ -s "$SECRET_CONFIG" ] && . "$SECRET_CONFIG"

  [ -n "$CONF_SOURCE" ] || return 0

  case "$CONF_SOURCE" in
    http://*|https://*)
      tmp_conf="${STATE_DIR}/remote-config.$$"
      fetch "$CONF_SOURCE" "$tmp_conf" || return 1
      . "$tmp_conf"
      rm -f "$tmp_conf"
      ;;
    *)
      [ -f "$CONF_SOURCE" ] || {
        printf '错误: 配置文件不存在: %s\n' "$CONF_SOURCE" >&2
        return 1
      }
      . "$CONF_SOURCE"
      ;;
  esac
}

load_config || exit 1

case "$LOCAL_PORT" in
  ''|*[!0-9]*)
    printf '错误: LOCAL_PORT 必须是数字\n' >&2
    exit 1
    ;;
esac

if [ "$LOCAL_PORT" -lt 1024 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
  printf '错误: 无 root 权限时 LOCAL_PORT 应在 1024-65535 之间\n' >&2
  exit 1
fi

pid_running() {
  pid_file="$1"
  [ -s "$pid_file" ] || return 1

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac

  kill -0 "$pid" 2>/dev/null
}

stop_process() {
  pid_file="$1"
  [ -s "$pid_file" ] || return 0

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*)
      rm -f "$pid_file"
      return 0
      ;;
  esac

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true

    count=0
    while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 10 ]; do
      sleep 1
      count=$((count + 1))
    done
  fi

  rm -f "$pid_file"
}

stop_all() {
  stop_process "$CF_PID_FILE"
  stop_process "$SB_PID_FILE"
}

show_status() {
  if pid_running "$SB_PID_FILE"; then
    printf 'sing-box:    running, PID %s\n' "$(cat "$SB_PID_FILE")"
  else
    printf 'sing-box:    stopped\n'
  fi

  if pid_running "$CF_PID_FILE"; then
    printf 'cloudflared: running, PID %s\n' "$(cat "$CF_PID_FILE")"
  else
    printf 'cloudflared: stopped\n'
  fi
}

# ── Telegram 节点推送 ─────────────────────────────────────────────

# save_secret：安全写入 secrets.conf 中的单个键，不覆盖其他键。
# 与 GITHUB_TOKEN 共用 secrets.conf，避免互相覆盖。
save_secret() {
  secret_key="$1"
  secret_value="$2"

  [ -f "$SECRET_CONFIG" ] || : >"$SECRET_CONFIG"
  tmp="${SECRET_CONFIG}.tmp"
  : >"$tmp"

  while IFS= read -r line; do
    case "$line" in
      "${secret_key}="*) continue ;;
    esac
    printf '%s\n' "$line" >>"$tmp"
  done <"$SECRET_CONFIG"

  printf '%s=%s\n' \
    "$secret_key" \
    "$(printf '%q' "$secret_value")" >>"$tmp"

  mv "$tmp" "$SECRET_CONFIG"
  chmod 600 "$SECRET_CONFIG"
}

# tg_send：向已配置的 Telegram 发送一条消息；失败只警告，不中断主流程。
# 需要服务器能访问 api.telegram.org（国内网络可能需要代理，见 README）。
tg_send() {
  tg_message="$1"

  [ "$TG_NOTIFY" = "true" ] || return 0
  [ -n "$TG_BOT_TOKEN" ] || return 0
  [ -n "$TG_CHAT_ID" ] || return 0

  command -v curl >/dev/null 2>&1 || {
    printf '警告: Telegram 推送需要 curl\n' >&2
    return 1
  }

  curl -fsS --max-time 15 \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${tg_message}" \
    --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    >/dev/null 2>&1
}

# tg_send_node：节点链接有变化时推送给用户；链接没变则不打扰。
# 去重依据：state/tg-last-sent 里保存上次已发送的 VLESS_LINK。
tg_send_node() {
  [ "$TG_NOTIFY" = "true" ] || return 0
  [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || return 0
  [ -n "$VLESS_LINK" ] || return 0

  last_sent="${STATE_DIR}/tg-last-sent"
  if [ -s "$last_sent" ] && \
     [ "$(cat "$last_sent" 2>/dev/null || true)" = "$VLESS_LINK" ]; then
    return 0
  fi

  tg_message="🚀 sing-box-argo 节点已更新
名称: ${NODE_NAME}
地址: ${DOMAIN}:443
时间: $(date '+%Y-%m-%d %H:%M:%S')

${VLESS_LINK}

订阅: ${SUB_URL}"

  if tg_send "$tg_message"; then
    printf '%s\n' "$VLESS_LINK" >"$last_sent"
    chmod 600 "$last_sent"
    printf '已将新节点推送到 Telegram\n'
  else
    printf '警告: Telegram 推送失败（网络或配置问题，可用 sb-argo tg-test 检查）\n' >&2
  fi
}

# ask_telegram：安装交互中询问 Telegram 配置并写入文件。
# 仅交互式安装时调用；已配置或明确关闭时不再询问。
ask_telegram() {
  [ -t 0 ] || return 0
  [ "$TG_NOTIFY" = "false" ] && return 0
  [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && return 0

  printf '是否启用 Telegram 节点推送（节点链接更新时自动发给你）？[y/N] '
  read -r tg_ans
  case "$tg_ans" in
    y|Y|yes|YES) ;;
    *)
      TG_NOTIFY=false
      printf '已跳过 Telegram 配置（需要时重新运行安装即可再询问）\n'
      return 0
      ;;
  esac

  if [ -z "$TG_BOT_TOKEN" ]; then
    printf '请输入 Telegram Bot Token（在 @BotFather 创建，输入不显示）: '
    read -r -s TG_BOT_TOKEN
    printf '\n'
    [ -n "$TG_BOT_TOKEN" ] || {
      printf '未输入 Token，跳过 Telegram 配置\n'
      TG_NOTIFY=false
      return 1
    }
    save_secret TG_BOT_TOKEN "$TG_BOT_TOKEN"
  fi

  if [ -z "$TG_CHAT_ID" ]; then
    printf '请现在给这个 bot 发送任意一条消息（如 /start），脚本会自动获取你的 Chat ID...\n'
    TG_CHAT_ID=""
    for tg_i in 1 2 3 4 5 6; do
      sleep 5
      tg_updates="$(
        curl -fsS --max-time 10 \
          "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" \
          2>/dev/null || true
      )"
      TG_CHAT_ID="$(
        printf '%s' "$tg_updates" |
        sed -n \
          's/.*"chat":{[^{]*"id":\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' |
        tail -n 1
      )"
      [ -n "$TG_CHAT_ID" ] && break
      printf '  （尚未收到消息，继续等待，最多 %s 秒）\n' "$(( (6 - tg_i) * 5 ))"
    done

    if [ -z "$TG_CHAT_ID" ]; then
      printf '自动获取超时。请输入 Chat ID 手动填写（@userinfobot 发送 /start 可查）: '
      read -r TG_CHAT_ID
      [ -n "$TG_CHAT_ID" ] || {
        printf '未输入 Chat ID，跳过 Telegram 配置\n'
        TG_NOTIFY=false
        return 1
      }
    fi
  fi

  TG_NOTIFY=true
  save_secret TG_BOT_TOKEN "$TG_BOT_TOKEN"
  printf '已保存 Telegram 配置，发送测试消息...\n'
  tg_send "✅ 配置成功，sing-box-argo 节点推送已启用。之后节点链接更新会自动推送到这里。"
}

case "$ACTION" in
  stop)
    stop_all
    printf '已停止\n'
    exit 0
    ;;
  status)
    show_status
    exit 0
    ;;
  show)
    [ -s "$NODE_FILE" ] && cat "$NODE_FILE" || \
      printf '尚未生成节点，请先运行 sb-argo install\n'
    exit 0
    ;;
  logs)
    printf '%s\n' '----- sing-box -----'
    tail -n 40 "$SB_LOG" 2>/dev/null || true
    printf '%s\n' '----- cloudflared -----'
    tail -n 60 "$CF_LOG" 2>/dev/null || true
    exit 0
    ;;
  tg-test)
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      if tg_send "🧪 测试消息：sing-box-argo Telegram 推送正常"; then
        printf 'Telegram 推送成功\n'
      else
        printf 'Telegram 推送失败\n' >&2
        exit 1
      fi
    else
      printf '未配置 Telegram，请运行 bash install.sh（交互式安装）或在 %s 中手动添加\n' "$SECRET_CONFIG" >&2
      exit 1
    fi
    exit 0
    ;;
  uninstall)
    stop_all
    rm -rf "$APP_DIR" "$CONFIG_DIR"
    rm -f "$MANAGER"
    printf '已卸载\n'
    exit 0
    ;;
esac

command -v tar >/dev/null 2>&1 || {
  printf '错误: 服务器缺少 tar\n' >&2
  exit 1
}

case "$(uname -m)" in
  x86_64|amd64)
    SB_ARCH="amd64"
    CF_ARCH="amd64"
    ;;
  aarch64|arm64)
    SB_ARCH="arm64"
    CF_ARCH="arm64"
    ;;
  armv7l|armv7)
    SB_ARCH="armv7"
    CF_ARCH="arm"
    ;;
  i386|i686)
    SB_ARCH="386"
    CF_ARCH="386"
    ;;
  *)
    printf '错误: 不支持的架构 %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

install_manager() {
  source_file="${BASH_SOURCE[0]}"

  if [ "$source_file" != "$MANAGER" ] && [ -r "$source_file" ]; then
    cp "$source_file" "$MANAGER"
    chmod 700 "$MANAGER"
  fi
}

# 检测系统是否使用 musl libc（Alpine 等）。
# sing-box 官方 release 分 glibc / musl 两种构建，
# glibc 动态链接版在 musl 系统上会报 "cannot execute: required file not found"。
is_musl() {
  compgen -G "/lib/ld-musl-*.so.1" >/dev/null 2>&1 && return 0
  compgen -G "/usr/lib/ld-musl-*.so.1" >/dev/null 2>&1 && return 0
  grep -qi '^ID=alpine' /etc/os-release 2>/dev/null && return 0
  return 1
}

download_binaries() {
  force="$1"

  # musl 系统上已存在的二进制若无法运行（例如旧脚本下错成 glibc 构建），
  # 必须强制重下，否则 -x 检查会误判为"已有"而跳过。
  sb_bin_broken=false
  if is_musl && [ -x "$SB_BIN" ] && ! "$SB_BIN" version >/dev/null 2>&1; then
    sb_bin_broken=true
    printf '已存在的 sing-box 无法运行，重新下载 musl 构建...\n'
    rm -f "$SB_BIN"
  fi

  if [ "$force" = "true" ] || [ ! -x "$SB_BIN" ] || [ "$sb_bin_broken" = "true" ]; then
    printf '正在获取 sing-box...\n'

    if [ -z "$SB_VERSION" ]; then
      release_json="${STATE_DIR}/sing-box-release.json"

      fetch \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        "$release_json" || return 1

      SB_VERSION="$(
        sed -n \
          's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' \
          "$release_json" |
        head -n 1
      )"
    fi

    [ -n "$SB_VERSION" ] || {
      printf '错误: 无法取得 sing-box 版本\n' >&2
      return 1
    }

    sb_variant=""
    if is_musl; then
      sb_variant="-musl"
      printf '检测到 musl libc，改用 sing-box 的 musl 构建\n'
    fi
    package="sing-box-${SB_VERSION}-linux-${SB_ARCH}${sb_variant}.tar.gz"
    archive="${STATE_DIR}/${package}"

    fetch \
      "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${package}" \
      "$archive" || return 1

    member="$(
      tar -tzf "$archive" 2>/dev/null |
      grep -m1 '/sing-box$' || true
    )"
    [ -n "$member" ] || {
      printf '错误: 压缩包内找不到 sing-box 文件\n' >&2
      return 1
    }

    tar -xOzf "$archive" "$member" \
      >"${SB_BIN}.new" || return 1

    chmod 700 "${SB_BIN}.new"
    mv "${SB_BIN}.new" "$SB_BIN"
    rm -f "$archive"
  fi

  if [ "$force" = "true" ] || [ ! -x "$CF_BIN" ]; then
    printf '正在获取 cloudflared...\n'

    fetch \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
      "${CF_BIN}.new" || return 1

    chmod 700 "${CF_BIN}.new"
    mv "${CF_BIN}.new" "$CF_BIN"
  fi
}

if [ "$ACTION" = "update" ]; then
  download_binaries true || exit 1
else
  download_binaries false || exit 1
fi

install_manager

# 仅在交互式安装时询问 Telegram 配置（-f 指定配置或非交互环境自动跳过）。
[ "$ACTION" = "install" ] && ask_telegram

# 配置初始化（模板生成、保存 config.conf、check 校验）只在 install 时执行。
# start/restart/doctor/update 必须保留现有的 sing-box.json：
# 否则每次运行（含 cron 每 2 分钟的 doctor）都会把 fanout 注入的
# socks 出站和路由规则冲成直连模板，面板里的绑定会被反复抹掉。
if [ "$ACTION" = "install" ]; then
if [ -z "$UUID" ]; then
  UUID="$("$SB_BIN" generate uuid)" || exit 1
fi

if [ -z "$WS_PATH" ]; then
  WS_PATH="/${UUID%%-*}-vl"
fi

case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/${WS_PATH}" ;;
esac

case "$WS_PATH" in
  *\"*|*\\*|*" "*)
    printf '错误: WS_PATH 不能包含空格、引号或反斜杠\n' >&2
    exit 1
    ;;
esac

cat >"$SB_CONFIG" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": ${LOCAL_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

chmod 600 "$SB_CONFIG"

cat >"$SAVED_CONFIG" <<EOF
LOCAL_PORT=$(printf '%q' "$LOCAL_PORT")
WS_PATH=$(printf '%q' "$WS_PATH")
UUID=$(printf '%q' "$UUID")
NODE_NAME=$(printf '%q' "$NODE_NAME")
SUBSCRIBE=$(printf '%q' "$SUBSCRIBE")
GIST_PUBLIC=$(printf '%q' "$GIST_PUBLIC")
GIST_ID=$(printf '%q' "$GIST_ID")
GIST_OWNER=$(printf '%q' "$GIST_OWNER")
ENABLE_CRON=$(printf '%q' "$ENABLE_CRON")
SB_MEMORY=$(printf '%q' "$SB_MEMORY")
CF_MEMORY=$(printf '%q' "$CF_MEMORY")
GH_PROXY=$(printf '%q' "$GH_PROXY")
SB_VERSION=$(printf '%q' "$SB_VERSION")
ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=$(printf '%q' "$ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS")
ENABLE_DOCTOR=$(printf '%q' "$ENABLE_DOCTOR")
TG_NOTIFY=$(printf '%q' "$TG_NOTIFY")
TG_CHAT_ID=$(printf '%q' "$TG_CHAT_ID")
EOF

chmod 600 "$SAVED_CONFIG"

env \
  GOMAXPROCS=1 \
  GOMEMLIMIT="$SB_MEMORY" \
  GOGC=25 \
  GODEBUG=madvdontneed=1 \
  ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS="$ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS" \
  "$SB_BIN" check -c "$SB_CONFIG" || {
    printf '错误: sing-box 配置检查失败\n' >&2
    exit 1
  }
fi

# ── 启动进程（standalone，供 install/restart/doctor 复用）───────────

# start_singbox：只启动 sing-box，不影响 cloudflared，域名保持不变。
start_singbox() {
  printf '正在启动 sing-box...\n'

  nohup env \
    GOMAXPROCS=1 \
    GOMEMLIMIT="$SB_MEMORY" \
    GOGC=25 \
    GODEBUG=madvdontneed=1 \
    ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS="$ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS" \
    "$SB_BIN" run -c "$SB_CONFIG" \
    </dev/null >>"$SB_LOG" 2>&1 &

  printf '%s\n' "$!" >"$SB_PID_FILE"

  sleep 2

  if ! pid_running "$SB_PID_FILE"; then
    tail -n 40 "$SB_LOG" >&2 || true
    printf '错误: sing-box 启动失败，可能是内存不足\n' >&2
    return 1
  fi
  return 0
}

# build_vless_link：用当前 DOMAIN 生成 VLESS 链接与本地订阅文件。
# start_cloudflared 与 doctor 从日志恢复域名时都会调用。
build_vless_link() {
  ENCODED_PATH="$(
    printf '%s' "$WS_PATH" |
    sed 's|%|%25|g; s|/|%2F|g; s|?|%3F|g; s|#|%23|g'
  )"

  VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&alpn=http%2F1.1&type=ws&host=${DOMAIN}&path=${ENCODED_PATH}#${NODE_NAME}"

  printf '%s\n' "$VLESS_LINK" |
    base64 |
    tr -d '\r\n' >"$SUB_FILE"

  printf '\n' >>"$SUB_FILE"
  chmod 600 "$SUB_FILE"

  SUB_URL="未发布在线订阅"

  # 订阅/节点链接更新后推送 TG（含 install/restart/doctor/start 等所有路径）。
  # tg_send_node 自带去重：链接没变不打扰，只有真的换了域名才发送。
  tg_send_node
}

# start_cloudflared：启动 cloudflared 并等待临时域名；域名写入全局 DOMAIN/VLESS_LINK。
# cloudflared 重启后 trycloudflare 域名会变化。
start_cloudflared() {
  printf '正在启动 Cloudflare 临时隧道...\n'

  : >"${STATE_DIR}/cloudflared-empty.yml"

  # 必须清空旧日志再启动：trycloudflare 域名在旧日志里残留，
  # 不清的话下面的等待循环第一轮就会从旧日志提取到旧域名并立即 break，
  # 新进程分配的新域名反而永远不会被读到，订阅会被写成失效的旧地址。
  : >"$CF_LOG"

  nohup env \
    GOMAXPROCS=1 \
    GOMEMLIMIT="$CF_MEMORY" \
    GOGC=25 \
    GODEBUG=madvdontneed=1 \
    "$CF_BIN" tunnel \
      --config "${STATE_DIR}/cloudflared-empty.yml" \
      --no-autoupdate \
      --protocol http2 \
      --url "http://127.0.0.1:${LOCAL_PORT}" \
    </dev/null >>"$CF_LOG" 2>&1 &

  printf '%s\n' "$!" >"$CF_PID_FILE"

  DOMAIN=""
  count=0

  while [ "$count" -lt 60 ]; do
    if ! pid_running "$CF_PID_FILE"; then
      tail -n 60 "$CF_LOG" >&2 || true
      printf '错误: cloudflared 已退出\n' >&2
      return 1
    fi

    DOMAIN="$(
      sed -n \
        's|.*https://\([A-Za-z0-9-]*\.trycloudflare\.com\).*|\1|p' \
        "$CF_LOG" |
      tail -n 1
    )"

    [ -n "$DOMAIN" ] && break

    count=$((count + 1))
    sleep 1
  done

  if [ -z "$DOMAIN" ]; then
    tail -n 60 "$CF_LOG" >&2 || true
    printf '错误: 60 秒内没有取得临时域名\n' >&2
    return 1
  fi

  build_vless_link
  return 0
}

if [ "$ACTION" = "install" ] || [ "$ACTION" = "restart" ] || [ "$ACTION" = "start" ] || [ "$ACTION" = "doctor" ]; then
  need_sb=false
  need_cf=false
  pid_running "$SB_PID_FILE" || need_sb=true
  pid_running "$CF_PID_FILE" || need_cf=true

  # start：两个都在运行则直接显示状态并退出（不改动域名）。
  # restart：整组重建。
  # doctor：只拉起缺失的成员，尽量不动 cloudflared（避免域名变化）。
  if [ "$ACTION" = "start" ] && [ "$need_sb" = false ] && [ "$need_cf" = false ]; then
    show_status
    [ -s "$NODE_FILE" ] && cat "$NODE_FILE"
    exit 0
  fi

  if [ "$ACTION" = "install" ] || [ "$ACTION" = "restart" ]; then
    stop_all
    : >"$SB_LOG"
    : >"$CF_LOG"
    start_singbox || exit 1
    start_cloudflared || exit 1
  elif [ "$ACTION" = "doctor" ]; then
    if [ "$need_sb" = false ] && [ "$need_cf" = false ]; then
      printf 'sb-argo: 全部正常\n'
      show_status
      exit 0
    fi
    [ "$need_sb" = true ] && printf 'sing-box 未运行，正在拉起...\n'
    [ "$need_cf" = true ] && printf 'cloudflared 未运行，正在拉起（临时域名会变化并自动刷新订阅）...\n'
    [ "$need_sb" = true ] && { start_singbox || exit 1; }
    [ "$need_cf" = true ] && { start_cloudflared || exit 1; }

    # cloudflared 未重启时（只拉起了 sing-box），从日志恢复当前域名，
    # 避免 node-info / 订阅被写成空地址。
    if [ "$need_cf" = false ]; then
      DOMAIN="$(
        sed -n \
          's|.*https://\([A-Za-z0-9-]*\.trycloudflare\.com\).*|\1|p' \
          "$CF_LOG" |
        tail -n 1
      )"
      [ -n "$DOMAIN" ] && build_vless_link
    fi
  fi
fi

publish_gist() {
  command -v curl >/dev/null 2>&1 || {
    printf '警告: 发布 Gist 订阅需要 curl\n' >&2
    return 1
  }

  if [ -z "$GITHUB_TOKEN" ] && [ -t 0 ]; then
    printf '请输入具有 gist 权限的 GitHub Token（输入不显示）: '
    read -r -s GITHUB_TOKEN
    printf '\n'
  fi

  [ -n "$GITHUB_TOKEN" ] || {
    printf '警告: 未提供 GitHub Token，只生成本地订阅文件\n' >&2
    return 1
  }

  save_secret GITHUB_TOKEN "$GITHUB_TOKEN"

  sub_content="$(tr -d '\r\n' <"$SUB_FILE")"
  payload="${STATE_DIR}/gist-payload.json"

  cat >"$payload" <<EOF
{
  "description": "sb-argo auto-updated subscription",
  "public": ${GIST_PUBLIC},
  "files": {
    "sub.txt": {
      "content": "${sub_content}"
    }
  }
}
EOF

  response="${STATE_DIR}/gist-response.json"

  if [ -z "$GIST_ID" ]; then
    curl -fsS \
      -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --data-binary "@${payload}" \
      "https://api.github.com/gists" >"$response" || return 1

    GIST_ID="$(
      grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$response" |
      head -n 1 |
      sed 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
    )"
  else
    curl -fsS \
      -X PATCH \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --data-binary "@${payload}" \
      "https://api.github.com/gists/${GIST_ID}" >"$response" || return 1
  fi

  GIST_OWNER="$(
    grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' "$response" |
    head -n 1 |
    sed 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
  )"

  [ -n "$GIST_ID" ] && [ -n "$GIST_OWNER" ] || return 1

  SUB_URL="https://gist.githubusercontent.com/${GIST_OWNER}/${GIST_ID}/raw/sub.txt"

  cat >>"$SAVED_CONFIG" <<EOF
GIST_ID=$(printf '%q' "$GIST_ID")
GIST_OWNER=$(printf '%q' "$GIST_OWNER")
EOF

  chmod 600 "$SAVED_CONFIG"
}

if [ "$SUBSCRIBE" = "true" ]; then
  publish_gist || true
fi

cat >"$NODE_FILE" <<EOF
协议: VLESS
地址: ${DOMAIN}
端口: 443
UUID: ${UUID}
传输: WebSocket
路径: ${WS_PATH}
Host: ${DOMAIN}
TLS: 开启
SNI: ${DOMAIN}

节点链接:
${VLESS_LINK}

订阅链接:
${SUB_URL}
EOF

chmod 600 "$NODE_FILE"

# 节点链接更新后推送到 Telegram（已配置且链接有变化时才发送）
tg_send_node

if [ "$ENABLE_CRON" = "true" ] && command -v crontab >/dev/null 2>&1; then
  cron_boot="@reboot sleep 20; ${MANAGER} start >/dev/null 2>&1"
  cron_doctor="*/2 * * * * ${MANAGER} doctor >/dev/null 2>&1"

  {
    crontab -l 2>/dev/null |
      grep -Fv "${MANAGER} start" |
      grep -Fv "${MANAGER} doctor" || true
    printf '%s\n' "$cron_boot"
    [ "$ENABLE_DOCTOR" = "true" ] && printf '%s\n' "$cron_doctor"
  } | crontab - 2>/dev/null || true
fi

printf '\n'
cat "$NODE_FILE"
printf '\n管理命令:\n'
printf '  %s show\n' "$MANAGER"
printf '  %s status\n' "$MANAGER"
printf '  %s restart\n' "$MANAGER"
printf '  %s logs\n' "$MANAGER"
printf '  %s doctor\n' "$MANAGER"
printf '  %s tg-test\n' "$MANAGER"
printf '  %s stop\n' "$MANAGER"