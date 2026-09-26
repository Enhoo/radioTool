import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit

struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

struct WAVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct EditorView: View {
    let recordingID: UUID
    var store: LibraryStore
    @State private var model: EditorModel
    @State private var showShare = false
    @State private var showMacExporter = false
    @State private var shareURL: URL?
    @State private var exportDocument = WAVExportDocument(data: Data())
    @State private var isPreparingExport = false

    @MainActor
    init(recordingID: UUID, store: LibraryStore) {
        self.recordingID = recordingID
        self.store = store
        _model = State(initialValue: EditorModel(recordingID: recordingID, store: store))
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("正在打开…")
            } else if model.frameCount == 0 && model.errorMessage != nil {
                ContentUnavailableView("无法打开", systemImage: "waveform.slash", description: Text(model.errorMessage ?? ""))
            } else {
                editor
            }
        }
        .navigationTitle(model.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await model.load()
        }
        .onDisappear {
            model.stopPlayback()
        }
        .alert("无法完成", isPresented: errorIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ActivityShareSheet(url: shareURL)
            }
        }
        #else
        .fileExporter(
            isPresented: $showMacExporter,
            document: exportDocument,
            contentType: .wav,
            defaultFilename: model.title
        ) { result in
            if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        #endif
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WaveformView(
                    peaks: model.peaks,
                    frameCount: model.frameCount,
                    playhead: model.playhead,
                    selectionLower: model.selectionLower,
                    selectionUpper: model.selectionUpper,
                    onScrub: { model.scrub(to: $0) },
                    onSelection: { model.setSelection(lower: $0, upper: $1) }
                )
                .disabled(model.isProcessing)

                HStack {
                    Text(TimeFormat.clock(model.playheadTime, tenths: true))
                    Text("/")
                    Text(TimeFormat.clock(model.duration))
                    Spacer()
                    Text(model.isDirty ? "未保存" : "已保存")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack {
                    Button(model.isPlaying ? "暂停" : "播放") {
                        model.togglePlayback()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button("撤销") { model.undo() }
                        .disabled(!model.canUndo || model.isProcessing)
                    Button("重做") { model.redo() }
                        .disabled(!model.canRedo || model.isProcessing)
                }

                HStack {
                    Button("保留选区") { model.trim() }
                        .disabled(model.isProcessing)
                    Button("删除选区") { model.deleteSelection() }
                        .disabled(model.isProcessing)
                }

                denoiseSection

                HStack {
                    Button("保存") { model.save() }
                        .disabled(!model.isDirty || model.isProcessing)
                        .buttonStyle(.borderedProminent)
                    Button(isPreparingExport ? "正在导出…" : "导出") {
                        prepareExport()
                    }
                    .disabled(model.isProcessing || isPreparingExport)
                }

                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private var denoiseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("去噪强度")
                Slider(value: $model.strength, in: 0...100)
                    .disabled(model.isProcessing)
                Text("\(Int(model.strength.rounded()))")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            Picker("处理范围", selection: $model.scope) {
                ForEach(DenoiseScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isProcessing)
            Toggle("用选区作为噪声样本", isOn: $model.useSelectionAsNoise)
                .disabled(model.isProcessing)
            Text("适合减弱风扇、底噪、嘶声和交流声这类比较稳定的噪声。突发噪声和嘈杂人声的效果有限。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("去噪") {
                model.denoise()
            }
            .disabled(model.strength <= 0 || model.isProcessing)
            if model.isProcessing {
                ProgressView(value: model.progress) {
                    Text("正在去噪…")
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func prepareExport() {
        isPreparingExport = true
        let samples = model
        Task {
            do {
                let url = try samples.makeExportURL()
                #if os(macOS)
                let data = try Data(contentsOf: url)
                exportDocument = WAVExportDocument(data: data)
                showMacExporter = true
                #else
                shareURL = url
                showShare = true
                #endif
            } catch {
                model.errorMessage = error.localizedDescription
            }
            isPreparingExport = false
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil && model.frameCount > 0 },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }
}
