import SwiftUI

struct URLInputView: View {
    @Binding var url: String
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("URL:")
                .font(.headline)

            TextField("Paste any supported URL here", text: $url)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disabled(isDisabled)
        }
    }
}

#Preview {
    URLInputView(url: .constant(""), isDisabled: false)
        .padding()
}
