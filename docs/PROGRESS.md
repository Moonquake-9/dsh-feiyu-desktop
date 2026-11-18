# 交接文档 · 鱼的心情桌面挂件（给"另一个我"看的）

> 最后更新：2026-11-12 · 挂件 build 28 · 仓库 `Moonquake-9/dsh-feiyu-desktop`（公开，MIT）
> 如果你是在另一个工作区拿到这份文档：读完这一页就能接手，不用翻聊天记录。

## 1. 这是什么

给 DeepSeek Harness 做的**桌面陪伴挂件**：一只会读心情、有自己的情绪和记忆、能在桌面上直接聊天的小鲸鱼少女。
不是 DSH 插件形态的网页挂件，而是独立的 WPF 桌面窗口（PowerShell 5.1 脚本驱动），外加一个 DSH 插件把她的"最近记忆/日程"喂给聊天模型。

- 上游基础：`Yuuyuko-uu/dsh-feiyu-mood`（MIT）——我们用了它的 5 张立绘表情和"心情"概念。
- 我们新增：桌面挂件本体、情绪/记忆/主动性/时间感知/日历提醒、聊天桥插件、多尺寸图标与安装脚本。
- 上游插件版本：`dsh-feiyu-mood` **0.9.2**（安装方式 `github:Yuuyuko-uu/dsh-feiyu-mood#v0.9.2`）。

## 2. 文件在哪（最重要的三处）

