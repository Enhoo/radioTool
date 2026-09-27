import Foundation
import Observation

enum PlaybackRate: Double, CaseIterable, Identifiable {
    case half = 0.5
    case normal = 1
    case faster = 1.5
    case double = 2
    case triple = 3

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .half: return "0.5倍"
        case .normal: return "1倍"
        case .faster: return "1.5倍"
        case .double: return "2倍"
        case .triple: return "3倍"
        }
    }
}

enum DenoiseScope: String, CaseIterable, Identifiable {
    case entire
    case selection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entire: return "整段"
        case .selection: return "仅选区"
        }
    }
}

@Observable
final class EditorModel {
    let recordingID: UUID
    private let store: LibraryStore
    private let player = PlayerEngine()
    private var session = EditSession(samples: AudioSamples(sampleRate: 48_000, channels: [[]]))
    private var hasLoaded = false
    private var clipboard: AudioSamples?
    private var progressSink: ProgressSink?
    private var progressTimer: Timer?

    var title: String
    var isLoading = true
    var isProcessing = false
    var isPlaying = false
    var playbackRate: PlaybackRate = .normal {
        didSet {
            player.rate = Float(playbackRate.rawValue)
        }
    }
    var isDirty = false
    var progress: Double = 0
    var strength: Double = 70
    var useSelectionAsNoise = false
    var scope: DenoiseScope = .entire
    var rumble: Double = 70
    var gainDecibels: Double = 6
    var effectScope: DenoiseScope = .entire
    var processingTitle = "正在处理…"
    var statusMessage: String?
    var errorMessage: String?
    var peaks = WaveformPeaks.empty
    var waveformRevision = 0

