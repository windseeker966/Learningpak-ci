# Learningpak-ci

[![Build](https://github.com/windseeker966/Learningpak-ci/actions/workflows/build.yml/badge.svg)](https://github.com/windseeker966/Learningpak-ci/actions/workflows/build.yml)

iPad 学习 App 的源码镜像，只用来在 GitHub Actions 上检查能否编译、规则测试是否通过。

- 内容由私有仓库的 `tools/sync-public.sh` 同步过来，不要在这里直接修改。
- 只包含源码（`Learning/`）、工程文件、`Info.plist` 和测试（`Tests/`），不含教辅内容。
- CI：`macos-26` 上用 `xcodebuild` 编译模拟器版本（不签名），再逐个用 `swiftc` 编译运行 `Tests/` 下的测试。

## iPad 安装包（`.github/workflows/ipa.yml`）

每次推送到 `main` 都会编译真机 Release 版本，在 Actions 运行页面的 Artifacts 里下载 `Learning-ipa-<编号>`：

- `Learning-unsigned.ipa`：未签名。用 [Sideloadly](https://sideloadly.io/) 或 AltStore 登录自己的 Apple ID 重签后装到 iPad（免费账号 7 天过期，需要重签）。
- `Learning-signed.ipa`：仓库配置了下面的 secrets 才会生成，已签名，可以直接装到描述文件里登记过的 iPad 上（如用 Apple Configurator、`xcrun devicectl device install app` 或爱思助手）。
  - `BUILD_CERTIFICATE_BASE64`：签名证书导出的 `.p12`，`base64 -i cert.p12 | pbcopy`
  - `P12_PASSWORD`：`.p12` 的密码
  - `PROVISIONING_PROFILE_BASE64`：`com.wind.studypack` 的开发或 Ad Hoc 描述文件，`base64 -i x.mobileprovision | pbcopy`
