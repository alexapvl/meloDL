import SwiftUI

struct URLInputView: View {
    @Binding var url: String
    let isDisabled: Bool
    let onSubmitDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("URL:")
                .font(.headline)

            TextField("Paste any supported URL here", text: $url)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disabled(isDisabled)
                .submitLabel(.go)
                .onSubmit(onSubmitDownload)
        }
    }
}

#Preview {
    URLInputView(url: .constant(""), isDisabled: false, onSubmitDownload: {})
        .padding()
}
