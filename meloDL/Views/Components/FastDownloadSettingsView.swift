import SwiftUI

struct FastDownloadSettingsView: View {
    @Binding var downloadConfiguration: DownloadConfiguration
    let isDisabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle("Fast downloads", isOn: $downloadConfiguration.fastDownloads)
                .font(.headline)
                .disabled(isDisabled)

            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help("Fast downloads automatically chooses worker count based on playlist size and system capacity. Turn off for a safer single-worker mode.")
        }
    }
}

#Preview {
    FastDownloadSettingsView(
        downloadConfiguration: .constant(DownloadConfiguration()),
        isDisabled: false
    )
    .padding()
}
