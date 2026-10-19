# 代码结构（2026-10-16）

Hermes 安卓客户端：Flutter 写的**远程网关客户端**（不是本地推理），后端是本机 Hermes 的
`tui_gateway`（WebSocket JSON-RPC + 少量 REST）。

## 目录约定

```
lib/                Dart 源码（保持扁平，见下）
test/               无头测试 —— 139 项，含逐条回归；改任何渲染/协议逻辑先跑它
tool/               开发脚本（Flutter 官方约定的脚本目录名）
  build-apk.sh        构建 + 当场核验（版本/A​​BI/签名/sha256）+ 写 dist/<包名>.json
  release.sh          出一批可交付包（正式 + 离线演示）并投递到共享目录
  run-on-emulator.sh  起模拟器 + 安装 + 启动（含三条血泪参数）
  drive.py            模拟器读屏/点按（uiautomator dump → 坐标）
  core-forensics.py   模拟器崩了以后的 core dump 取证（不需要 gdb）
docs/               全部文档
  ARCHITECTURE.md     本文件
  BUILDING.md         构建环境（国内镜像、内存、NDK 等）
  RELEASING.md        版本号/产物命名/校验/manifest 规范
  EMULATOR.md         模拟器验收配方 + 已知坑
  TAILSCALE.md        远程访问
dist/               构建产物（gitignore）：<包名>.apk + <包名>.json 清单 + SHA256SUMS
android/            平台工程（本地镜像与内存 tweak 用 git update-index --skip-worktree 挡在提交外）
desktop-plugin/     上游带的桌面插件（命令面板里"把会话拉到本机"）
```

## 为什么 `lib/` 保持扁平

8.4k 行的 Dart 里，`main.dart`（UI）、`store.dart`（状态机 + 事件推导）、`design.dart`（设计系统）、
`api.dart`（传输）职责已经清楚，文件头都有分节注释；拆子目录只会产生大规模 import 改动，
而收益（可读性）靠文件头注释和 `test/` 的回归已经拿到。真要拆，先补一轮测试再动。

| 文件 | 职责 |
|---|---|
| `main.dart` | 全部页面/组件：Boot/Login/Home/ChatView/MessageTile/RequestCard/Composer/各 Sheet |
| `store.dart` | `HermesStore`：会话状态机、事件→聊天项推导、后台活动、clarify/approval 回执 |
| `design.dart` | 设计系统：DGlass/DBtn/DStepRow/DPayload/DChoice/BackgroundStrip… |
| `api.dart` | `HermesApi`（REST + cookie）+ `Gateway`（WS JSON-RPC、重连、ticket） |
| `l10n.dart` | 轻量本地化：键=阿语原文，zh/en 两张表（缺键有测试门禁） |
| `connections.dart` | 多网关保存/切换 |
| `notify.dart` / `background.dart` / `background_connection.dart` | 本地通知 + 前台服务连接 |
| `demo.dart` | 离线演示/取证模式（`--dart-define=HERMES_DEMO=true`，不连服务器） |

## 关键协议（客户端要对齐的服务端约定）

| 事件/请求 | 关键点（2026-10-16 核对 `tui_gateway/contracts/`） |
|---|---|
| `clarify` 回执 | 必须 `{"answers": {qid: 值}}`；**没有 `answers` 字段 = 全部取消** |
| `approval` 回执 | `{"choice": "once"/"session"/"always"/"deny"}` |
| `tool.start` / `tool.complete` | 入参 `args_text`/`args`；返回值 `result_text`/`result`/`inline_diff` |
| `message.interim` | 工具调用前后的旁白；一轮里可以有多段文字，各自一条气泡 |
| `message.complete` | `response_previewed=true` 表示这段已作为 interim 交付过，别重复写 |
| `process.list` | **"运行中 + 刚结束"**的进程都在（所以后台面板的行要跟着它的报告走，别自己定时删） |
| `subagent.list` / `subagent.tail` | 名录 + 某个子代理的实时 transcript（16KB 尾巴） |
| 历史 | `GET /api/sessions/{id}/messages?limit=300&order=latest`（升序返回；tool 行 `content` 是返回值原文） |
