import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @State private var store: LibraryStore
    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var selection: UUID?
    @State private var path: [UUID] = []
    @State private var pendingDelete: UUID?
    @State private var pendingNavigation: PendingNavigation?
    @State private var alertMessage: String?

    @MainActor
    init() {
        _store = State(initialValue: LibraryStore())
    }

    var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            } detail: {
                if let currentID = selection, store.recording(id: currentID) != nil {
                    EditorView(
                        recordingID: currentID,
                        store: store,
                        onCreatedRecording: { newID in
                            selection = newID
                        },
                        onResolveUnsaved: { continueNavigation() },
                        onCancelUnsaved: { pendingNavigation = nil }
                    )
                    .id(currentID)
                } else {
                    ContentUnavailableView(
                        "没有选择录音",
                        systemImage: "waveform",
                        description: Text("从左侧选择一条录音，或录一段新的。")
                    )
                }
            }
            #else
            NavigationStack(path: $path) {
                sidebar
                    .navigationDestination(for: UUID.self) { id in
                        EditorView(
                            recordingID: id,
                            store: store,
                            onCreatedRecording: { newID in
                                path = [newID]
                            },
                            onAttemptLeave: { requestLeave() },
                            onResolveUnsaved: { continueNavigation() },
                            onCancelUnsaved: { pendingNavigation = nil }
                        )
                    }
            }
            #endif
        }
        .sheet(isPresented: $showRecorder) {
            RecorderView(store: store)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url):
                do {
                    try store.importAudio(from: url)
                    if let imported = store.recordings.first?.id {
                        openRecording(imported)
                    }
                } catch {
                    alertMessage = error.localizedDescription
                }
            case .failure(let error):
                alertMessage = error.localizedDescription
            }
        }
        .alert("无法完成", isPresented: alertIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage ?? store.lastError ?? "")
        }
        .confirmationDialog("要删除这条录音吗？", isPresented: deleteIsPresented, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let pendingDelete {
                    if selection == pendingDelete {
                        selection = nil
                    }
                    if path.last == pendingDelete {
                        path = []
                    }
                    if store.unsaved.recordingID == pendingDelete {
                        store.unsaved.isDirty = false
                        store.unsaved.resetActions()
                    }
                    store.delete(id: pendingDelete)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var sidebar: some View {
        Group {
            if store.recordings.isEmpty {
                ContentUnavailableView(
                    "还没有录音",
                    systemImage: "waveform",
                    description: Text("点击录音开始，或导入已有的音频。")
                )
            } else {
                recordingList
            }
        }
        .navigationTitle("录音")
        .toolbar { toolbar }
    }

    private var recordingList: some View {
        List {
            ForEach(store.recordings) { recording in
                Button {
                    openRecording(recording.id)
                } label: {
                    recordingRow(recording)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .listRowBackground(selection == recording.id ? Color.accentColor.opacity(0.22) : Color.clear)
                .contextMenu { deleteButton(recording.id) }
                #else
                .swipeActions {
                    Button("删除", role: .destructive) {
                        pendingDelete = recording.id
                    }
                }
                #endif
            }
        }
    }

    private func recordingRow(_ recording: Recording) -> some View {
        HStack {
            row(recording)
            Spacer(minLength: 0)
            #if os(iOS)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
            #endif
        }
        .contentShape(Rectangle())
    }

    private func openRecording(_ id: UUID) {
        #if os(iOS)
        let current = path.last
        #else
        let current = selection
        #endif
        guard id != current else { return }
        attempt(navigation: .open(id), from: current)
    }

    private func requestLeave() {
        #if os(iOS)
        let current = path.last
        #else
        let current = selection
        #endif
        attempt(navigation: .leave, from: current)
    }

    private func attempt(navigation: PendingNavigation, from current: UUID?) {
        if store.unsaved.isProcessing, store.unsaved.recordingID == current {
            alertMessage = "正在处理当前录音，请稍后再切换。"
            return
        }
        if let current, store.unsaved.recordingID == current, store.unsaved.isDirty {
            pendingNavigation = navigation
            store.confirmUnsaved = true
            return
        }
        perform(navigation)
    }

    private func continueNavigation() {
        guard let pendingNavigation else { return }
        let navigation = pendingNavigation
        self.pendingNavigation = nil
        perform(navigation)
    }

    private func perform(_ navigation: PendingNavigation) {
        switch navigation {
        case .open(let id):
            #if os(iOS)
            path = [id]
            #else
            selection = id
            #endif
        case .leave:
            #if os(iOS)
            path = []
            #else
            selection = nil
            #endif
        }
    }

    private func row(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.headline)
            Text("\(TimeFormat.dateTime.string(from: recording.createdAt)) · \(TimeFormat.clock(recording.duration))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showImporter = true
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            Button {
                showRecorder = true
            } label: {
                Label("录音", systemImage: "mic.fill")
            }
        }
    }

    private func deleteButton(_ id: UUID) -> some View {
        Button("删除", role: .destructive) {
            pendingDelete = id
        }
    }

    private var importTypes: [UTType] {
        var types: [UTType] = [.wav, .mpeg4Audio]
        if let caf = UTType("com.apple.coreaudio-format") {
            types.append(caf)
        }
        return types
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil || store.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                    store.lastError = nil
                }
            }
        )
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDelete = nil
                }
            }
        )
    }
}

private enum PendingNavigation {
    case open(UUID)
    case leave
}
