import UIKit

/// 屏幕方向锁定器 —— 只服务于「K 线横屏大图」。
///
/// 为什么不直接用 SwiftUI：SwiftUI 没有公开的「临时切到横屏」API，
/// iOS 16+ 应通过 `UIWindowScene.requestGeometryUpdate` 请求方向，避免继续使用
/// `UIDevice.setValue(_:forKey:)` 这一套非公开 KVC 写法。
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    /// AppDelegate 读这个值决定当前允许的方向。
    private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown

    private init() {}

    func lockLandscape() {
        mask = .landscape
        request(.landscape)
    }

    func unlock() {
        mask = .allButUpsideDown
        request(.portrait)
    }

    private func request(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in
            // 设备方向被系统或多任务布局限制时保持当前方向，不强制写私有属性。
        }
    }
}
