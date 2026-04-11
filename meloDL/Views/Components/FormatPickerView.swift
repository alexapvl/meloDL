import SwiftUI

struct FormatPickerView: View {
    @Binding var audioSettings: AudioSettings
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Format")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("Format", selection: $audioSettings.format) {
                        ForEach(AudioFormat.allCases, id: \.self) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(isDisabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("Quality", selection: $audioSettings.quality) {
                        ForEach(AudioQuality.allCases, id: \.self) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(isDisabled)
                }
            }

            HStack(spacing: 16) {
                Toggle("Embed metadata", isOn: $audioSettings.embedMetadata)
                    .disabled(isDisabled)

                if audioSettings.format.supportsThumbnailEmbed {
                    Toggle("Embed thumbnail", isOn: $audioSettings.embedThumbnail)
                        .disabled(isDisabled)
                }
            }
            .font(.subheadline)
        }
    }
}

#Preview {
    FormatPickerView(
        audioSettings: .constant(AudioSettings()),
        isDisabled: false
    )
    .padding()
}
