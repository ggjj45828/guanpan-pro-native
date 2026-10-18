import SwiftUI

enum ProStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let line = Color.primary.opacity(0.09)
    static func change(_ value: Double) -> Color { value > 0 ? Color(red: 0.78, green: 0.23, blue: 0.24) : value < 0 ? Color(red: 0.07, green: 0.49, blue: 0.38) : .secondary }
}
struct ProPage<Content: View>: View {
    @Environment(\.appAppearance) private var appearance
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).scaledFont(30, weight: .bold).accessibilityIdentifier("workspace.title")
                    Text(subtitle).scaledFont(15).foregroundStyle(.secondary)
                }.padding(.top, 12)
                content()
            }.frame(maxWidth: 1080, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 32).frame(maxWidth: .infinity)
        }.background(AppTheme.palette(for: AppAppearance.resolved(appearance)).gradient.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline).buttonStyle(.plain)
    }
}
struct ProSectionTitle: View {
    let title: String
    var detail = ""
    var body: some View { HStack(alignment: .firstTextBaseline) { Text(title).scaledFont(17, weight: .semibold); Spacer(); Text(detail).scaledFont(13).foregroundStyle(.secondary) } }
}
struct ProActionRow: View {
    let title: String
    let detail: String
    let icon: String
    var tone: Color = .accentColor
    @State private var showDetail = false
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).scaledFont(17, weight: .semibold).foregroundStyle(tone).frame(width: 36, height: 36)
                .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).scaledFont(16, weight: .medium).foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").scaledFont(13, weight: .semibold).foregroundStyle(.tertiary)
        }.padding(.vertical, 12).contentShape(Rectangle())
            .accessibilityHint("長按查看介绍")
            .help(detail)
            .onLongPressGesture(minimumDuration: 0.45) { showDetail = true }
            .alert(title, isPresented: $showDetail) { Button("知道了", role: .cancel) {} } message: { Text(detail) }
    }
}
struct ProMetric: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).scaledFont(13).foregroundStyle(.secondary)
            Text(value).scaledFont(20, weight: .semibold, design: .rounded).monospacedDigit().foregroundStyle(color).minimumScaleFactor(0.65).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct ProEmpty: View {
    let title: String
    let detail: String
    var icon = "tray"
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).scaledFont(30, weight: .light).foregroundStyle(.secondary)
            Text(title).scaledFont(17, weight: .semibold)
            Text(detail).scaledFont(15).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}
extension View {
    func proSurface(tone: Color = .accentColor) -> some View {
        padding(20)
            .background {
                RoundedRectangle(cornerRadius: 22).fill(ProStyle.surface)
                    .overlay(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [tone.opacity(0.17), tone.opacity(0.07), tone.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LinearGradient(colors: [tone.opacity(0.82), tone.opacity(0.42), tone.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.4))
            .shadow(color: tone.opacity(0.12), radius: 15, x: 0, y: 6)
    }
}
