# capcap AI 私人发行版 CI/CD 设计

## 目标

`SoLuT1oN/capcap` 的 `main` 长期保存官方 `upstream/main`、AI Calendar 私人功能和私人 CI/CD。每天自动检查 upstream；只有 merge、构建、全量测试和 AI Calendar 回归测试全部成功，才更新私人 `main`、发布 `custom-v<官方版本>-ai.<修订号>`，并通知 `SoLuT1oN/homebrew-tap` 更新 `capcap-ai` Cask。

## 分支与远端

- `origin` 固定为 `https://github.com/SoLuT1oN/capcap.git`，是唯一自动 push 目标
- `upstream` 固定为 `https://github.com/realskyrin/capcap.git`，只 fetch 和 merge
- `main` 是唯一长期集成分支，不建立长期 `ai-calendar` 分支
- 同步只允许普通 `git merge upstream/main`，禁止 reset、force push 和冲突时批量选择 ours/theirs

## Upstream 同步

`.github/workflows/sync-upstream.yml` 在每天 `03:17 UTC`（北京时间 11:17）及手动触发时运行。它以完整历史检出 `main`，确保 upstream URL 正确，fetch `upstream/main` 和 tags，并先用祖先关系判断是否已有更新。

没有更新时输出 `No upstream changes.` 并结束，不 push、不发布、不更新 Tap。有更新时只在 Runner 工作树中 merge。若冲突，写出冲突文件清单和 `Upstream synchronization requires manual conflict resolution.` 到 Job Summary，abort merge 并失败，远端保持不变。仓库当前未启用 Issues，因此不自动创建 Issue。

无冲突后依次执行 debug build、全量 tests、AI Calendar 定向回归和 universal release build。全部通过后才 push `HEAD:main`，随后以 Actions API `workflow_dispatch` 启动 `release-ai.yml`，规避 `GITHUB_TOKEN` 事件递归限制。

## 私人 Release

`.github/workflows/release-ai.yml` 仅支持手动或同步 workflow dispatch。它从 `capcap/App/Info.plist` 读取纯数字官方版本，不修改 App 内的 `CFBundleShortVersionString` 和 `CFBundleVersion`。现有 `custom-v<BASE>-ai.N` 的最大 N 加一形成新版本；如果当前 `main` 已有对应 custom Release，则幂等跳过；如果 tag 已存在但 Release 缺失，则复用该 tag 恢复发布。

构建流程与官方 `.github/workflows/release.yml` 保持一致：完整 Xcode、universal arm64/x86_64 release build、release tests、手工组装 `capcap.app`、复制图标、本地化、PermissionFlow bundle 和 Share Extension、验证两种架构、稳定证书或 ad-hoc fallback、ZIP/DMG 与 SHA256。私人版本只进入 Tag、Release 名、资产名和 Homebrew version；App 名仍为 `capcap.app`，Bundle ID 仍为 `cn.skyrin.capcap`。

Release 名为 `capcap <CUSTOM_VERSION>`，目标为触发时的 `main` 提交，资产包括 ZIP、ZIP SHA256、DMG 和 DMG SHA256。Tag 使用 `custom-v*`，不会触发官方监听 `release-v*` 的 workflow。

## Homebrew Tap

`SoLuT1oN/homebrew-tap` 保留官方 `Casks/capcap.rb`，新增 `Casks/capcap-ai.rb`、生成脚本和 `.github/workflows/bump-capcap-ai.yml`。Cask token 是 `capcap-ai`，下载私人 Release ZIP，安装的 App 仍是 `capcap.app`，并声明与官方 `capcap` Cask 冲突。

Tap workflow 监听 `capcap_ai_release_published` 和手动输入。它只接受形如 `X.Y.Z-ai.N` 的 version、64 位十六进制 SHA256、匹配的 tag 和 asset name；生成 Cask 后运行 Ruby 语法检查，条件允许时执行 Homebrew style/audit，只暂存 `Casks/capcap-ai.rb`，用 Tap 自身 `GITHUB_TOKEN` push。

capcap Release 使用可选 `HOMEBREW_TAP_TOKEN` 跨仓库发送 dispatch，payload 包含 version、sha256、tag、asset_name。Secret 缺失时 Release 仍成功，只写 warning 和 Job Summary；不读取、不打印、不自动复制当前 gh token。

## 失败与安全边界

- merge 冲突、任何 build/test 失败：不 push main、不 Release、不更新 Tap
- Release 构建失败：不创建 Release、不更新 Tap
- Tap token 缺失：Release 保留成功，Tap 保持最后一个可用版本
- Tap 校验失败：不 commit、不 push，旧 Cask 保持不变
- 不写 upstream、不 force push、不提交 API Key、PAT、证书、私钥或 Secret
- 不卸载现有 capcap，不覆盖 `/Applications/capcap.app`

## 验收

本地检查 YAML、Shell/Ruby 语法、`swift build`、`swift test`、AI Calendar 定向测试、universal release build、`git diff --check` 和敏感信息扫描。推送后实际手动运行无 upstream 更新路径，确认无 Release；再手动运行私人 Release，核对资产与 checksum。使用实际 ZIP checksum 生成 Cask，并用 `ruby -c`、`brew info`、`brew style` 和适用的 `brew audit` 验证元数据，不执行安装或覆盖应用。
