import Foundation
import UIKit
import Vision

// MARK: - 券商成交截图 OCR（移植自观盘max FBrokerScreenshotOCR，按 Pro 的导入口径适配）
//
// 与观盘max 的差别：max 输出「只有时间」的草稿表，Pro 的 TradeCSVParser 需要
// 完整日期才能落 Ledger，所以这里把用户选的成交日与识别出的时间拼成
// `yyyy-MM-dd HH:mm:ss`，再交给现成的 TradeCSVParser / importTradeLedger。
//
// 红线：识别结果一律先预览、人工勾选，绝不自动写账本；
// 价×量与金额对不上、疑似成交行解析不出来，都直接拦截而不是猜一个值。

struct ScreenshotTradeRow: Identifiable, Equatable {
    let id = UUID()
    let code: String
    let name: String
    let side: String
    let time: String
    let price: String
    let units: String
    let amount: String
    let sourceImageIndex: Int

    var fingerprint: String {
        [code, side, time, price, units, amount].joined(separator: "|")
    }
}

/// 「按股票汇总」截图里的一行。方向允许为空（有些汇总页不标买卖）。
struct ScreenshotSummaryRow: Identifiable, Equatable {
    let id = UUID()
    let code: String
    let name: String
    let side: String
    let units: String
    let amount: String
    let sourceImageIndex: Int

    var fingerprint: String {
        [code, side, units, amount].joined(separator: "|")
    }
}

/// 手续费来源枚举定义在 `TradeCSVImport.swift`（CSV 与截图导入共用）。
enum ScreenshotOCRError: Error, LocalizedError {
    case invalidImage
    case noText
    case unparsedTradeRows(Int)
    case amountMismatch([Int])
    case summaryEmpty
    case unparsedSummaryRows(Int)
    case reconciliationMismatch([String])

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "有一张图片无法读取"
        case .noText: return "截图里没有识别到文字"
        case .unparsedTradeRows(let count):
            return "有 \(count) 行看起来是成交记录但没解析出来，已拦截，请改用表格导入或手动录入"
        case .amountMismatch(let rows):
            return "第 \(rows.map(String.init).joined(separator: "、")) 行的「价格 × 数量」与成交金额不一致，已拦截"
        case .summaryEmpty:
            return "汇总截图没有识别到任何汇总行，已拦截；请重新选择或取消汇总截图"
        case .unparsedSummaryRows(let count):
            return "汇总截图有 \(count) 行看起来是汇总记录但没解析出来，已拦截"
        case .reconciliationMismatch(let codes):
            return "逐笔截图与汇总截图对不上（\(codes.joined(separator: "、"))），已整批拦截；请核对截图是否为同一交易日"
        }
    }
}

enum TradeScreenshotOCR {

    private struct Cell {
        let text: String
        let midY: Double
        let minX: Double
    }

