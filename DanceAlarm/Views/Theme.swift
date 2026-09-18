import SwiftUI

/// 配色。与安卓版保持一致，两端看起来是同一个产品。
enum Brand {
    static let accent = Color(red: 1.00, green: 0.42, blue: 0.21)   // #FF6B35
    static let ok = Color(red: 0.20, green: 0.84, blue: 0.29)       // #32D74B
    static let warn = Color(red: 1.00, green: 0.69, blue: 0.13)     // #FFB020
    static let bad = Color(red: 1.00, green: 0.27, blue: 0.23)      // #FF453A

    static let warnCard = Color(red: 1.00, green: 0.95, blue: 0.91)
    static let warnTitle = Color(red: 0.70, green: 0.29, blue: 0.06)
    static let infoCard = Color(red: 0.93, green: 0.95, blue: 1.00)
    static let infoTitle = Color(red: 0.11, green: 0.29, blue: 0.63)

    static let page = Color(red: 0.98, green: 0.97, blue: 0.96)
    static let subText = Color(red: 0.48, green: 0.43, blue: 0.41)
    static let faint = Color(red: 0.60, green: 0.56, blue: 0.53)
    static let divider = Color.black.opacity(0.08)
}

extension DancePhase {
    /// 判定状态对应的强调色：在跳=绿，动作不够=黄，其他=红
    var tint: Color {
        switch self {
        case .dancing: return Brand.ok
        case .tooStill: return Brand.warn
        case .phoneShaking, .halfBody, .noPerson: return Brand.bad
        }
    }
}

/// 统一的卡片容器
struct CardBox<Content: View>: View {
    let background: Color
    private let content: Content

    init(background: Color = .white, @ViewBuilder content: () -> Content) {
        self.background = background
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(background)
            )
    }
}

/// 小节标题
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Brand.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }
}
