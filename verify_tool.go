// verify_tool.go
//
// 轻量 Ed25519 验签工具，供模块在 Android 上验证服务器下发的 keybox 未被篡改。
// 公钥采用 PHP sodium 生成的 32 字节 Ed25519 公钥（base64 编码），
// 与服务器 manifest//pubkey 端点返回值一一对应。
//
// 编译 (任意装有 Go 的机器):
//   CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o verify_tool verify_tool.go
//
// 用法:
//   verify_tool <pubkey.b64> <signature.b64> <data_file>
//   退出码 0 = 通过, 非 0 = 失败
package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
)

func readTrim(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return []byte(strings.TrimSpace(string(b))), nil
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "用法: verify_tool <pubkey.b64> <signature.b64> <data_file>")
		os.Exit(2)
	}
	pubB64, err := readTrim(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取公钥失败:", err)
		os.Exit(2)
	}
	sigB64, err := readTrim(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取签名失败:", err)
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取数据失败:", err)
		os.Exit(2)
	}

	pub, err := base64.StdEncoding.DecodeString(string(pubB64))
	if err != nil || len(pub) != ed25519.PublicKeySize {
		fmt.Fprintln(os.Stderr, "公钥解析失败（应为 base64 的 32 字节 Ed25519 公钥）")
		os.Exit(2)
	}
	sig, err := base64.StdEncoding.DecodeString(string(sigB64))
	if err != nil {
		fmt.Fprintln(os.Stderr, "签名 base64 解码失败:", err)
		os.Exit(2)
	}
	if ed25519.Verify(pub, data, sig) {
		fmt.Println("OK")
		os.Exit(0)
	}
	fmt.Fprintln(os.Stderr, "签名校验失败")
	os.Exit(1)
}