    /// 多图识别 + 行分组 + 逐行解析 + 跨图去重。
    static func extractRows(from images: [Data]) async throws -> [ScreenshotTradeRow] {
        var rows: [ScreenshotTradeRow] = []
        var seen = Set<String>()
        var unparsed = 0
        for (index, data) in images.enumerated() {
            let cells = try recognize(data)
            if cells.isEmpty { continue }
            for line in group(cells) {
                let joined = line.map { $0.text }.joined(separator: " ")
                let looksLikeTrade = joined.range(of: #"(?<!\d)\d{6}(?!\d)"#, options: .regularExpression) != nil
                guard var row = parse(line, imageIndex: index) else {
                    if looksLikeTrade { unparsed += 1 }
                    continue
                }
                if seen.insert(row.fingerprint).inserted { rows.append(row) }
            }
        }
        if rows.isEmpty && unparsed == 0 { throw ScreenshotOCRError.noText }
        if unparsed > 0 { throw ScreenshotOCRError.unparsedTradeRows(unparsed) }
        return rows
    }

    /// 价 × 数量 与成交金额核对，容差与观盘max 一致。
    static func validate(_ rows: [ScreenshotTradeRow]) throws {
        var bad: [Int] = []
        for (offset, row) in rows.enumerated() {
            guard let price = Double(row.price), let units = Double(row.units),
                  let amount = Double(row.amount) else {
                bad.append(offset + 1)
                continue
            }
            let tolerance = max(0.02, abs(amount) * 0.0001)
            if abs(price * units - amount) > tolerance { bad.append(offset + 1) }
        }
        if !bad.isEmpty { throw ScreenshotOCRError.amountMismatch(bad) }
    }

    /// 生成 TradeCSVParser 能直接吃的制表符表格。
    static func draftTable(_ rows: [ScreenshotTradeRow], tradingDay: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "Asia/Shanghai")
        day.dateFormat = "yyyy-MM-dd"
        let dayText = day.string(from: tradingDay)
        var lines = ["证券代码\t证券名称\t买卖方向\t成交时间\t成交价格\t成交数量\t成交金额"]
        for row in rows {
            let time = row.time.isEmpty ? "09:30:00"
                : (row.time.count == 5 ? row.time + ":00" : row.time)
            lines.append([row.code, row.name, row.side,
                          "\(dayText) \(time)", row.price, row.units, row.amount]
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 逐笔 ↔ 汇总 交叉核对
    //
    // 让用户分开选「逐笔截图」和「按股票汇总截图」，程序不猜哪张是汇总页。
    // 汇总页可能不标买卖方向，所以两边都按证券代码聚合总量 / 总额再比；
    // 任一代码缺失或对不上，整批拦截，不允许只导入对得上的那部分。

    static func extractSummaryRows(from images: [Data]) async throws -> [ScreenshotSummaryRow] {
        var rows: [ScreenshotSummaryRow] = []
        var seen = Set<String>()
        var unparsed = 0
        for (index, data) in images.enumerated() {
            let cells = try recognize(data)
            for line in group(cells) {
                let joined = line.map { $0.text }.joined(separator: " ")
                let looksLikeSummary = joined.range(of: #"(?<!\d)\d{6}(?!\d)"#, options: .regularExpression) != nil
                guard let row = parseSummary(line, imageIndex: index) else {
                    if looksLikeSummary { unparsed += 1 }
                    continue
                }
                if seen.insert(row.fingerprint).inserted { rows.append(row) }
            }
        }
        if unparsed > 0 { throw ScreenshotOCRError.unparsedSummaryRows(unparsed) }
        if rows.isEmpty { throw ScreenshotOCRError.summaryEmpty }
        return rows
    }

    static func reconcile(details: [ScreenshotTradeRow], summary: [ScreenshotSummaryRow]) throws {
        struct Bucket { var units: Double = 0; var amount: Double = 0 }
        var detail: [String: Bucket] = [:]
        for row in details {
            guard let units = Double(row.units), let amount = Double(row.amount) else { continue }
            var bucket = detail[row.code] ?? Bucket()
            bucket.units += units
            bucket.amount += amount
            detail[row.code] = bucket
        }
        var summed: [String: Bucket] = [:]
        for row in summary {
            guard let units = Double(row.units), let amount = Double(row.amount) else { continue }
            var bucket = summed[row.code] ?? Bucket()
            bucket.units += units
            bucket.amount += amount
            summed[row.code] = bucket
        }
        guard !detail.isEmpty, !summed.isEmpty else {
            throw ScreenshotOCRError.reconciliationMismatch(["无可核对数据"])
        }
        var bad = Set(detail.keys).symmetricDifference(Set(summed.keys)).sorted()
        for (code, left) in detail {
            guard let right = summed[code] else { continue }
            let tolerance = max(0.05, abs(left.amount) * 0.0002)
            if abs(left.units - right.units) > 1e-6 || abs(left.amount - right.amount) > tolerance {
                if !bad.contains(code) { bad.append(code) }
            }
        }
        if !bad.isEmpty { throw ScreenshotOCRError.reconciliationMismatch(bad.sorted()) }
    }

    // MARK: 识别与分组

    private static func recognize(_ data: Data) throws -> [Cell] {
        guard let image = UIImage(data: data)?.cgImage else { throw ScreenshotOCRError.invalidImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw ScreenshotOCRError.invalidImage }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.35 }
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return Cell(text: candidate.string,
                            midY: Double(box.midY),
                            minX: Double(box.minX))
            }
    }

    /// 同一行的判定：纵向中心差 ≤ 0.012（归一化坐标）。
    private static func group(_ cells: [Cell]) -> [[Cell]] {
        let sorted = cells.sorted { $0.midY > $1.midY }
        var groups: [[Cell]] = []
        for cell in sorted {
            if var last = groups.last, let anchor = last.first,
               abs(anchor.midY - cell.midY) <= 0.012 {
                last.append(cell)
                groups[groups.count - 1] = last
            } else {
                groups.append([cell])
            }
        }
        return groups.map { $0.sorted { $0.minX < $1.minX } }
    }

    // MARK: 行解析

    private static func parse(_ cells: [Cell], imageIndex: Int) -> ScreenshotTradeRow? {
        let texts = cells.map { $0.text }
        let joined = texts.joined(separator: " ")
        guard let codeRange = joined.range(of: #"(?<!\d)\d{6}(?!\d)"#, options: .regularExpression) else {
            return nil
        }
        let code = String(joined[codeRange])
        let side = joined.contains("卖") ? "卖出" : "买入"
        let time = firstMatch(#"\d{1,2}:\d{2}(?::\d{2})?"#, in: joined) ?? ""

        let numerics: [String] = texts.compactMap { raw in
            let value = raw.replacingOccurrences(of: #"[,，¥￥\s]"#, with: "", options: .regularExpression)
            guard value.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
            // 6 位证券代码本身也是纯数字，必须先剔掉，
            // 否则「第一个可转整数的列」会错指到代码上，整行解析失败。
            if value == code || value.contains(code) || isDateLike(value) { return nil }
            return value
        }
        guard numerics.count >= 3,
              let unitsIndex = numerics.firstIndex(where: { Int64($0) != nil }),
              unitsIndex > 0, unitsIndex + 1 < numerics.count else { return nil }
        let price = numerics[unitsIndex - 1]
        let units = numerics[unitsIndex]
        let amount = numerics[unitsIndex + 1]

        var name = texts.filter { !$0.contains(code) && !$0.contains("成交") && !$0.contains("证券") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = code }
        return ScreenshotTradeRow(code: code, name: name, side: side, time: time,
                                  price: price, units: units, amount: amount,
                                  sourceImageIndex: imageIndex)
    }

    /// 汇总行只要求「6 位代码 + 整数数量 + 金额」，不要求时间戳。
    private static func parseSummary(_ cells: [Cell], imageIndex: Int) -> ScreenshotSummaryRow? {
        let texts = cells.map { $0.text }
        let joined = texts.joined(separator: " ")
        guard let codeRange = joined.range(of: #"(?<!\d)\d{6}(?!\d)"#, options: .regularExpression) else {
            return nil
        }
        let code = String(joined[codeRange])
        let numerics: [String] = texts.compactMap { raw in
            let value = raw.replacingOccurrences(of: #"[,，¥￥\s]"#, with: "", options: .regularExpression)
            guard value.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
            if value == code || value.contains(code) || isDateLike(value) { return nil }
            return value
        }
        guard numerics.count >= 2,
              let unitsIndex = numerics.firstIndex(where: { (Int64($0) ?? 0) >= 1 }) else { return nil }
        let units = numerics[unitsIndex]
        guard let amount = numerics.last, amount != units,
              let unitsValue = Double(units), let amountValue = Double(amount),
              unitsValue > 0, amountValue > 0 else { return nil }
        let side = joined.contains("卖") ? "卖出" : (joined.contains("买") ? "买入" : "")
        var name = texts.filter { !$0.contains(code) && !$0.contains("成交") && !$0.contains("证券") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = code }
        return ScreenshotSummaryRow(code: code, name: name, side: side,
                                    units: units, amount: amount, sourceImageIndex: imageIndex)
    }

    /// 8 位 20xx 开头的纯数字更像 yyyyMMdd 日期，不能当成成交数量。
    private static func isDateLike(_ value: String) -> Bool {
        value.count == 8 && value.hasPrefix("20")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }
}
