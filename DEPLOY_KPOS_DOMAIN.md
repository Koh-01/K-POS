# 把 K POS 接到 kpos.koh01.com

这份说明对应当前 Mac 的 Docker Desktop 与本地管理的 Cloudflare Tunnel。

| 项目 | 当前配置 |
| --- | --- |
| 后端容器 | `K_Pos` |
| 本机后端地址 | `http://127.0.0.1:5001` |
| 实际 Docker 部署目录 | `/Users/koh-01/servers/kts-backup-20260804/projects/backend` |
| Tunnel 配置 | `/Users/koh-01/.cloudflared/config.yml` |
| Tunnel ID | `8c749c9e-74a9-43b6-a2d0-1a4b7e656bbb` |
| Admin 登录 | `https://kpos.koh01.com/web/login` |
| App 的 Server URL | `https://kpos.koh01.com` |

## 1. 确认 Docker 后端正常

```sh
docker ps --filter name=K_Pos
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5001/web/login
```

登录页应返回 `200`。

## 2. 配置 Tunnel 入口

在 `~/.cloudflared/config.yml` 的 `ingress:` 下添加下面两行，放在最后的 `http_status:404` 规则之前：

```yaml
  - hostname: kpos.koh01.com
    service: http://localhost:5001
```

这两行已在本次配置中添加。现有其他域名规则保持原样，旧 POS 域名规则也暂时保留。

验证配置：

```sh
cloudflared tunnel --config /Users/koh-01/.cloudflared/config.yml ingress validate
cloudflared tunnel --config /Users/koh-01/.cloudflared/config.yml ingress rule https://kpos.koh01.com/web/login
```

应显示 `OK`，并匹配 `kpos.koh01.com` → `http://localhost:5001`。

这里 cloudflared 运行在 Mac 系统服务中，因此 `localhost:5001` 指向 Mac 上 Docker 发布的端口。如果以后改成容器运行 cloudflared，需要重新检查容器之间的网络地址。

## 3. 配置 Cloudflare DNS

本次已执行：

```sh
cloudflared tunnel route dns 8c749c9e-74a9-43b6-a2d0-1a4b7e656bbb kpos.koh01.com
```

它创建指向现有 Tunnel 的 CNAME。也可以在 Cloudflare → `koh01.com` → DNS → Records 检查：

| 字段 | 值 |
| --- | --- |
| Type | CNAME |
| Name | kpos |
| Target | `8c749c9e-74a9-43b6-a2d0-1a4b7e656bbb.cfargotunnel.com` |
| Proxy status | Proxied，橙色云 |
| TTL | Auto |

不要重复创建同名记录。官方说明：[本地 Tunnel 的 DNS 配置](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/)。

## 4. 配置后端并加载环境变量

以下两份 `.env` 的 `PUBLIC_BASE_URL` 已改为新域名：

- 桌面项目的 `backend/.env`。
- 实际部署目录的 `.env`。

```dotenv
PUBLIC_BASE_URL=https://kpos.koh01.com
```

本次已用现有镜像重新创建后端容器，加载更新后的环境变量：

```sh
cd /Users/koh-01/servers/kts-backup-20260804/projects/backend
docker compose up -d --no-deps --no-build backend
```

`docker restart` 不会加载新的 Compose 环境变量，因此这里使用 `compose up`。这次只重新创建后端；现有数据库和上传图片挂载仍然使用原配置。

## 5. 让 Tunnel 重新读取配置

在 Mac 终端执行：

```sh
sudo launchctl kickstart -k system/com.cloudflare.cloudflared
```

输入 Mac 管理员密码。输入时不会显示字符，输入完按 Enter。不要将密码发送到聊天中。

此服务同时承载其他域名，重启时它们也可能短暂重连。

然后验证：

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://kpos.koh01.com/web/login
```

应返回 `200`。浏览器打开 `https://kpos.koh01.com/web/login`，使用原来的 Admin 账号登录。

若仍返回 `404`，先检查第 2 步的规则匹配结果以及系统服务是否成功重启。若返回 `502`，先检查第 1 步的本机登录页。

## 6. 同步 App 与 Google Drive 配置

App 源代码的默认地址已更新。已经安装的 App 可以在登录页点 **Change server URL**，输入：

```text
https://kpos.koh01.com
```

App 地址不加 `/web/login`。此前保存过的 Server URL 会优先于源代码中的默认值。

如果需要重新打包 APK，可以从桌面项目执行：

```sh
cd /Users/koh-01/Desktop/KTS-POS/app
flutter build apk --release --dart-define=API_BASE_URL=https://kpos.koh01.com
```

APK 尚未在本次域名配置中重新打包。

后端已经启用 Google OAuth。打开 Google Cloud Console，选择现有项目 → Google Auth Platform → Clients → 当前 Web OAuth client，在 **Authorized redirect URIs** 添加并保存：

```text
https://kpos.koh01.com/web/settings/google-drive/callback
```

Google 要求回调地址与授权列表完全一致；域名改动后需要同步此地址。现有旧回调可暂时保留。[Google OAuth 官方说明](https://developers.google.com/identity/protocols/oauth2/web-server)。

## 配置备份

修改前已在实际部署目录和 Tunnel 配置目录分别生成 `.before-kpos-*` 备份。后端 `.env` 备份包含密钥，应与原 `.env` 一样妥善保管。
