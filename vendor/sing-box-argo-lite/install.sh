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
  install.sh [-f 配置文件或URL] [install|start|restart|stop|status|show|logs|update|uninstall]

示例:
  bash install.sh
  bash install.sh -f config.conf
  sb-argo show
  sb-argo restart
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
    install|start|restart|stop|status|show|logs|update|uninstall)
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

if [ "$ACTION" = "start" ] &&
   pid_running "$SB_PID_FILE" &&
   pid_running "$CF_PID_FILE"; then
  show_status
  [ -s "$NODE_FILE" ] && cat "$NODE_FILE"
  exit 0
fi

stop_all
: >"$SB_LOG"
: >"$CF_LOG"

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
  exit 1
fi

printf '正在启动 Cloudflare 临时隧道...\n'

: >"${STATE_DIR}/cloudflared-empty.yml"

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
    exit 1
  fi

  DOMAIN="$(
    sed -n \
      's|.*https://\([A-Za-z0-9-]*\.trycloudflare\.com\).*|\1|p' \
      "$CF_LOG" |
    head -n 1
  )"

  [ -n "$DOMAIN" ] && break

  count=$((count + 1))
  sleep 1
done

if [ -z "$DOMAIN" ]; then
  tail -n 60 "$CF_LOG" >&2 || true
  printf '错误: 60 秒内没有取得临时域名\n' >&2
  exit 1
fi

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

  cat >"$SECRET_CONFIG" <<EOF
GITHUB_TOKEN=$(printf '%q' "$GITHUB_TOKEN")
EOF
  chmod 600 "$SECRET_CONFIG"

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

if [ "$ENABLE_CRON" = "true" ] && command -v crontab >/dev/null 2>&1; then
  cron_line="@reboot sleep 20; ${MANAGER} start >/dev/null 2>&1"

  {
    crontab -l 2>/dev/null |
      grep -Fv "${MANAGER} start" || true
    printf '%s\n' "$cron_line"
  } | crontab - 2>/dev/null || true
fi

printf '\n'
cat "$NODE_FILE"
printf '\n管理命令:\n'
printf '  %s show\n' "$MANAGER"
printf '  %s status\n' "$MANAGER"
printf '  %s restart\n' "$MANAGER"
printf '  %s logs\n' "$MANAGER"
printf '  %s stop\n' "$MANAGER"