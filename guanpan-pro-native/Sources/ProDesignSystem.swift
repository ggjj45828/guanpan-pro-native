import SwiftUI

enum ProStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let line = Color.primary.opacity(0.09)
    static func change(_ value: Double) -> Color { value > 0 ? Color(red: 0.78, green: 0.23, blue: 0.24) : value < 0 ? Color(red: 0.07, green: 0.49, blue: 0.38) : .secondary }
}
struct ProPage<Content: View>: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.visualTheme) private var visualTheme
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        let tokens = ThemeManager.tokens(visualTheme)
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.gap + 5) {
                ZStack(alignment: .leading) {
                    if visualTheme == .eastern || visualTheme == .magazine {
                        LandscapeDecoration(color: tokens.accent)
                            .frame(width: 185, height: visualTheme == .magazine ? 88 : 70)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(visualTheme == .magazine
                                  ? .system(size: 31, weight: .bold, design: .serif)
                                  : .system(size: visualTheme == .dashboard ? 25 : 29,
                                            weight: .bold, design: .rounded))
                            .accessibilityIdentifier("workspace.title")
                        Text(subtitle).scaledFont(14).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, minHeight: visualTheme == .magazine ? 88 : 66,
                        alignment: .leading)
                    .padding(.top, 8)
                content()
            }.frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, tokens.pageInset)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
        }.background(tokens.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline).buttonStyle(.plain)
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
            Text(title).scaledFont(16, weight: .medium).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").scaledFont(13, weight: .semibold).foregroundStyle(.tertiary)
        }.padding(.vertical, 10).contentShape(Rectangle())
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
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
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
        modifier(ProSurfaceModifier(tone: tone))
    }
}

private struct ProSurfaceModifier: ViewModifier {
    @Environment(\.visualTheme) private var visualTheme
    let tone: Color
    func body(content: Content) -> some View {
        let tokens = ThemeManager.tokens(visualTheme)
        let shape = RoundedRectangle(cornerRadius: tokens.corner, style: .continuous)
        return content
            .padding(visualTheme == .dashboard ? 14 : 17)
            .background {
                shape.fill(tokens.surface)
                    .overlay(shape.fill(LinearGradient(colors: [
                        tone.opacity(visualTheme == .bento ? 0.31 : visualTheme == .dashboard ? 0.17 : 0.11),
                        tone.opacity(visualTheme == .bento ? 0.14 : 0.035)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .overlay(shape.strokeBorder(tone.opacity(visualTheme == .dashboard ? 0.46 : 0.27),
                                        lineWidth: 1))
            .shadow(color: tone.opacity(visualTheme == .magazine ? 0.14 : 0.08),
                    radius: visualTheme == .magazine ? 15 : 9, x: 0, y: 5)
    }
}
