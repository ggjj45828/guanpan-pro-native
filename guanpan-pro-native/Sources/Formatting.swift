import Foundation

/// 与 Swift 版本和数值类型无关的展示格式化助手。
/// 原工程大量使用 `Text(value, format: .currency(code: "CNY"))` 等 FormatStyle 写法，
/// 在 CI 所用的 Swift 版本上，对 Decimal 或带标签的字符串插值无法推断基类型而编译失败。
/// 这里改用 NumberFormatter 实现，Double / Decimal / Int 均可直接调用，行为保持一致。
extension BinaryFloatingPoint {
    /// 涨跌的方向符号。
    ///
    /// 国内是红涨绿跌，但**只靠颜色**区分时红绿色盲（男性约 8%、女性约 0.5%）完全读不出来，
    /// 打印 / 截图转灰度后也一样。所以涨跌数字旁边恒定带一个方向符号，
    /// 颜色之外还能靠形状分辨。0 用「—」而不是空格，避免和「没数据」混淆。
    func directionMark() -> String {
        let v = Double(self)
        if v > 0 { return "▲" }
        if v < 0 { return "▼" }
        return "—"
    }

    func cny(_ digits: Int = 2) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "CNY"
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: NSNumber(value: Double(self))) ?? String(format: "%.*f", digits, Double(self))
    }

    func num(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: NSNumber(value: Double(self))) ?? String(format: "%.*f", digits, Double(self))
    }

    /// 把「已经是百分数」的值格式化成字符串：-1.05 → "-1.05%"。
    ///
    /// 千万不要用 NumberFormatter 的 .percent 样式：那个样式约定输入是 0.0105 这类小数，
    /// 会自动再 ×100。而本工程所有调用方（pnlRate / positionPercent / changePct / winRate…）
    /// 传入的都是百分数，二次相乘就会显示成 "-104.56%" 这种百倍错误（2026-10 用户实测发现）。
    func pct(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        let v = Double(self)
        return (nf.string(from: NSNumber(value: v)) ?? String(format: "%.*f", digits, v)) + "%"
    }
}

extension Decimal {
    func cny(_ digits: Int = 2) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "CNY"
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: self as NSDecimalNumber) ?? "\(self)"
    }

    func num(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: self as NSDecimalNumber) ?? "\(self)"
    }

    /// 传入值已是百分数（见 Double.pct 的说明），直接加 % 格式化。
    func pct(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        let s = nf.string(from: self as NSDecimalNumber)
        return (s ?? "\(self)") + "%"
    }
}

extension Int {
    func cny(_ digits: Int = 2) -> String { Double(self).cny(digits) }
    func num(_ digits: Int) -> String { Double(self).num(digits) }
    func pct(_ digits: Int) -> String { Double(self).pct(digits) }
}
