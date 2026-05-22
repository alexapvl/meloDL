import AppKit
import SwiftUI

struct URLInputView: View {
    @Binding var url: String
    let isDisabled: Bool
    let onSubmitDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("URL:")
                .font(.headline)

            NoFocusRingTextField(
                placeholder: "Paste any supported URL here",
                text: $url,
                isDisabled: isDisabled,
                onSubmit: onSubmitDownload
            )
            .frame(height: 22)
                .disabled(isDisabled)
        }
    }
}

private struct NoFocusRingTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let isDisabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .none
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
        textField.isEnabled = !isDisabled
        textField.focusRingType = .none
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        @objc
        func submit() {
            onSubmit()
        }
    }
}

#Preview {
    URLInputView(url: .constant(""), isDisabled: false, onSubmitDownload: {})
        .padding()
}
