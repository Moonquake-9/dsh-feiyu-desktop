# dsh-feiyu-bridge

给 [feiyu-mood 桌面挂件](https://github.com/) 用的**本地聊天后端**：桌面挂件不开 DSH 窗口也能和桌宠说话。

## 它做什么

1. 挂件把一条请求写到 `%DSH_HOME%/feiyu-desktop/bridge/inbox/<id>.json`
2. 本插件每 400ms 扫一次收件箱，用 Host 自己的 `ctx.llm`（也就是你在 DSH 里配的模型）跑一次性调用
3. 回复流式写回 `outbox/<id>.json`，挂件轮询做打字机效果

顺手还写两个文件，方便排查：

- `bridge/alive.json` —— 心跳（`ts`/`pid`），挂件用它判断"桥在不在"
- `bridge/bridge.log` —— 每次问答一行

## 为什么走文件而不是 HTTP

Host 的 `webServer` 是给页面用的，带浏览器会话鉴权；外部进程（我们的 WPF 挂件）直接调要处理 token。文件桥零依赖、不占端口、出错时能直接看文件内容。

## 配置

```yaml
- id: feiyu-bridge
  name: dsh-feiyu-bridge
  config:
    intervalMs: 400      # 扫描间隔
    maxTokens: 600
    temperature: 0.75
    personaModel: ''     # 可选：指定模型 id；留空自动挑 chat/deepseek 类
```

## 前置条件

- DSH 需要在后台运行（插件加载在 Host 里）。挂件检测不到 `alive.json` 时会提示"DSH 没开"。
- 想完全脱离 DSH：在挂件设置里填 DeepSeek 官方 API Key，走直连模式。
