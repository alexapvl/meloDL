import SwiftUI

struct SwipeGestureTipAnimationView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .frame(width: 86, height: 54)

            HStack(spacing: 9) {
                fingertip
                fingertip
            }
            .offset(x: isAnimating ? 12 : -12)
            .opacity(isAnimating ? 0.95 : 0.7)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isAnimating
            )
        }
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }

    private var fingertip: some View {
        Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 10, height: 10)
            .shadow(color: .white.opacity(0.2), radius: 2, y: 1)
    }
}
