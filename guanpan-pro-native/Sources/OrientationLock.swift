import UIKit

/// 屏幕方向锁定器 —— 只服务于「K 线横屏大图」。
///
/// 为什么不直接用 SwiftUI：SwiftUI 没有公开的「临时切到横屏」API，
/// 只能走 UIKit 两步：改 `UIDevice.orientation` 触发一次旋转，
/// 再由 AppDelegate 的 `supportedInterfaceOrientationsFor` 决定允许哪些方向。
/// 两者缺一：只改 orientation 会被系统支持的旋转方向挡回去；只改 mask 不会主动转。
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    /// AppDelegate 读这个值决定当前允许的方向。
    private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown

    private init() {}

    func lockLandscape() {
        mask = .landscape
        // 先设一次具体方向，再让系统去尝试旋转，否则停留在竖屏不动。
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }

    func unlock() {
        mask = .allButUpsideDown
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
