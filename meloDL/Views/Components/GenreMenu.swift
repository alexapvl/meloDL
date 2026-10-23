import SwiftUI

/// Picks a Rekordbox genre from the loaded collection's genres.
/// A nil selection inherits `inheritedGenre`; an empty string means no genre.
struct GenreMenu<Label: View>: View {
    let genres: [String]
    let selection: String?
    /// The genre a nil selection falls back to. nil when this menu sets the default itself.
    let inheritedGenre: String?
    let onSelect: (String?) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isEnteringCustomGenre = false
    @State private var customGenre = ""

    var body: some View {
        Menu {
            if let inheritedGenre {
                genreButton(
                    inheritedGenre.isEmpty ? "Default (no genre)" : "Default (\(inheritedGenre))",
                    value: nil
                )
            }
            if inheritedGenre == nil || inheritedGenre?.isEmpty == false {
                genreButton("No genre", value: "")
            }

            Divider()

            if let selection, !selection.isEmpty, !genres.contains(selection) {
                genreButton(selection, value: selection)
            }
            ForEach(genres, id: \.self) { genre in
                genreButton(genre, value: genre)
            }

            Divider()

            Button("Other…") {
                customGenre = ""
                isEnteringCustomGenre = true
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .focusable(false)
        .alert("Genre", isPresented: $isEnteringCustomGenre) {
            TextField("Genre", text: $customGenre)
            Button("Cancel", role: .cancel) {}
            Button("Use Genre") {
                let genre = customGenre.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !genre.isEmpty else { return }
                onSelect(genre)
            }
        } message: {
            Text("Type a genre that isn't in your Rekordbox collection yet.")
        }
    }

    @ViewBuilder
    private func genreButton(_ title: String, value: String?) -> some View {
        Button {
            onSelect(value)
        } label: {
            if selection == value {
                SwiftUI.Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
