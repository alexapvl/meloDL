import SwiftUI

struct FormatPickerView: View {
    @Binding var format: AudioFormat
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Format", systemImage: "music.note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Format", selection: $format) {
                ForEach(AudioFormat.allCases, id: \.self) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.large)
            .disabled(isDisabled)
        }
    }
}

#Preview {
    FormatPickerView(
        format: .constant(.mp3),
        isDisabled: false
    )
    .padding()
}
