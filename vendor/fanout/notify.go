package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Telegram 掉线通知。
//
// 用途:fanout 的 SOCKS5 出口掉线(openvpn 断、出口 IP 回落)时,
// 通过 Telegram 推送一条提醒,让运维/用户不用登录面板就能知道。
//
// 配置来源(按优先级):
//   1. 环境变量 FANOUT_TG_BOT_TOKEN / FANOUT_TG_CHAT_ID
//   2. argo-fanout 一键安装写下的 sb-argo 配置:
//        ${HOME}/.config/sb-argo/secrets.conf 的 TG_BOT_TOKEN
//        ${HOME}/.config/sb-argo/config.conf   的 TG_CHAT_ID
// 两者都没配就静默跳过,不影响隧道本身。

const tgAPITimeout = 15 * time.Second

// loadTGConfig 每次调用都重新读配置,改完配置不用重启服务。
// 返回的 token/chatID 为空表示未配置。
func loadTGConfig() (token, chatID string) {
	token = strings.TrimSpace(os.Getenv("FANOUT_TG_BOT_TOKEN"))
	chatID = strings.TrimSpace(os.Getenv("FANOUT_TG_CHAT_ID"))
	if token != "" && chatID != "" {
		return token, chatID
	}

	home := os.Getenv("HOME")
	if home == "" {
		home = "/root"
	}
	confDir := filepath.Join(home, ".config", "sb-argo")

	if token == "" {
		if v := readShellKV(filepath.Join(confDir, "secrets.conf"), "TG_BOT_TOKEN"); v != "" {
			token = v
		}
	}
	if chatID == "" {
		if v := readShellKV(filepath.Join(confDir, "config.conf"), "TG_CHAT_ID"); v != "" {
			chatID = v
		}
	}
	return token, chatID
}

// readShellKV 从 bash 风格 KEY='value' 的配置文件里取一个键的值。
// 找不到键或文件不存在都返回空串。
func readShellKV(path, key string) string {
	blob, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	prefix := key + "="
	for _, line := range strings.Split(string(blob), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		val := strings.TrimPrefix(line, prefix)
		val = strings.Trim(val, "'\"")
		return strings.TrimSpace(val)
	}
	return ""
}

// sendTG 发一条 Telegram 消息;未配置或发送失败只记日志,不影响主流程。
// 异步调用方自行 go 出去,这里不做并发保护(短小幂等)。
func sendTG(text string) {
	token, chatID := loadTGConfig()
	if token == "" || chatID == "" {
		return
	}

	payload, err := json.Marshal(map[string]string{
		"chat_id":                  chatID,
		"text":                     text,
		"disable_web_page_preview": "true",
	})
	if err != nil {
		return
	}

	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: tgAPITimeout}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("TG 通知发送失败: %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("TG 通知发送失败: HTTP %d", resp.StatusCode)
	}
}
