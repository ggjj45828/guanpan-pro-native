import SwiftUI

enum ProStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let line = Color.primary.opacity(0.09)
    static func change(_ value: Double) -> Color { value > 0 ? Color(red: 0.78, green: 0.23, blue: 0.24) : value < 0 ? Color(red: 0.07, green: 0.49, blue: 0.38) : .secondary }
}
struct ProPage<Content: View>: View {
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
        }.background(ProStyle.background).navigationBarTitleDisplayMode(.inline).buttonStyle(.plain)
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
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).scaledFont(19, weight: .medium).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).scaledFont(16, weight: .medium).foregroundStyle(.primary)
                Text(detail).scaledFont(13).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").scaledFont(13, weight: .semibold).foregroundStyle(.tertiary)
        }.padding(.vertical, 14).contentShape(Rectangle())
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
                    .overlay(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [tone.opacity(0.09), tone.opacity(0.015), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LinearGradient(colors: [tone.opacity(0.76), tone.opacity(0.3), tone.opacity(0.58)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.25))
            .shadow(color: tone.opacity(0.08), radius: 15, x: 0, y: 6)
    }
}
