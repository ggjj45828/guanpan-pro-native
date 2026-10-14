import SwiftUI

/// 「网页版账本」卡片 —— 把 App 的账本单向写回 NAS 上网页版用的那份文档。
///
/// 为什么单独做成一张卡，而不是塞进 NAS 那堆按钮里：
/// 它是一个**方向明确、只动账本**的动作（App 为准 → 网页），
/// 混在「上传 / 下载 / 历史版本」中间既容易误触，也说不清它到底改了什么。
struct WebLedgerSyncCard: View {
    @EnvironmentObject var store: PortfolioStore
    @State private var enabled = false
    @State private var working = false

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Toggle("自动写回（在 App 里买卖后，网页版跟着变）", isOn: $enabled)
                .scaledFont(13)
                .onChange(of: enabled) { _, value in store.setWebLedgerWriteBack(value) }
            WebLedgerSyncActions(working: $working, canRestore: store.hasWebLedgerBackup)
            statusRow
            Text("只写回账本：现金、持仓、自选、交易记录、场外基金与净值、资金流水、快照、手填价。"
                + "NAS 上那份的设置、分红参考、汇率、休市日、网格历史原样保留；"
                + "读不回现有文档时会直接放弃写回，不会拿空账本去覆盖。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .plainCard(isLight: isLight)
        .onAppear { enabled = store.webLedgerWriteBackEnabled }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.square.on.square")
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(Color.accentColor)
            Text("网页版账本").scaledFont(14, weight: .semibold)
            Spacer(minLength: 0)
            Text("App 为准")
                .scaledFont(10, weight: .semibold)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14), in: Capsule(style: .continuous))
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(statusTint).frame(width: 6, height: 6).padding(.top, 5)
                Text(store.webLedgerStatus).scaledFont(11).foregroundStyle(.secondary)
            }
            if let date = store.webLedgerBackupDate {
                Text("写回前备份：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .scaledFont(10).foregroundStyle(.tertiary)
            }
        }
    }

    /// 状态灯的取色：只按文案里有没有「失败 / 跳过 / 没有」判断，不额外维护一套状态机。
    private var statusTint: Color {
        let text = store.webLedgerStatus
        if text.contains("失败") { return .red }
        if text.contains("跳过") || text.contains("未配置") || text.contains("没有") { return .orange }
        if text.hasPrefix("已") { return .green }
        return .secondary
    }
}

/// 两个动作按钮单独成视图：卡片本体只负责排布，按钮状态各自独立。
private struct WebLedgerSyncActions: View {
    @EnvironmentObject var store: PortfolioStore
    @Binding var working: Bool
    let canRestore: Bool

    var body: some View {
        HStack(spacing: 8) {
            WebLedgerActionButton(
                title: working ? "写回中…" : "立即写回",
                icon: "arrow.up.circle",
                emphasized: true,
                disabled: working
            ) {
                working = true
                Task {
                    await store.writeBackWebLedger(reason: "手动")
                    working = false
                }
            }
            WebLedgerActionButton(
                title: "还原上次",
                icon: "arrow.uturn.backward.circle",
                emphasized: false,
                disabled: working || !canRestore
            ) {
                working = true
                Task {
                    await store.restorePreviousWebLedger()
                    working = false
                }
            }
        }
    }
}

private struct WebLedgerActionButton: View {
    let title: String
    let icon: String
    let emphasized: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .scaledFont(12, weight: .medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var tint: Color {
        emphasized ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemBackground).opacity(0.6)
    }

    private var foreground: Color {
        emphasized ? .accentColor : .primary
    }
}
