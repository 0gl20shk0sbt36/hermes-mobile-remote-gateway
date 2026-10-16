# 在模拟器里跑/验收这个 App（2026-10-16 实测走通）

一键：

```bash
tool/run-on-emulator.sh            # 构建 x64 演示包 → 起模拟器 → 安装 → 启动
python3 tool/drive.py texts        # 读屏（按视觉顺序打印所有文字）
python3 tool/drive.py tap 提交回答   # 按文字点
python3 tool/drive.py long 演示会话  # 长按（打开诊断面板）
```

## 三条必须知道的参数（都是踩出来的）

1. **模拟器用 `-gpu swiftshader`**。
   宿主侧软件光栅（SwiftShader/ANGLE/lavapipe）在 Flutter **Impeller** 的渲染负载下会让**模拟器进程**
   SIGSEGV/SIGILL（core dump 实证：RIP 落在它自己 JIT 出来的匿名可执行页，栈上
   `libGLESv2.so → createFrameBuffer → es2GetProcAddress`）。四种子模式 `swangle/swiftshader/lavapipe/software` 全崩。
2. **App 侧必须"关 Impeller"，而且要写进 `AndroidManifest.xml`**：

   ```xml
   <meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false" />
   ```

   `am start --ez enable-impeller false` 在 **release 包里无效**（logcat 里照样打印
   `Using the Impeller rendering backend (OpenGLES)`）—— 这一条骗过我一次，别重犯。
3. **装完等 20 秒再启动**。包替换会让正在启动的 App 的 Activity 重建，此时
   `HermesApplication` 自管的 `FlutterEngine` 会抛
   `RuntimeException: Cannot execute operation because FlutterJNI is not attached to native`
   （栈：`FlutterJNI.setViewportMetrics` ← `FlutterView.onSizeChanged`）。竞态、不是必崩。
4. 屏幕用 **720x1280**（比 900x1600/1080x2400 稳），且 `-crash-report-mode disabled` 才能拿到 core。

## 崩了怎么取证

```bash
ulimit -c unlimited                  # 默认软限 0，必须抬（硬限是 unlimited）
cd <模拟器工作目录>                   # core_pattern=core → core 落在模拟器进程的 CWD
# 复现崩溃后：
python3 tool/core-forensics.py core.<pid>
```

输出：信号/si_addr、崩溃线程 RIP 所在模块+偏移、最近符号（调 `nm -D -C`）、沿栈扫出的疑似调用链。
2026-10-16 用它定位到"崩在模拟器自己的 JIT 代码里、栈上是指令翻译层"。

## 已知边界

- 关 Impeller = 走 Skia，与真机（Impeller）**渲染后端不同**：布局/交互/逻辑等价，像素级不保证。
- 更重的帧（超长列表 + 大量阴影）偶尔仍可能把模拟器带走；聊天界面的完整验收目前以
  **Flutter Web 构建 + Chromium 截图**为准（`flutter build web` 后 headless Chromium 驱动）。
- emulator 版本：本机 37.3.4 (build 16555280) = 官方 stable 最新，腾讯镜像与官方 XML 完全同步，
  canary 通道 URL 404 ⇒ **暂时没有更新的版本可升级**。后续可选：换 system image（API 34/33 / atd）、
  盯上游 issue、宿主加真显卡直通后 `-gpu host`。
