# iOS 构建与 IPA 归档

本源码包使用 `project.yml` 作为唯一工程配置。请从本文件所在目录运行仓库内的 `generate-xcode-project.sh`；不要手工重建 `.xcodeproj`，也不要单独挑选 Swift 文件创建工程。XcodeGen 会把 `Sources/` 下的 Swift 源码和资源纳入 `GuanpanProNative` target，新加的 `.swift` 文件也会自动进入 target。

## 先验证源码能编译

在安装了 Xcode 与 XcodeGen 的 Mac 上运行：

```sh
./generate-xcode-project.sh
xcodebuild -project GuanpanProNative.xcodeproj \
  -scheme GuanpanProNative \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

这一步用于定位 Swift 语法、类型和 target 配置错误，不需要 Apple 开发者签名。若失败，优先依据 Xcode 输出的文件名和行号做最小修正，然后重新运行同一条构建命令。

## 生成 IPA

IPA 归档需要可用的 Apple 签名团队与对应的导出方式。完成上一步后，在有签名配置的 Mac 上归档：

```sh
xcodebuild -project GuanpanProNative.xcodeproj \
  -scheme GuanpanProNative \
  -destination 'generic/platform=iOS' \
  -archivePath build/GuanpanPro.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=你的团队ID \
  archive
```

再用与分发方式匹配的 `ExportOptions.plist` 导出：

```sh
xcodebuild -exportArchive \
  -archivePath build/GuanpanPro.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist
```

`.ipa` 是否可安装取决于归档签名、描述文件和导出方式；这与 Swift 源码是否编译通过是两个独立结果。修复编译错误时不要删除功能或整份替换 `project.yml`，应保留现有 target、资源和版本设置。
