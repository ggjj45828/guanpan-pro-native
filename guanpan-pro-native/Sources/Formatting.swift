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

    /// **关闭千分位分组**：份额、成交量、金额一律按「2222」显示，不写成「2,222」。
    ///
    /// `.decimal` 样式的 `usesGroupingSeparator` 默认为 true，`zh_CN` 下 4 位数就会插逗号 ——
    /// 用户看到的「2222 显示成 2,222」就是这个默认值造成的。国内行情/账本界面习惯直接连写，
    /// 所以在所有展示格式化入口统一关掉，改一处即可覆盖全 App。
    private func plainNumberFormatter(style: NumberFormatter.Style,
                                      digits: Int,
                                      minimumFractionDigits: Int? = nil) -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = style
        nf.locale = Locale(identifier: "zh_CN")
        nf.usesGroupingSeparator = false
        nf.minimumFractionDigits = minimumFractionDigits ?? digits
        nf.maximumFractionDigits = digits
        return nf
    }

    func cny(_ digits: Int = 2) -> String {
        guard Double(self).isFinite else { return "—" }
        let nf = plainNumberFormatter(style: .currency, digits: digits)
        nf.currencyCode = "CNY"
        return nf.string(from: NSNumber(value: Double(self))) ?? String(format: "%.*f", digits, Double(self))
    }

    func num(_ digits: Int) -> String {
        guard Double(self).isFinite else { return "—" }
        let nf = plainNumberFormatter(style: .decimal, digits: digits)
        return nf.string(from: NSNumber(value: Double(self))) ?? String(format: "%.*f", digits, Double(self))
    }

    /// 紧凑数字：最多保留 `digits` 位小数，去掉尾随零。
    /// 与 `num` 的区别：`num` 固定小数位（"1234.5000"），`compactNum` 去尾零（"1234.5" / "1234"）。
    func compactNum(_ digits: Int) -> String {
        let v = Double(self)
        guard v.isFinite else { return "—" }
        let nf = plainNumberFormatter(style: .decimal, digits: digits, minimumFractionDigits: 0)
        return nf.string(from: NSNumber(value: v)) ?? String(format: "%.*f", digits, v)
    }

    /// 把「百分数」格式化成字符串：-1.05 → "-1.05%"。
    ///
    /// 千万不要用 NumberFormatter 的 .percent 样式：那个样式约定输入是 0.0105 这类小数，
    /// 会自动再 ×100。调用方必须传百分数单位；行情模型的 changePct 是小数比例，使用前要乘 100。
    func pct(_ digits: Int) -> String {
        let v = Double(self)
        guard v.isFinite else { return "—" }
        let nf = plainNumberFormatter(style: .decimal, digits: digits)
        return (nf.string(from: NSNumber(value: v)) ?? String(format: "%.*f", digits, v)) + "%"
    }
}

extension Decimal {
    /// 与 `BinaryFloatingPoint` 同口径：`usesGroupingSeparator = false`，
    /// 金额与数量都按「2222」连写，不出现「2,222」。
    private func plainNumberFormatter(style: NumberFormatter.Style, digits: Int) -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = style
        nf.locale = Locale(identifier: "zh_CN")
        nf.usesGroupingSeparator = false
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf
    }

    func cny(_ digits: Int = 2) -> String {
        let nf = plainNumberFormatter(style: .currency, digits: digits)
        nf.currencyCode = "CNY"
        return nf.string(from: self as NSDecimalNumber) ?? "\(self)"
    }

    func num(_ digits: Int) -> String {
        plainNumberFormatter(style: .decimal, digits: digits).string(from: self as NSDecimalNumber) ?? "\(self)"
    }

    /// 传入值已是百分数（见 Double.pct 的说明），直接加 % 格式化。
    func pct(_ digits: Int) -> String {
        (plainNumberFormatter(style: .decimal, digits: digits).string(from: self as NSDecimalNumber) ?? "\(self)") + "%"
    }
}

extension Int {
    func cny(_ digits: Int = 2) -> String { Double(self).cny(digits) }
    func num(_ digits: Int) -> String { Double(self).num(digits) }
    func pct(_ digits: Int) -> String { Double(self).pct(digits) }
}

// MARK: - 日期短格式

/// 行情时间戳 → "10-09"。界面标注数据日期用（休市时它就是上一交易日）。
///
/// 固定用上海时区：行情源给的时间戳是交易所时间，用本机时区会在跨时区时差一天。
func shortDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "MM-dd"
    return formatter.string(from: date)
}

/// "2026-10-08" → "10-08"。净值历史里存的是 `yyyy-MM-dd` 字符串，长度不够时原样返回。
func shortDay(_ isoDay: String) -> String {
    isoDay.count >= 10 ? String(isoDay.dropFirst(5)) : isoDay
}
