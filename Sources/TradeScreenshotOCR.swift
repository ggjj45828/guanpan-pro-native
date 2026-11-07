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

enum ScreenshotOCRError: Error, LocalizedError {
    case invalidImage
    case noText
    case unparsedTradeRows(Int)
    case amountMismatch([Int])

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "有一张图片无法读取"
        case .noText: return "截图里没有识别到文字"
        case .unparsedTradeRows(let count):
            return "有 \(count) 行看起来是成交记录但没解析出来，已拦截，请改用表格导入或手动录入"
        case .amountMismatch(let rows):
            return "第 \(rows.map(String.init).joined(separator: "、")) 行的「价格 × 数量」与成交金额不一致，已拦截"
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
            if value == code || value.contains(code) { return nil }
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

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }
}
