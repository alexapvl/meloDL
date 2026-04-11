import SwiftUI

struct PlaylistSettingsView: View {
    @Binding var downloadConfiguration: DownloadConfiguration
    let isDisabled: Bool

    var body: some View {
        FastDownloadSettingsView(
            downloadConfiguration: $downloadConfiguration,
            isDisabled: isDisabled
        )
        .padding(.vertical, 2)
        .accessibilityLabel("Fast download settings")
        .accessibilityHint("Toggles automatic worker scaling based on playlist size")
        }
}

#Preview {
    PlaylistSettingsView(
        downloadConfiguration: .constant(DownloadConfiguration()),
        isDisabled: false
    )
    .padding()
}
