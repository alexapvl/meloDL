import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct IndexedFoldersPickerView: View {
    let roots: [String]
    @Binding var selectedRoot: String?
    @Binding var dropTargeted: Bool
    var isDisabled = false
    let emptyTitle: String
    let emptyDescription: String
    let onAdd: () -> Void
    let onRemove: (String) -> Void
    let onDropProviders: ([NSItemProvider]) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            folderList

            HStack(spacing: 10) {
                controls

                Text("Tip: Drag and drop folders into this list to add them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text("\(roots.count) folder\(roots.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.controlBackgroundColor), in: Capsule(style: .continuous))
            }
        }
    }

    private var folderList: some View {
        ZStack {
            if roots.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "folder.badge.plus",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, minHeight: 128)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(roots, id: \.self) { root in
                            folderRow(root)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(minHeight: 150, maxHeight: 190)
        .background(Color(.windowBackgroundColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(isDisabled)
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $dropTargeted,
            perform: handleDrop(providers:)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.2),
                    lineWidth: dropTargeted ? 2 : 1
                )
        }
    }

    private func folderRow(_ root: String) -> some View {
        Button {
            selectedRoot = root
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(root)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill(for: root), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func rowFill(for root: String) -> Color {
        selectedRoot == root
            ? Color.accentColor.opacity(0.62)
            : Color(.controlBackgroundColor).opacity(0.45)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                if let selectedRoot {
                    onRemove(selectedRoot)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .disabled(selectedRoot == nil || isDisabled)
            .buttonStyle(.plain)
            .help("Remove selected folder")

            Divider()
                .frame(height: 16)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .disabled(isDisabled)
            .buttonStyle(.plain)
            .help("Add indexed folder")
        }
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !isDisabled else { return false }
        return onDropProviders(providers)
    }
}