| 用途 | 路径 |
| --- | --- |
| 正在运行的挂件（live，改了立刻生效需重启） | `<workspace>\feiyu-desktop\FeiyuMoodDesktop.ps1` |
| 公开仓库（提交/推送用） | `<workspace>\dsh-feiyu-desktop\` |
| 聊天桥插件源码 | `<workspace>\dsh-feiyu-bridge\` |

流程：改 live → 跑 `powershell.exe -File <workspace>\dsh-feiyu-desktop\scripts\sync-from-live.ps1`（把 live 拷进仓库）→ 提交 → 用户在 GitHub Desktop 点 **Push origin**（他没有命令行 push 习惯）。

其它常看的：

- 她的记忆/情绪：`<workspace>\feiyu-desktop\bridge\{memory.json, emotion.json, agenda.json, alive.json, bridge.log}`
- 设置：`<workspace>\feiyu-desktop\pet-settings.json`；日历源：`calendar.json`（含订阅链接，已 gitignore，别提交）
- 挂件日志：`<workspace>\feiyu-desktop\_boot.log`（自收敛，>256KB 保留最近 1200 行）
- 版本号：`version.json` 的 `build`，在"她的设置"窗底部和托盘提示里显示 `v1.0.0 · build N`

## 3. 已经做完的功能（按用户能感知的顺序）

1. **桌面常驻**：透明置顶、拖动吸附屏幕边缘、自动记住位置；在屏幕左半边时自动左右镜像（面向屏幕中心）。
2. **聊天**：左键单击她 → 弹出输入条；再点空白处收起。回复逐字出现在头顶气泡里，气泡会按优先级避让输入条/面板。桥插件把请求写成文件、模型回包再写回（`inbox/outbox`），所以 DSK 窗口关掉也能聊——只要 Host 在后台跑。
3. **情绪**：七维情绪（开心/踏实/甜蜜/心疼/担心/难过/吃醋）+ 亲密度 + 精力 + 关系（还不太熟→渐渐熟了→很亲近→黏着你）。数据来自桌面聊天本身，不是 DSH 会话；睡一夜只回落不归零（半衰期 7 小时，另有按亲密度的保底值）。
4. **记忆**：热层 40 轮 + 温层最多 12 条要点（每 8 轮用模型压缩一次），落盘 `memory.json`。
5. **主动性**：安静约 25 分钟（随机 17–35）会自己开口；聊完 7–16 分钟会追问一句；你说话时会记下"我要去开会/吃饭/上课"，之后会问"会开完了吧"，同一件事最多问 2 次、间隔 ≥90 分钟。
6. **时间感知**：聊天时注入"现在几点 + 距上次多久"，所以会说"这么晚还不睡""你回来啦"；待机台词按早晚时段分桶；启动时若隔得久会先打招呼。
7. **日历提醒**：设置里填 `.ics` 订阅链接（一行一个 `名称|链接`，也支持本地文件、裸链接自动命名），提前 N 分钟弹气泡提醒；`agenda.json` 同步给桥，所以问她"明天有什么安排"她能答。
8. **打磨项**：全屏应用自动隐藏；托盘退出后不会被看门狗复活（`widget.stopped` 标记）；单实例锁；设置窗（记忆/主动性/英文界面/日历/气泡时长/刷新频率/开机自启/模型）；中英双语（切语言自动重启一次生效）；版本号显示；日志自收敛；桌面快捷方式 + 开机启动。

## 4. 已知坑（踩过，别再踩）

- **PS 5.1 必须 UTF-8 BOM**。用 edit/write 工具直接改 `.ps1` 会写无 BOM，PowerShell 按 GBK 解析 → 中文乱码 + 语法错误。改完必须用 `[System.IO.File]::WriteAllText($p,$s,(New-Object System.Text.UTF8Encoding($true)))` 存。
- **`launch.vbs` 必须是纯 ASCII + CRLF + 无 BOM**，否则 `wscript` 弹 800A0408。
- **别把图标放在 `<workspace>\` 目录里**：该目录被 DSH 沙箱标了低完整性级别 + 拒绝 ACE，Explorer 读不到 ICO，快捷方式会显示白纸。图标统一放 `%LOCALAPPDATA%\FeiyuDesktop\feiyu.ico`（脚本里的 `Ensure-Icon` 会处理）。
- **`ConvertTo-Json` 会毁掉 `[datetime]`**（写成 `\/Date(...)\/`，读回来变 UTC 当本地）。缓存/输出统一先 `.ToString('s')` 存 ISO 字符串。
- **桥插件是"安装时复制"**：改了 `<workspace>\dsh-feiyu-bridge\` 的源码不会自动生效，要 `plugin_manager remove_bundle` + `install_bundle file:<workspace>/dsh-feiyu-bridge` 重装一次（Host 热重载，不用重启）。
- **`sync-from-live.ps1` 要用 `powershell.exe -File` 跑**，用 python/node 拉起不会生效。
- **单实例/看门狗**：桥每 25s 检查 `widget.pid`，进程没了会拉起；但看到 `widget.stopped`（托盘退出写的标记）就跳过。手动 kill 进程调试后，记得删 `widget.lock`/`widget.pid` 再启动。
- **git 身份**：提交时用 `-c user.name=... -c user.email=<your-github-noreply>@users.noreply.github.com` 临时传，不写全局配置。不要用真实邮箱。
- 用户看不到命令行，**推送要靠 GitHub Desktop 点 Push origin**；每次提交后要提醒他。

## 5. 当前待办 / 可选

- [ ] 让用户推最新提交（每次改完都要提醒）。
- [ ] 可选：把当前 DSH 会话绑给 `dsh-feiyu-mood` 的"绑定会话"，让上游判官也跑起来（代价：每轮多一次模型调用）。目前七维情绪走的是我们自己的桌面聊天数据。
- [ ] 可选：把 `v1.0.0` 发成 GitHub Release（本地有 tag，网页上 Release 页面可创建）。
- [ ] 可选：应用内挂饰（网页右上角小挂件）用的是上游 `widget.js`，桌面挂件用的是头像表情，两者形象未统一。

## 6. 快速自检（改完代码必做）

```powershell
# 1) 语法
$f='<workspace>\feiyu-desktop\FeiyuMoodDesktop.ps1'
$err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$err); "errors=$($err.Count)"

# 2) 离屏渲染（不开窗口，产出 _r.png_pet/_panel/_chat/_bubble/_settings/_status）
& 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File $f -Render '<workspace>\feiyu-desktop\_r.png'

# 3) 重启挂件（先杀再起，删锁）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*-File*FeiyuMoodDesktop.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep 2; Remove-Item '<workspace>\feiyu-desktop\widget.lock' -Force -ErrorAction SilentlyContinue
& wscript.exe '<workspace>\feiyu-desktop\launch.vbs'
Get-Content '<workspace>\feiyu-desktop\_boot.log' -Tail 5
```

## 7. 风格约定（用户偏好）

- 回复用中文，别端着；少用"作为 AI"这类词。
- 改完东西先自己验证（渲染截图/日志/实测对话），再报告；报告里给用户"能看见的证据"。
- 用户在意"像真人"：她的语气、主动性、记忆比多一个功能更重要。
- 不要动公众号/隐私类数据；日历订阅链接只存本机（`calendar.json` 已 gitignore）。
