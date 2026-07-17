# Security

本项目会处理可用于登录迅雷账号的 OAuth Token。请遵守以下原则：

- 永远不要提交 `state.json`、Refresh Token、Access Token、真实设备 ID 或调试响应。
- 使用 `xunlei-speedup init` 写入凭据，状态文件默认权限为 `600`。
- 如果凭据曾出现在公开仓库、聊天记录或日志中，立即重新登录或刷新以轮换 Token。
- 提交安全问题时，请先遮盖 Token、Cookie、用户 ID、手机号和设备信息。

安全问题请通过 GitHub 私密漏洞报告功能提交；不要在公开 Issue 中附带凭据。
