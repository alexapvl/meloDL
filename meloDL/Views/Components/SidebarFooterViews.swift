import SwiftUI

enum SidebarFooterMetrics {
    static let horizontalPadding: CGFloat = 6
    static let buttonHorizontalPadding: CGFloat = 10
    static let buttonVerticalPadding: CGFloat = 7
}

struct SidebarFooterSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, SidebarFooterMetrics.horizontalPadding)
    }
}

struct SidebarFooterButtonLabel: View {
    let title: String
    let systemImage: String
    let isHovered: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, SidebarFooterMetrics.buttonHorizontalPadding)
            .padding(.vertical, SidebarFooterMetrics.buttonVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(buttonFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }

    private var buttonFill: Color {
        isHovered ? Color.primary.opacity(0.08) : .clear
    }
}
