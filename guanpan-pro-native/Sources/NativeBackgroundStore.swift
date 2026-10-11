import Foundation
import UIKit

enum NativeBackgroundStore {
    private static let revisionKey = "guanpan.native.background.revision"
    private static let presetKey = "guanpan.native.background.preset"
    private static let gradientKey = "guanpan.native.background.gradient"
    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("guanpan-custom-background.jpg")
    }

    static var revision: Int { UserDefaults.standard.integer(forKey: revisionKey) }
    static var selectedPreset: NativeBackgroundPreset? {
        guard let rawValue = UserDefaults.standard.string(forKey: presetKey) else { return nil }
        return NativeBackgroundPreset(rawValue: rawValue)
    }
    static var selectedGradient: NativeGradientPreset? {
        guard let rawValue = UserDefaults.standard.string(forKey: gradientKey) else { return nil }
        return NativeGradientPreset(rawValue: rawValue)
    }
    static var hasActiveBackground: Bool {
        selectedPreset != nil || selectedGradient != nil
            || fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    static var backupData: Data? {
        if let fileURL, let data = try? Data(contentsOf: fileURL) { return data }
        if let gradient = selectedGradient {
            let size = CGSize(width: 900, height: 1600)
            let image = UIGraphicsImageRenderer(size: size).image { renderer in
                let colors = gradient.hexColors.map { hex in
                    UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                            green: CGFloat((hex >> 8) & 0xff) / 255,
                            blue: CGFloat(hex & 0xff) / 255, alpha: 1).cgColor
                } as CFArray
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                if let cgGradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: nil) {
                    renderer.cgContext.drawLinearGradient(cgGradient, start: .zero,
                        end: CGPoint(x: size.width, y: size.height), options: [])
                }
            }
            return image.jpegData(compressionQuality: 0.82)
        }
        return load()?.jpegData(compressionQuality: 0.82)
    }

    static func load() -> UIImage? {
        if let preset = UserDefaults.standard.string(forKey: presetKey),
           let image = UIImage(named: preset) { return image }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    static func select(_ preset: NativeBackgroundPreset) {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        UserDefaults.standard.removeObject(forKey: gradientKey)
        UserDefaults.standard.set(preset.assetName, forKey: presetKey)
        UserDefaults.standard.set(revision + 1, forKey: revisionKey)
    }

    static func select(_ preset: NativeGradientPreset) {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        UserDefaults.standard.removeObject(forKey: presetKey)
        UserDefaults.standard.set(preset.rawValue, forKey: gradientKey)
        UserDefaults.standard.set(revision + 1, forKey: revisionKey)
    }

    static func save(_ source: Data) throws {
        guard let raw = UIImage(data: source), let fileURL else { throw BackgroundImageError.invalidImage }
        // 先按最长边缩到 1800（与旧逻辑一致），再强制裁成 3:4 竖向比例并归一到固定像素尺寸。
        // 原因：极端宽高比的图配合 scaledToFill 会让 SwiftUI 渲染出超大位图，导致界面错乱/内存暴涨。
        // 统一成 1080x1440 后，任何来源的图片都只占用固定显存。
        let maxDimension: CGFloat = 1800
        let scale = min(1, maxDimension / max(raw.size.width, raw.size.height))
        let scaledSize = CGSize(width: max(1, raw.size.width * scale), height: max(1, raw.size.height * scale))
        let resized = UIGraphicsImageRenderer(size: scaledSize).image { _ in
            raw.draw(in: CGRect(origin: .zero, size: scaledSize))
        }
        let targetSize = CGSize(width: 1080, height: 1440)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let normalized = renderer.image { _ in
            // aspectFill：铺满目标画布并居中裁剪，避免拉伸变形
            let ratio = max(targetSize.width / resized.size.width, targetSize.height / resized.size.height)
            let drawSize = CGSize(width: resized.size.width * ratio, height: resized.size.height * ratio)
            let origin = CGPoint(x: (targetSize.width - drawSize.width) / 2,
                                 y: (targetSize.height - drawSize.height) / 2)
            resized.draw(in: CGRect(origin: origin, size: drawSize))
        }
        guard let encoded = normalized.jpegData(compressionQuality: 0.78), encoded.count <= 8 * 1024 * 1024 else {
            throw BackgroundImageError.invalidImage
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: fileURL, options: .atomic)
        UserDefaults.standard.removeObject(forKey: presetKey)
        UserDefaults.standard.removeObject(forKey: gradientKey)
        UserDefaults.standard.set(revision + 1, forKey: revisionKey)
    }

    static func remove() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        UserDefaults.standard.removeObject(forKey: presetKey)
        UserDefaults.standard.removeObject(forKey: gradientKey)
        UserDefaults.standard.set(revision + 1, forKey: revisionKey)
    }

    // MARK: - v2.12：背景图功能整体下线

    private static let removalMigrationKey = "guanpan.native.background.removedInV212"

    /// 一次性清掉老版本留下的图片背景 / 渐变背景。
    ///
    /// v2.12 起只保留「配色主题」，设置页里已经没有背景图的任何入口。
    /// 但 `hasActiveBackground` 仍会被 `MetricCardKit` 用来决定卡片是否走
    /// 「背景图 + 卡片半透明透出来」那套样式 —— 用户本机若还留着上次选的图，
    /// 界面会继续铺着它，用户却既看不到入口也撤不掉。所以升级后的第一次启动必须清干净。
    static func removeLegacyBackgroundIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: removalMigrationKey) else { return }
        defaults.set(true, forKey: removalMigrationKey)
        guard hasActiveBackground else { return }
        remove()
    }
}

