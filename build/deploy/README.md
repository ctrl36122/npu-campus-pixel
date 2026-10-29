# 像素工大 · 联机服务器部署包

一套自包含的部署包：**网页（浏览器打开就能玩）+ 联机服务端**，跑在你自己的云主机上。
部署完，别人点一个链接就能进同一个校园，不用装任何东西。

## 目录

```
deploy/
├── install.sh              一键部署脚本（Ubuntu / Debian）
├── server/xgd-server.x86_64  Godot 无头服务端（Linux x86_64，86MB，数据已内嵌）
├── web/                    网页版（index.html / index.wasm / index.pck）
└── README.md               本文件
```

## 服务器要求

| 项目 | 要求 |
|---|---|
| 系统 | Ubuntu 20.04 / 22.04 / 24.04 或 Debian 11+ |
| 配置 | **1 核 1G 起步，2 核 2G 更稳**（服务端不渲染画面） |
| 端口 | 安全组放行 **80**（有域名再放 443） |
| 磁盘 | 500MB 够用 |

> 9080 端口不需要对外开放 —— 服务端只监听本机，由 Caddy 反代过去。

## 部署（三步）

**1. 上传**

```bash
# 在你自己的电脑上（不是服务器），把整个 deploy 目录传上去
scp -r deploy root@<服务器IP>:/root/
```

**2. 登录服务器，跑脚本**

```bash
ssh root@<服务器IP>
cd /root/deploy

# 没有域名（推荐先这样，立刻能用）
sudo bash install.sh

# 或者有域名（先在 DNS 加一条 A 记录指向服务器 IP）
sudo DOMAIN=xgd.example.com bash install.sh
```

**3. 打开**

- 无域名：`http://<服务器IP>/`
- 有域名：`https://xgd.example.com/`

网页会自动连**同一个域名下的 `/ws`**（也就是这台服务器上的联机服务端），
不需要配置任何服务器地址。

## 验证是否成功

```bash
systemctl status xgd        # 服务端在跑
journalctl -u xgd -n 30     # 应该能看到 "hosting WebSocket :9080"
ss -lntp | grep 9080        # 端口在监听
```

浏览器打开网址后，右上角应该显示「在线 1/32 · 你的昵称 · 我」。
再换一台设备（或手机）打开同一个网址，人数会变 2/32，两个人能互相看见。

## 常用维护

```bash
systemctl restart xgd       # 重启服务端（改了配置/换二进制）
systemctl restart caddy     # 重启反代
journalctl -u xgd -f        # 实时看服务端日志
```

换新版本（比如游戏更新了）：把新的 `server/xgd-server.x86_64` 和 `web/` 覆盖到
`/opt/xgd/` 下，然后 `systemctl restart xgd` 即可。

## 常见问题

**Q：没域名能用吗？**
能。默认就是纯 HTTP（`http://IP/`），游戏是单线程 wasm，不需要 https 特有能力。
缺点是浏览器地址栏会显示"不安全"，部分公共网络可能拦 HTTP。

**Q：想换正式域名 / 加 HTTPS？**
DNS 加一条 A 记录指向服务器 IP，然后重新跑 `sudo DOMAIN=你的域名 bash install.sh`，
Caddy 会自动申请 Let's Encrypt 证书。之后网页走 https，联机自动变成 wss。

**Q：为什么没有 443 也能跑？**
因为目前用的是 HTTP 页面 + ws。一旦用 https 页面，浏览器就只允许 wss，
所以 HTTPS 必须由 Caddy 来终结 TLS（Godot 自身没有 TLS 服务端）。

**Q：最多几个人？**
32（`net/autoload/Net.gd` 的 `MAX_PLAYERS`）。1 核机器建议控制在 10 人以内。

**Q：服务端不渲染，为什么还有 86MB？**
里面是 Godot 引擎 + 整张校园地图数据，只是不画出来 —— 服务端要跑碰撞和玩家位置校验。

**Q：exe 版还能用吗？**
能，两者不冲突。exe 走局域网 ENet 自动发现；网页版走这台服务器。互不相通。
