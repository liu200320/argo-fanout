package main

import "testing"

// exitIPStillOnVPN 决定"探测到的出口 IP 是否还说明流量走在 VPN 上"：
// 只要不是母机公网 IP 就算健康（容忍 VPN Gate 多出口/负载均衡的 IP 漂移），
// 只有退回母机 IP 才算掉线；母机 IP 未知时不强判。
func TestExitIPStillOnVPN(t *testing.T) {
	cases := []struct {
		name string
		got  string
		host string
		want bool
	}{
		{"同母机IP=掉线", "1.2.3.4", "1.2.3.4", false},
		{"不同公网IP=健康", "9.9.9.9", "1.2.3.4", true},
		{"出口IP漂移=健康", "8.8.8.8", "1.2.3.4", true},
		{"母机IP未知不误杀", "1.2.3.4", "", true},
		{"母机IP未知且相同不误杀", "9.9.9.9", "", true},
	}
	for _, c := range cases {
		if got := exitIPStillOnVPN(c.got, c.host); got != c.want {
			t.Errorf("%s: exitIPStillOnVPN(%q, %q) = %v, want %v", c.name, c.got, c.host, got, c.want)
		}
	}
}