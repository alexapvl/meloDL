import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct IndexedFoldersPickerView: View {
    let roots: [String]
    var rootTrackCounts: [String: Int] = [:]
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
        IndexedFolderRow(
            root: root,
            trackCount: rootTrackCounts[root, default: 0],
            isSelected: selectedRoot == root,
            isDisabled: isDisabled
        ) {
            selectedRoot = root
        } onOpen: {
            openFolder(root)
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            IndexedFolderControlButton(systemImage: "minus", isDisabled: selectedRoot == nil || isDisabled) {
                if let selectedRoot {
                    onRemove(selectedRoot)
                }
            }
            .help("Remove selected folder")

            Divider()
                .frame(height: 16)

            IndexedFolderControlButton(systemImage: "plus", isDisabled: isDisabled, action: onAdd)
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

    private func openFolder(_ root: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: root, isDirectory: true))
    }
}

private struct IndexedFolderRow: View {
    let root: String
    let trackCount: Int
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                rowLabel
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            Button {
                onOpen()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .meloBorderedButton()
            .disabled(isDisabled)
            .help("Open folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var rowLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Text(root)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(" - \(trackCount) \(trackWord)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var trackWord: String {
        trackCount == 1 ? "Track" : "Tracks"
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(isHovered ? 0.70 : 0.62)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}

private struct IndexedFolderControlButton: View {
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(isDisabled ? .secondary : .primary)
                .frame(width: 30, height: 26)
                .background(backgroundFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .scaleEffect(isPressed ? 0.985 : 1)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var backgroundFill: Color {
        guard !isDisabled else { return .clear }
        if isPressed {
            return Color.primary.opacity(0.10)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}
