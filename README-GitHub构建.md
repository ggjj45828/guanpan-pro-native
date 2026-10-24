# 观盘 Pro：GitHub 云端 Mac 构建

此源码包用于在 GitHub Actions 的 macOS Runner 上生成 iPhone 版**未签名 IPA**。它只包含 iOS 原生工程和构建工作流，不包含网页版或 NAS 部署包。

## 上传并运行

1. 在 GitHub 新建一个仓库。**必须是公开（Public）仓库**：GitHub 只对公开仓库免费提供 macOS Runner；私有仓库的 macOS 额度按 10 倍折算，免费额度跑不了几次就会开始计费（约 $0.062/分钟）。
2. 把仓库根目录放齐 `.github`、`guanpan-pro-native` 两个文件夹和本说明文件，提交到 `main` 分支。
3. 打开仓库的 **Actions** 标签页，选择 **Build iOS IPA**，点击 **Run workflow**（推送到 `main` 也会自动触发）。
4. 构建完成后，在该次运行页面底部的 **Artifacts** 下载 `guanpan-pro-unsigned-ipa`，再解压得到 `GuanpanPro-unsigned.ipa`。

首次使用 GitHub 网页上传时，请确认隐藏的 `.github` 文件夹也上传成功，否则 Actions 页面不会出现此工作流。也可以用 GitHub Desktop 将解压后的文件夹发布到仓库。

## 关于 Token 和签名

- 运行此工作流不需要 Personal Access Token，也不需要配置 GitHub Secrets；仓库所有者可直接在 Actions 页面启动。
- 不要把 GitHub Token、Apple 密码或证书私钥写进源码、提交记录或聊天。
- 这个工作流通过 XcodeGen 生成 Xcode 工程，在 macOS 上编译并打包未签名 IPA。它证明云端编译链路可用，但**未签名 IPA 不能直接安装到 iPhone**。
- 包内应用目录和主程序文件名固定为 ASCII（`Payload/GuanpanPro.app/GuanpanPro`），桌面显示名仍为“观盘 Pro”。构建会校验 ZIP CRC、`CFBundleExecutable` 与真实文件路径、Mach-O 文件头及 Bundle ID；路径或文件不匹配时构建失败，不上传坏包。
- 安装前需要用有效的 Apple 开发签名和匹配设备的 provisioning profile 重签。单纯用 3uTools 传输 IPA 不会自动让未签名包变成可安装应用。免费个人签名的证书与描述文件也有有效期限制。
- 当前工作流不会使用或读取任何签名凭据。需要签名时，应另行设计签名步骤，并通过 GitHub 仓库的 Actions Secrets 安全提供所需文件和密码，不要发送给助手。

## 构建设置

- 最低系统版本：iOS 17
- Scheme：`GuanpanProNative`
- Bundle ID：`com.guanpan.pro.native`
- Runner：GitHub-hosted `macos-15`
- 产物保留：14 天
