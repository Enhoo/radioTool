import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @State private var store: LibraryStore
    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var selection: UUID?
    @State private var pendingDelete: UUID?
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
                if let selection, store.recording(id: selection) != nil {
                    EditorView(recordingID: selection, store: store)
                        .id(selection)
                } else {
                    ContentUnavailableView(
                        "没有选择录音",
                        systemImage: "waveform",
                        description: Text("从左侧选择一条录音，或录一段新的。")
                    )
                }
            }
            #else
            NavigationStack {
                sidebar
                    .navigationDestination(for: UUID.self) { id in
                        EditorView(recordingID: id, store: store)
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
                    selection = store.recordings.first?.id
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
        #if os(macOS)
        List(selection: $selection) {
            ForEach(store.recordings) { recording in
                row(recording)
                    .tag(recording.id)
                    .contextMenu { deleteButton(recording.id) }
            }
        }
        #else
        List {
            ForEach(store.recordings) { recording in
                NavigationLink(value: recording.id) {
                    row(recording)
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        pendingDelete = recording.id
                    }
                }
            }
        }
        #endif
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
