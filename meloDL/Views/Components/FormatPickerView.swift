import SwiftUI

struct FormatPickerView: View {
    @Binding var format: AudioFormat
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Format")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Format", selection: $format) {
                ForEach(AudioFormat.allCases, id: \.self) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
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