enum NativeBackgroundPreset: String, CaseIterable, Identifiable {
    case landscape, portrait, car, mecha
    var id: String { rawValue }
    var assetName: String { rawValue }
    var title: String {
        switch self {
        case .landscape: return "极光雪山"
        case .portrait: return "都市写真"
        case .car: return "暮色跑车"
        case .mecha: return "变形机甲"
        }
    }
}

enum NativeGradientPreset: String, CaseIterable, Identifiable {
    case sunset, aurora, ocean, bamboo, desert, animeSky, animeNight, galaxy, neon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sunset: return "日落海滩"
        case .aurora: return "极光夜空"
        case .ocean: return "深海"
        case .bamboo: return "竹林晨雾"
        case .desert: return "沙漠黄昏"
        case .animeSky: return "动漫天空"
        case .animeNight: return "二次元夜"
        case .galaxy: return "星云"
        case .neon: return "霓虹街景"
        }
    }
    var hexColors: [UInt] {
        switch self {
        case .sunset: return [0x2b1055, 0x6a5acd, 0xc86b8f, 0xff9a5a, 0xffd194]
        case .aurora: return [0x050b1e, 0x0d2b4a, 0x155e63, 0x2fa88a, 0x0a1836]
        case .ocean: return [0x00121f, 0x00304d, 0x00628a, 0x00a8b5]
        case .bamboo: return [0x08180f, 0x1b4332, 0x2d6a4f, 0x74c69d, 0xb7e4c7]
        case .desert: return [0x2d1b0e, 0x7a4a21, 0xc87f3a, 0xe8b06a, 0xf6d8a8]
        case .animeSky: return [0x5ec8f2, 0xa5e4ff, 0xffe1f0, 0xfff6fb]
        case .animeNight: return [0x1b1035, 0x4a2a72, 0x8b5ea8, 0xff9ecd, 0xffd6e8]
        case .galaxy: return [0x070516, 0x6b3fa0, 0x1f6f8b, 0xa03a6b, 0x050310]
        case .neon: return [0x0d0221, 0x240046, 0x7b2cbf, 0xf72585, 0x4cc9f0]
        }
    }
}

enum BackgroundImageError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "图片无法读取，或压缩后仍超过 8 MB。" }
}
