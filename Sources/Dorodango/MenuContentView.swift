import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The panel shown when the menu bar icon is clicked.
struct MenuContentView: View {
    @EnvironmentObject var queue: ProcessingQueue
    @EnvironmentObject var panelState: PanelState
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            if panelState.showSettings {
                SettingsView()
                    .transition(.opacity)
            } else {
                DropZone(onFiles: { queue.add(urls: $0) },
                         onURL: { queue.add(remote: $0) },
                         focused: $urlFocused)
                QueueListView()
            }
        }
        .padding(12)
        .frame(width: 340)
        // A tap anywhere that isn't the field (or another control) falls through
        // to this background and dismisses the text cursor. As a background it
        // matches the content size, so the panel still resizes correctly.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { urlFocused = false }
        )
    }

    private var header: some View {
        HStack {
            Image(systemName: "circle.circle")
            Text("Dorodango").font(.headline)
            Spacer()
            Button {
                withAnimation { panelState.showSettings.toggle() }
            } label: {
                Image(systemName: panelState.showSettings ? "list.bullet" : "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help(panelState.showSettings ? "Back to queue" : "Processing settings")
        }
    }

}

/// Combined drop target + URL field: drop files, or click anywhere in the zone
/// to focus the field and ⌘V a URL, then ↩ to enqueue it.
struct DropZone: View {
    let onFiles: ([URL]) -> Void
    let onURL: (String) -> Void
    var focused: FocusState<Bool>.Binding

    @State private var link = ""
    @State private var isTargeted = false

    private var isURL: Bool { link.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http") }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title2)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            // Only this field grabs the cursor; tapping anywhere else clears it.
            TextField("Drop a video, or paste a URL", text: $link)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.caption)
                .frame(maxWidth: 230)
                .focused(focused)
                .onSubmit(submit)

            HStack(spacing: 12) {
                Button("Add files…") { pickFiles() }
                    .buttonStyle(.borderless).font(.caption)
                if isURL {
                    Button("Add URL", action: submit)
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(isTargeted || focused.wrappedValue ? Color.accentColor
                                                                    : Color.secondary.opacity(0.4))
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func submit() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("http") else { return }
        onURL(trimmed)
        link = ""
        focused.wrappedValue = false
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { onFiles(collected) }
        return true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        if panel.runModal() == .OK { onFiles(panel.urls) }
    }
}

/// Queue section. Renders nothing until there are items; once populated it
/// shows a header (with Clear done, when there's anything finished) and the
/// per-item rows, growing up to ~6 items then scrolling.
struct QueueListView: View {
    @EnvironmentObject var queue: ProcessingQueue

    private var hasFinished: Bool {
        queue.items.contains {
            switch $0.status {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    var body: some View {
        if !queue.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Queue").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if hasFinished {
                        Button("Clear done") { queue.clearFinished() }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                    }
                }

                let rows = VStack(spacing: 6) {
                    ForEach(queue.items) { item in
                        QueueRowView(item: item)
                    }
                }
                if queue.items.count > 6 {
                    ScrollView { rows }.frame(height: 320)
                } else {
                    rows
                }
            }
        }
    }
}

struct QueueRowView: View {
    @ObservedObject var item: QueueItem
    @EnvironmentObject var queue: ProcessingQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.status.symbolName)
                    .foregroundStyle(item.status.tint)
                if item.isRemote && item.status == .queued {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                Spacer()
                if item.status.isActive {
                    Button {
                        queue.cancelCurrent()
                    } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless)
                        .help("Cancel")
                } else if case .done = item.status {
                    Button {
                        if let out = item.outputURL {
                            NSWorkspace.shared.activateFileViewerSelecting([out])
                        }
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                } else {
                    Button {
                        queue.remove(item)
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }

            if item.status.isActive {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
            }

            if !item.detail.isEmpty {
                Text(item.detail).font(.caption2).foregroundStyle(.secondary)
            } else if case .failed(let msg) = item.status {
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}