    var waveformChannels: [[Float]] {
        session.samples.channels
    }
    var selectionLower = 0
    var selectionUpper = 0
    var playhead = 0
    var canUndo = false
    var canRedo = false
    var canInsert = false
    var frameCount = 0
    var sampleRate = 48_000.0

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    var playheadTime: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(playhead) / sampleRate
    }

    init(recordingID: UUID, store: LibraryStore) {
        self.recordingID = recordingID
        self.store = store
        self.title = store.recording(id: recordingID)?.title ?? "录音"
        player.onFrame = { [weak self] frame in
            self?.playhead = frame
            self?.session.setPlayhead(frame)
        }
        player.onFinish = { [weak self] in
            self?.isPlaying = false
        }
    }

    func load() async {
        let request: (proceed: Bool, url: URL?) = await MainActor.run {
            guard !hasLoaded else { return (false, nil) }
            hasLoaded = true
            return (true, store.fileURL(id: recordingID))
        }
        guard request.proceed else { return }
        guard let url = request.url else {
            await MainActor.run {
                errorMessage = "找不到这条录音。"
                isLoading = false
            }
            return
        }
        do {
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioFileStore.read(url: url)
            }.value
            let waveform = await Task.detached(priority: .userInitiated) {
                WaveformPeaks.make(channels: samples.channels)
            }.value
            await MainActor.run {
                session = EditSession(samples: samples)
                sync()
                peaks = waveform
                waveformRevision += 1
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        do {
            try player.play(samples: session.samples, from: session.playhead)
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scrub(to frame: Int) {
        let wasPlaying = player.isPlaying
        session.setPlayhead(frame)
        playhead = session.playhead
        guard wasPlaying else { return }
        do {
            try player.play(samples: session.samples, from: session.playhead)
            isPlaying = true
        } catch {
            isPlaying = false
            errorMessage = error.localizedDescription
        }
    }

    var hasSelection: Bool { selectionUpper > selectionLower }

    func setSelection(lower: Int, upper: Int) {
        session.setSelection(lower: lower, upper: upper)
        selectionLower = session.selection.lowerBound
        selectionUpper = session.selection.upperBound
    }

    func clearSelection() {
        guard hasSelection else { return }
        setSelection(lower: 0, upper: 0)
        statusMessage = "已取消选中。"
    }

    func trim() {
        stopPlayback()
        guard session.selection.count > 0 else {
            statusMessage = "请先在波形上按住拖动，选出一段音频。"
            return
        }
        guard session.trimToSelection() else {
            statusMessage = "选区已经覆盖整段音频。"
            return
        }
        finishEdit(message: "已保留选区。")
    }

    func deleteSelection() {
        stopPlayback()
        guard session.selection.count > 0 else {
            statusMessage = "请先在波形上按住拖动，选出一段音频。"
            return
        }
        guard session.deleteSelection() else {
            errorMessage = AudioToolError.nothingToDelete.errorDescription
            return
        }
        finishEdit(message: "已删除选区。")
    }

    func copySelection() {
        guard session.selection.count > 0 else {
            statusMessage = "请先在波形上按住拖动，选出要复制的一段。"
            return
        }
        clipboard = session.samples.trimming(to: session.selection)
        canInsert = true
        setSelection(lower: 0, upper: 0)
        statusMessage = "已复制选区。把红线移到目标位置后，点插入。"
    }

    func insertCopy() {
        guard let clipboard, clipboard.frameCount > 0 else {
            statusMessage = "还没有复制内容。"
            return
        }
        stopPlayback()
        session.insert(clipboard, after: session.playhead)
        finishEdit(message: "已插入到红线后面。")
    }

    func undo() {
        stopPlayback()
        session.undo()
        finishEdit(message: nil)
    }

    func redo() {
        stopPlayback()
        session.redo()
        finishEdit(message: nil)
    }

    func denoise() {
        guard !isProcessing else { return }
        let amount = Float(strength / 100)
        guard amount > 0 else { return }
        stopPlayback()
        let channels = session.samples.channels
        let rate = session.samples.sampleRate
        let noiseRange = useSelectionAsNoise ? session.selection : nil
        let applyRange = scope == .selection ? session.selection : 0..<session.samples.frameCount
        guard applyRange.count > 1 else { return }
        isProcessing = true
        progress = 0
        statusMessage = nil
        processingTitle = "正在去噪…"
        let sink = ProgressSink()
        progressSink = sink
        startProgressTimer(sink)
        Task { @MainActor in
            let updated = await Task.detached(priority: .userInitiated) {
                SpectralDenoiser.processChannels(
                    channels: channels,
                    sampleRate: rate,
                    strength: amount,
                    noiseFrameRange: noiseRange,
                    applyFrameRange: applyRange,
                    progress: { sink.set($0) }
                )
            }.value
            self.stopProgressTimer()
            self.session.replace(with: AudioSamples(sampleRate: rate, channels: updated))
            self.progress = 1
            self.isProcessing = false
            self.finishEdit(message: "去噪已应用到当前录音，保存后才会写回文件。")
        }
    }

    func applyRumble() {
        let amount = Float(rumble / 100)
        guard amount > 0 else { return }
        runOfflineEdit(
            processingTitle: "正在添加震感…",
            success: "震感已加上，保存后才会写回文件。"
        ) { channels, rate, range, report in
            AudioEffects.applyRumble(
                channels: channels,
                sampleRate: rate,
                strength: amount,
                applyFrameRange: range,
                progress: report
            )
        }
    }

    func applyGain() {
        let decibels = Float(gainDecibels)
        guard decibels > 0 else { return }
        runOfflineEdit(
            processingTitle: "正在加大音量…",
            success: "音量已加大，保存后才会写回文件。"
        ) { channels, rate, range, report in
            AudioEffects.applyGain(
                channels: channels,
                sampleRate: rate,
                decibels: decibels,
                applyFrameRange: range,
                progress: report
            )
        }
    }

    func save() {
        do {
            try store.replaceAudio(id: recordingID, samples: session.samples)
            isDirty = false
            statusMessage = "已保存到原文件。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveAsNew() -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyTitle = trimmed.isEmpty ? "录音副本" : "\(trimmed) 副本"
        do {
            return try store.saveAsNew(samples: session.samples, title: copyTitle)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func makeExportURL() throws -> URL {
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = safeTitle.isEmpty ? "录音" : safeTitle
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).wav")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try AudioFileStore.write(session.samples, to: url)
        return url
    }

    func stopPlayback() {
        player.stop()
        isPlaying = false
    }

    private func runOfflineEdit(
        processingTitle: String,
        success: String,
        transform: @escaping @Sendable ([[Float]], Double, Range<Int>, @escaping (Double) -> Void) -> [[Float]]
    ) {
        guard !isProcessing else { return }
        stopPlayback()
        let channels = session.samples.channels
        let rate = session.samples.sampleRate
        let applyRange = effectScope == .selection ? session.selection : 0..<session.samples.frameCount
        guard applyRange.count > 1 else {
            statusMessage = "选区太短，无法添加效果。"
            return
        }
        isProcessing = true
        progress = 0
        statusMessage = nil
        self.processingTitle = processingTitle
        let sink = ProgressSink()
        progressSink = sink
        startProgressTimer(sink)
        Task { @MainActor in
            let updated = await Task.detached(priority: .userInitiated) {
                transform(channels, rate, applyRange) { sink.set($0) }
            }.value
            self.stopProgressTimer()
            self.session.replace(with: AudioSamples(sampleRate: rate, channels: updated))
            self.progress = 1
            self.isProcessing = false
            self.finishEdit(message: success)
        }
    }

    private func finishEdit(message: String?) {
        sync()
        peaks = WaveformPeaks.make(channels: session.samples.channels)
        waveformRevision += 1
        isDirty = true
        if let message {
            statusMessage = message
        }
    }

    private func sync() {
        selectionLower = session.selection.lowerBound
        selectionUpper = session.selection.upperBound
        playhead = session.playhead
        canUndo = session.canUndo
        canRedo = session.canRedo
        frameCount = session.samples.frameCount
        sampleRate = session.samples.sampleRate
    }

    private func startProgressTimer(_ sink: ProgressSink) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.progress = sink.get()
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        progressSink = nil
    }
}

final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func set(_ value: Double) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
