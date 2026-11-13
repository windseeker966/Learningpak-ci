# Learningpak-ci

[![Build](https://github.com/windseeker966/Learningpak-ci/actions/workflows/build.yml/badge.svg)](https://github.com/windseeker966/Learningpak-ci/actions/workflows/build.yml)

iPad 学习 App 的源码镜像，只用来在 GitHub Actions 上检查能否编译、规则测试是否通过。

- 内容由私有仓库的 `tools/sync-public.sh` 同步过来，不要在这里直接修改。
- 只包含源码（`Learning/`）、工程文件、`Info.plist` 和测试（`Tests/`），不含教辅内容。
- CI：`macos-26` 上用 `xcodebuild` 编译模拟器版本（不签名），再逐个用 `swiftc` 编译运行 `Tests/` 下的测试。
