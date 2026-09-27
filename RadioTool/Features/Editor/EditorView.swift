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
    var onCreatedRecording: (UUID) -> Void
    var onAttemptLeave: () -> Void
    var onResolveUnsaved: () -> Void
    var onCancelUnsaved: () -> Void
    @State private var model: EditorModel
    @State private var showShare = false
    @State private var showMacExporter = false
    @State private var showSaveChoice = false
    @State private var shareURL: URL?
    @State private var exportDocument = WAVExportDocument(data: Data())
    @State private var isPreparingExport = false

    @MainActor
    init(
        recordingID: UUID,
        store: LibraryStore,
        onCreatedRecording: @escaping (UUID) -> Void = { _ in },
        onAttemptLeave: @escaping () -> Void = {},
        onResolveUnsaved: @escaping () -> Void = {},
        onCancelUnsaved: @escaping () -> Void = {}
    ) {
        self.recordingID = recordingID
        self.store = store
        self.onCreatedRecording = onCreatedRecording
        self.onAttemptLeave = onAttemptLeave
        self.onResolveUnsaved = onResolveUnsaved
        self.onCancelUnsaved = onCancelUnsaved
        _model = State(initialValue: EditorModel(recordingID: recordingID, store: store))
    }

    var body: some View {
        let _ = store.confirmUnsaved
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
        .onAppear {
            syncUnsavedState()
        }
        .onChange(of: model.isDirty) { _, _ in
            syncUnsavedState()
        }
        .onChange(of: model.isProcessing) { _, _ in
            syncUnsavedState()
        }
        .onDisappear {
            model.stopPlayback()
            if store.unsaved.recordingID == recordingID {
                store.unsaved.isDirty = false
                store.unsaved.isProcessing = false
                store.unsaved.resetActions()
            }
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(model.isDirty)
        .toolbar {
            if model.isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onAttemptLeave) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.backward")
                                .fontWeight(.semibold)
                            Text("录音")
                        }
                    }
                }
            }
        }
        .background(PopGestureGuard(allowPop: !model.isDirty))
        #endif
        .alert("无法完成", isPresented: errorIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("还有未保存的修改", isPresented: unsavedPromptPresented) {
            Button("保留在原文件") {
                model.save()
                syncUnsavedState()
                guard !model.isDirty else { return }
                onResolveUnsaved()
            }
            Button("保存为新文件") {
                guard model.saveAsNew() != nil else { return }
                store.unsaved.isDirty = false
                onResolveUnsaved()
            }
            Button("不保存", role: .destructive) {
                store.unsaved.isDirty = false
                onResolveUnsaved()
            }
            Button("取消", role: .cancel) {
                onCancelUnsaved()
            }
        } message: {
            Text("当前录音的修改还没保存。可以先保存，或放弃修改后再打开其他文件。")
        }
        .alert("如何保存？", isPresented: $showSaveChoice) {
            Button("保存为新文件") {
                if let id = model.saveAsNew() {
                    onCreatedRecording(id)
                }
            }
            Button("保留在原文件") {
                model.save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存为新文件会留下原来的录音。保留在原文件会用当前修改覆盖它。")
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
        .background {
            WaveformTouchBarInstaller(
                peaks: model.peaks,
                frameCount: model.frameCount,
                playhead: model.playhead,
                selectionLower: model.selectionLower,
                selectionUpper: model.selectionUpper,
                isEnabled: !model.isProcessing,
                onScrub: { model.scrub(to: $0) }
            )
            .allowsHitTesting(false)
        }
        #endif
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WaveformView(
                    peaks: model.peaks,
                    channels: model.waveformChannels,
                    revision: model.waveformRevision,
                    frameCount: model.frameCount,
                    sampleRate: model.sampleRate,
                    playhead: model.playhead,
                    isPlaying: model.isPlaying,
                    selectionLower: model.selectionLower,
                    selectionUpper: model.selectionUpper,
                    onScrub: { model.scrub(to: $0) },
                    onSelection: { model.setSelection(lower: $0, upper: $1) }
                )
                .disabled(model.isProcessing)
                Text("单击波形移动红线，按住拖动选择一段。两指撑开放大后，拖动下方滚动条左右移动，点「全部」回到整段。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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

                Picker("倍速", selection: $model.playbackRate) {
                    ForEach(PlaybackRate.allCases) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isProcessing)

                HStack {
                    Button("保留选区") { model.trim() }
                        .disabled(model.isProcessing)
                    Button("删除选区") { model.deleteSelection() }
                        .disabled(model.isProcessing)
                    Button("取消选中") { model.clearSelection() }
                        .disabled(!model.hasSelection || model.isProcessing)
                    Button("复制") { model.copySelection() }
                        .disabled(model.isProcessing)
                    Button("插入") { model.insertCopy() }
                        .disabled(!model.canInsert || model.isProcessing)
                }

                denoiseSection

                effectsSection

                if model.isProcessing {
                    ProgressView(value: model.progress) {
                        Text(model.processingTitle)
                    }
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar
        }
    }

    private var canSave: Bool {
        model.isDirty && !model.isProcessing
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                saveButton
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
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var saveButton: some View {
        if canSave {
            Button("保存") { showSaveChoice = true }
                .buttonStyle(.borderedProminent)
        } else {
            Button("保存") {}
                .buttonStyle(.bordered)
                .foregroundStyle(.primary)
                .allowsHitTesting(false)
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
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("效果")
                .font(.headline)
            Picker("处理范围", selection: $model.effectScope) {
                ForEach(DenoiseScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isProcessing)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("震感")
                    Slider(value: $model.rumble, in: 0...100, step: 1)
                        .disabled(model.isProcessing)
                    Text("\(Int(model.rumble.rounded()))")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Text("加上扎实的低频震动，接近赤脚踩在发声表面上的感觉。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("添加震感") {
                    model.applyRumble()
                }
                .disabled(model.rumble <= 0 || model.isProcessing)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("音量")
                    Slider(value: $model.gainDecibels, in: 0...12, step: 1)
                        .disabled(model.isProcessing)
                    Text("+\(Int(model.gainDecibels.rounded())) dB")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text("提高响度。快到最大音量时会轻轻压限，避免破音。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("加大音量") {
                    model.applyGain()
                }
                .disabled(model.gainDecibels <= 0 || model.isProcessing)
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

    private func syncUnsavedState() {
        let editor = model
        let library = store
        library.unsaved.recordingID = recordingID
        library.unsaved.isDirty = editor.isDirty
        library.unsaved.isProcessing = editor.isProcessing
        library.unsaved.save = {
            editor.save()
            library.unsaved.isDirty = editor.isDirty
        }
        library.unsaved.saveAsNew = {
            editor.saveAsNew()
        }
    }

    private var unsavedPromptPresented: Binding<Bool> {
        Binding(
            get: { store.confirmUnsaved },
            set: { store.confirmUnsaved = $0 }
        )
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

#if os(iOS)
private struct PopGestureGuard: UIViewControllerRepresentable {
    var allowPop: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        DispatchQueue.main.async {
            controller.navigationController?.interactivePopGestureRecognizer?.isEnabled = allowPop
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        controller.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }
}
#endif
