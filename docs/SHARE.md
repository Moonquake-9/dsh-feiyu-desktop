# 分享文案（复制即用）

> 每个平台的语气不同：小红书要"安利感 + 图"，微博要短，X/Reddit 要英文、讲清楚 what/why。
> 所有文案都假设仓库地址是 `https://github.com/Moonquake-9/dsh-feiyu-desktop`。

---

## 1. 一句话版（任何地方都能用）

> 给 DeepSeek Harness 做了一只桌面小鲸鱼：会读 DSH 的心情、有自己的情绪和记忆，不开 DSH 窗口也能在桌面上和她说话。PowerShell + WPF，无安装器，MIT 开源。

英文版：

> A desktop companion for DeepSeek Harness — a little whale girl that mirrors the agent's mood, keeps her own emotions/memory, and talks to you from your Windows desktop without opening the app. PowerShell 5.1 + WPF, MIT.

---

## 2. 小红书版

**标题**（选一个）
- 把 DeepSeek 的心情做成了桌面小鲸鱼 🐳
- 我的 AI 有情绪了，还会在桌面上跟我说话
- 纯手搓：给 DeepSeek Harness 做了一个桌面挂件

**正文**

```
最近在折腾 DeepSeek Harness，顺手把它的「鱼的心情」插件从应用窗口里拎到了桌面上 🐳

现在它是一只一直待在最上层的小鲸鱼：
· 会读 DSH 里的心情值，七根情绪条实时变
· 有自己的亲密度 / 精力 / 关系，会随聊天和搁置慢慢变化，关掉重开也记得
· 点她一下会说话，还能直接打字聊天（不用开 DSH 窗口）
· 拖到屏幕边会自动吸附，全屏看视频/打游戏时自己躲起来
· 右键「她的设置」里能改记忆、自启、气泡时长，还有英文界面

技术上一句话：PowerShell 5.1 + WPF 写的透明置顶窗口，没有安装器、没有 Electron、没有后台服务。
MIT 开源，代码和现成 zip 都在 GitHub（主页有 Release）：

github.com/Moonquake-9/dsh-feiyu-desktop

基于 @Yuuyuko-uu 的 dsh-feiyu-mood 插件改的，立绘和心情系统都是原作者的，我只是把"她"搬到了桌面上 🙏
```

**标签**：`#DeepSeek` `#桌面挂件` `#桌宠` `#AI宠物` `#开源项目` `#独立开发` `#Windows`

**配图顺序**：`docs/social-preview.png`（封面）→ `docs/preview-chat2.png` → `docs/preview-settings.png`

---

## 3. 微博 / 即刻版

```
给 DeepSeek Harness 做了个桌面挂件：一只会读心情、有自己情绪和记忆的小鲸鱼 🐳
点她会说话，也能直接打字聊；拖到边缘自动吸附，全屏时自动隐藏。
PowerShell 5.1 + WPF，无安装器、无 Electron，MIT 开源。
代码 + Release zip：https://github.com/Moonquake-9/dsh-feiyu-desktop
（立绘/心情系统来自 @Yuuyuko-uu 的 dsh-feiyu-mood，我负责把它搬到桌面上）
```

---

## 4. X / Twitter（English）

```
Made a desktop companion for DeepSeek Harness 🐳

A little whale girl that lives on your Windows desktop:
· mirrors the agent's mood (7 emotion bars)
· keeps her own affection / energy / memory across restarts
· click her to talk — no need to open the DSH window
· edge snapping, auto-hide on fullscreen, EN/ZH UI

PowerShell 5.1 + WPF. No installer, no Electron. MIT.

https://github.com/Moonquake-9/dsh-feiyu-desktop

Built on top of @Yuuyuko-uu's dsh-feiyu-mood plugin (art + mood system).
```

---

## 5. Reddit（r/desktopgaming、r/AI_Agents 之类，注意先读版规）

**Title**: `I built a desktop pet for DeepSeek Harness — it mirrors the agent's mood and keeps its own memory`

```
TL;DR: a transparent always-on-top WPF window that reads the DSH agent's mood state file,
plus a tiny bridge plugin so you can chat with the pet inside the DSH host process
(one-shot model calls, doesn't pollute your conversation context).

Features: mood mirror, persistent affection/energy, hot+warm memory layers,
click-to-talk, edge snapping, fullscreen auto-hide, per-pixel click-through, EN/ZH UI.

Stack: PowerShell 5.1 + WPF only (no Electron). MIT licensed.

Repo + prebuilt zip: https://github.com/Moonquake-9/dsh-feiyu-desktop

Credits: built on the dsh-feiyu-mood plugin by Yuuyuko-uu (artwork + mood system are theirs).
```

---

## 6. V2EX / 掘金 / 少数派（偏"工程向"）

**标题**：`用 PowerShell 5.1 + WPF 给 DeepSeek Harness 写了个桌面挂件`

正文开头就把技术点摆出来：

- 透明置顶窗口：`AllowsTransparency` 分层窗，透明像素天然点击穿透（实测 `WindowFromPoint`）
- 心情读取：直接读 `<DSH_HOME>/feiyu-mood/state.json`，1.2s 轮询
- 聊天通道：不占端口，用**文件桥**（`inbox/*.json` → Host 内 `ctx.llm.stream` → `outbox/*.json`），避免 webServer 鉴权问题
- 情绪系统：关键词打标 + 时间漂移 + 落盘，热层（最近 N 轮）+ 温层（模型压缩要点）
- 踩坑：WPF 窗口在 `Application` 之前创建时 `Windows` 集合为空，`ShutdownMode=OnLastWindowClose` 会在关任何对话框时把整个应用退出

---

## 7. 让别人"发现"这个仓库的动作清单

GitHub 侧（一次性，5 分钟）：

1. **Social preview**：仓库 → Settings → General → Social preview → Upload image → 选 `docs/social-preview.png`（1280×640）
   —— 这样别人把链接发到微信/X/Discord 时会显示封面卡片，点开率差很多。
2. **Pin 仓库**：个人主页 → Customize your pins → 勾上 `dsh-feiyu-desktop`（最多 6 个）。
3. **个人简介**：Profile → Edit profile → Bio 里放一行 `Desktop pets for DeepSeek Harness → github.com/Moonquake-9/dsh-feiyu-desktop`。
4. **Release 里加一句**：编辑 v1.0.0 → 末尾加「如果觉得有用，点个 ⭐ 就是最大的鼓励」。
5. **Topics**：已经加好（`dsh-plugin`、`desktop-pet` 等），别人逛 topic 页就能刷到。
6. **README 里加个 star 引导**（本次已加）。

社区侧（选 2–3 个就够，不用全发）：

- DeepSeek Harness 相关的群/Discord/论坛（发"我做了什么 + 一个 15 秒录屏"最有效）
- 小红书 / B 站：**录屏 > 截图**。15 秒就够：桌面出现 → 点她跳一下 → 打字聊天 → 打开设置窗
- V2EX「分享创造」节点、掘金、少数派 Matrix（偏技术，适合讲文件桥和 WPF 坑）
- Reddit 的桌面美化/AI agent 版块（先看版规，别当广告发）
- 投稿到 awesome 列表：搜 `awesome deepseek` / `awesome desktop pets`，按各自 CONTRIBUTING 提 PR

小技巧：

- 发帖时间选晚上 8–11 点；同一份内容**换措辞**再发第二个平台，别复制粘贴（会被限流）
- 每个帖子都带上仓库链接 + 一张封面图；小红书正文里 GitHub 链接容易被折叠，可以放在**评论区第一条**
- 有人问"怎么装"，直接给 Release 页链接，比给 README 更省事
