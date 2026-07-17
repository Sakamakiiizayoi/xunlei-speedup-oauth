# xunlei-speedup-oauth

通过迅雷网页 OAuth 登录凭据，以纯 Shell 方式调用迅雷快鸟宽带提速/试用接口。

脚本会自动完成：

```text
账号中心 Refresh Token
  → 刷新账号中心 Access Token，并保存轮换后的 Refresh Token
  → 生成 PKCE 参数
  → 获取快鸟 OAuth 授权码
  → 兑换快鸟 Access Token
  → 调用快鸟开通/试用接口
```

> [!WARNING]
> 这是非官方项目，接口可能随时变更。请仅用于自己的迅雷账号和宽带线路，并遵守相关服务条款。

## 特性

- 纯 `bash + curl + jq + openssl`
- 使用网页 OAuth/PKCE 流程，不保存迅雷账号密码
- 自动处理 Refresh Token 轮换
- 状态文件原子更新，避免写坏凭据
- 使用 `flock` 防止并发运行导致令牌冲突
- 支持调试响应保存、状态查看和单独测试刷新

## 环境要求

已在 Debian 12 LXC 中验证。

```bash
apt update
apt install -y bash curl jq openssl util-linux
```

其他 Linux 发行版也可以使用，但必须通过 Bash 运行。OpenWrt 默认的 `ash` 不能直接运行本脚本。

## 安装

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Sakamakiiizayoi/xunlei-speedup-oauth/main/xunlei-speedup.sh \
  -o /usr/local/bin/xunlei-speedup

chmod 755 /usr/local/bin/xunlei-speedup
```

也可以克隆仓库后安装：

```bash
git clone https://github.com/Sakamakiiizayoi/xunlei-speedup-oauth.git
cd xunlei-speedup-oauth
install -m 755 xunlei-speedup.sh /usr/local/bin/xunlei-speedup
```

## 获取首次凭据

首次初始化需要：

1. 迅雷账号中心的 `refresh_token`
2. 同一登录会话使用的 `x-device-id`
3. `x-device-sign`，可选，通常可以先留空尝试

### 获取 Refresh Token

1. 在浏览器登录迅雷账号中心。
2. 打开开发者工具（F12）。
3. 进入 **Application → Local Storage → `https://i.xunlei.com`**。
4. 找到：

```text
credentials_XW5SkOhLDjnOZP7J
```

5. 从对应 JSON 中复制 `refresh_token`。

### 获取 x-device-id

1. 在开发者工具打开 **Network**。
2. 查找发往 `xluser-ssl.xunlei.com` 的登录、用户信息或 Token 请求。
3. 在请求头中复制 `x-device-id`。

Refresh Token、Access Token 和设备信息都属于敏感登录凭据，不要上传到 GitHub、Issue、聊天记录或公开日志。

## 初始化

```bash
xunlei-speedup init
```

按照提示输入：

```text
x-device-id
x-device-sign（可直接回车留空）
refresh_token
```

状态默认保存在：

```text
~/.local/state/xunlei-speedup-oauth/state.json
```

文件权限会设置为 `600`。服务端刷新时可能返回新的 Refresh Token，脚本会立即原子写回状态文件。以后不要恢复或复用旧 Token。

## 使用

完整执行：

```bash
xunlei-speedup
```

或：

```bash
xunlei-speedup run
```

查看状态，不显示完整 Token：

```bash
xunlei-speedup status
```

只测试账号中心 Refresh Token 刷新：

```bash
xunlei-speedup refresh
```

查看帮助：

```bash
xunlei-speedup --help
```

## 调试

```bash
XL_DEBUG=1 xunlei-speedup
```

响应默认保存到：

```text
~/.local/state/xunlei-speedup-oauth/debug/
```

调试文件可能包含敏感凭据，排查完成后及时删除，不要提交到仓库。

## 定时运行

### Cron

示例位于 [`examples/cron.example`](examples/cron.example)。例如：

```cron
15 3 * * * HOME=/root /usr/local/bin/xunlei-speedup >>/var/log/xunlei-speedup.log 2>&1
```

### systemd timer

示例位于 [`examples/systemd/`](examples/systemd/)。安装后执行：

```bash
cp examples/systemd/xunlei-speedup.service /etc/systemd/system/
cp examples/systemd/xunlei-speedup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now xunlei-speedup.timer
systemctl list-timers xunlei-speedup.timer
```

请根据实际试用额度重置时间调整。避免多个 cron、systemd timer 或手动任务同时运行同一状态文件。

## 可用环境变量

| 变量 | 说明 |
| --- | --- |
| `XL_STATE_FILE` | 自定义状态文件路径 |
| `XL_DEBUG_DIR` | 自定义调试响应目录 |
| `XL_DEVICE_ID` | 首次导入 `x-device-id` |
| `XL_ACCOUNT_DEVICE_SIGN` | 首次导入 `x-device-sign` |
| `XL_ACCOUNT_REFRESH_TOKEN` | 首次导入账号中心 Refresh Token |
| `XL_ACCOUNT_CLIENT_ID` | 覆盖账号中心 Client ID |
| `XL_SPEEDUP_CLIENT_ID` | 覆盖快鸟网页 Client ID |
| `XL_DEBUG=1` | 保存各步骤响应 |

使用环境变量初始化的例子：

```bash
XL_DEVICE_ID='你的设备ID' \
XL_ACCOUNT_REFRESH_TOKEN='你的最新RefreshToken' \
xunlei-speedup
```

首次成功运行后，以状态文件中自动轮换后的 Refresh Token 为准。

## 常见返回

- `ret=0`：开通/试用成功
- `ret=11`、`error_code=6005`：当天试用机会已用完
- `ret=16`：快鸟登录鉴权失败

HTTP 200 只代表接口请求成功，最终结果应以响应 JSON 中的 `ret` 和 `msg` 为准。

## 安全建议

- 不要在命令行参数、Shell 历史或公开日志中写入 Token。
- 不要提交 `state.json`、`.env` 或 `debug/`。
- 定期确认状态文件权限为 `600`。
- 如果 Token 曾经公开泄露，重新登录或再次刷新以轮换凭据。
- 使用专用低权限系统用户运行比长期使用 root 更安全。

## 免责声明

本项目仅用于技术研究和个人自动化。作者不保证接口持续可用，也不对账号限制、提速失败、Token 失效或其他后果负责。

## License

[MIT](LICENSE)
