# 发版规范（2026-10-16 定）

## 版本号

`pubspec.yaml` 的 `version: <versionName>+<versionCode>` **两个都要动**：

```yaml
version: 1.3.3+7      # 语义化名字 + 单调递增的 versionCode（Android 用它判断能否覆盖安装）
```

- 修 bug：patch +1（1.3.3 → 1.3.4）；加功能：minor +1；不改版本号别人手机上装不上（同 code 覆盖安装要靠用户确认）。
- 每次发版在 `CHANGELOG.md` 顶部加一节（**英文**，跟上游文档一致；给用户看的说明另写在交付目录）。
- 名字里带 `+` 在文件名里不友好，所以**产物文件名用 `<versionName>-<versionCode>`**：`1.3.3-7`。

## 产物命名与清单

```
dist/hermes-mobile-<versionName>-<versionCode>-<abi>[-demo].apk
dist/hermes-mobile-<versionName>-<versionCode>-<abi>[-demo].json   ← 同名清单
dist/SHA256SUMS
```

清单（`tool/build-apk.sh` 自动生成）含：包名、versionName/versionCode、ABI、sha256、字节数、
签名证书 SHA-256、git commit、工作树是否脏、构建时间、Flutter 版本。**验货先看清单再装包。**

## 出包流程

```bash
tool/release.sh                 # 正式包 + 离线演示包（arm64），核验后投递到 ~/share/apk/hermes-mobile/
tool/release.sh /path/to/dir    # 指定投递目录
```

`tool/release.sh` 内部逐个调 `tool/build-apk.sh`，后者会：
1. 检查模拟器没在跑（构建与模拟器必须串行）；
2. 构建；
3. **当场核验** versionCode/versionName（读 APK 的 badging，不信任文件名）、ABI（zipfile 查 libflutter.so）、
   签名证书、sha256，任何一项不符直接 fail（`set -e`，不会再出现"构建失败却把旧包当产物交付"）。

## 交付目录

```
~/share/apk/hermes-mobile/                     ← 规范位置（带版本号 + 清单）
    hermes-mobile-1.3.3-7-arm64.apk
    hermes-mobile-1.3.3-7-arm64-demo.apk
    hermes-mobile-1.3.3-7-arm64.json
    hermes-mobile-1.3.3-7-arm64-demo.json
    SHA256SUMS
~/share/apk/hermes-mobile-i18n-fixes-arm64.apk ← 旧路径（手机上一路用的名字，release.sh 会同步一份）
```

## 装机注意（都是实测）

- **签名必须一致**：`apksigner verify --print-certs` 应等于 `CN=Android Debug`, SHA-256 `55293152…c9703`；
  换签名就只能卸载重装（会丢本地登录态）。
- **模拟器要 x64 包**（`--abi x64`），手机要 arm64；x64 包在手机上装不上，反之模拟器里能装但一启动就 `UnsatisfiedLinkError`。
- 装完 App 别立刻启动（等 20 秒），否则可能撞 `FlutterJNI is not attached to native`（见 docs/EMULATOR.md）。

## 提交与推送

- 只提交到自己的分支（`fork` remote），**不开 PR**（用户 2026-10-16 定）。
- 提交信息：一句话英文 type + 中文细节；功能与版本号分开提交（`fix(...)` / `release: x.y.z+code`）。
