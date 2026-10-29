#!/usr/bin/env bash
# 像素工大 · 联机服务器一键部署（Ubuntu / Debian）
#
# 用法（在服务器上，root 执行）：
#   sudo bash install.sh              # 纯 HTTP：http://<服务器IP>/ 就能玩（无需域名/证书）
#   sudo DOMAIN=xgd.example.com bash install.sh   # 有域名：自动申请证书，走 https/wss
#
# 它会做：
#   1. 装 Caddy（反代 + 静态托管，自带自动 HTTPS）
#   2. 建 /opt/xgd/{server,web}，把本目录的 server/ 和 web/ 拷进去
#   3. 注册 systemd 服务 xgd（Godot 无头服务端，监听 127.0.0.1:9080）
#   4. 启动并自检
set -euo pipefail

APP_DIR=/opt/xgd
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="${DOMAIN:-}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 或 sudo 运行" >&2
  exit 1
fi

echo "==> 1/6 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg apt-transport-https

if ! command -v caddy >/dev/null 2>&1; then
  echo "==> 安装 Caddy"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

echo "==> 2/6 建目录与用户"
id -u xgd >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin xgd
mkdir -p "$APP_DIR/server" "$APP_DIR/web"
cp -f "$SRC_DIR/server/xgd-server.x86_64" "$APP_DIR/server/"
cp -rf "$SRC_DIR/web/." "$APP_DIR/web/"
chmod +x "$APP_DIR/server/xgd-server.x86_64"
chown -R xgd:xgd "$APP_DIR"

echo "==> 3/6 注册 systemd 服务"
cat >/etc/systemd/system/xgd.service <<UNIT
[Unit]
Description=XGD Campus 联机服务器 (Godot headless)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xgd
WorkingDirectory=$APP_DIR/server
Environment=HOME=$APP_DIR
ExecStart=$APP_DIR/server/xgd-server.x86_64 --headless --server
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable xgd

echo "==> 4/6 配置 Caddy"
if [ -n "$DOMAIN" ]; then
  SITE="$DOMAIN"
else
  SITE=":80"
fi
cat >/etc/caddy/Caddyfile <<CADDY
$SITE {
	encode gzip

	# 联机走 WebSocket：浏览器 <-> Caddy(443/80) <-> Godot(127.0.0.1:9080)
	handle /ws* {
		reverse_proxy 127.0.0.1:9080
	}

	# 其余都是网页静态文件（Godot 导出的 index.html / .wasm / .pck）
	handle {
		root * $APP_DIR/web
		file_server
	}

	# wasm 体积大，允许浏览器长缓存
	header /index.wasm Cache-Control "public, max-age=31536000, immutable"
	header /index.pck Cache-Control "public, max-age=31536000, immutable"
}
CADDY
caddy fmt --overwrite /etc/caddy/Caddyfile || true

echo "==> 5/6 启动"
systemctl restart xgd
systemctl restart caddy
sleep 3

echo "==> 6/6 自检"
systemctl is-active --quiet xgd && echo "  服务端 xgd: 运行中" || { echo "  服务端没起来，看日志：journalctl -u xgd -n 50"; exit 1; }
systemctl is-active --quiet caddy && echo "  Caddy: 运行中" || { echo "  Caddy 没起来，看日志：journalctl -u caddy -n 50"; exit 1; }
ss -lntp 2>/dev/null | grep -E ':9080|:80 |:443 ' || true

PUBIP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<服务器IP>')"
if [ -n "$DOMAIN" ]; then
  echo
  echo "  完成。访问：https://$DOMAIN/"
else
  echo
  echo "  完成。访问：http://$PUBIP/"
  echo "  （想换 https + 正式域名：重新跑  sudo DOMAIN=你的域名 bash install.sh）"
fi
