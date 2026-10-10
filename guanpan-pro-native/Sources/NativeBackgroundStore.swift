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
        guard let image = UIImage(data: source), let fileURL else { throw BackgroundImageError.invalidImage }
        let maxDimension: CGFloat = 1800
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let encoded = resized.jpegData(compressionQuality: 0.78), encoded.count <= 8 * 1024 * 1024 else {
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
