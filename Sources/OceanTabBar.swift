import SwiftUI

// MARK: - 蓝海浅色专用底栏
//
// 与 `ProTabBar` 是两套独立版式，不是同一组件换色：
//   · tech  ：悬浮胶囊、四格、中央探出的渐变 AI 球。
//   · ocean ：贴底全宽平铺栏、五项等分、AI 只是普通一格（蓝色圆形图标）。
// 浅色主题不做悬浮球：白底上悬浮球的绿色光晕没有依托，反而会显得脏。

struct OceanTabBar: View {
    @Binding var selection: ProTab
    let accent: Color
    let isLight: Bool
    var onAITap: () -> Void = {}

    private var palette: DsPalette { DsPalette(isLight: isLight, layout: .ocean) }

    var body: some View {
        HStack(spacing: 0) {
            item(.home)
            item(.holdings)
            aiItem
            item(.assets)
            item(.more)
        }
        .padding(.horizontal, 6)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .background {
            Rectangle()
                .fill(isLight ? Color.white : Color(hex: 0x0E1411))
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            Rectangle().fill(palette.hairline).frame(height: 1)
        }
    }

    private func item(_ tab: ProTab) -> some View {
        let selected = selection == tab
        return Button {
            Haptics.tap()
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: selected ? tab.icon : tab.inactiveIcon)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(height: 26)
                Text(tab.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? accent : palette.ink3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var aiItem: some View {
        Button {
            Haptics.push()
            onAITap()
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(accent.opacity(0.12)).frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(height: 26)
                Text("AI")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(palette.ink2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI 顾问")
    }
}
