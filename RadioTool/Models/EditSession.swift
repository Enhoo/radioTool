import Foundation

/// In-memory edit stack. Trim and delete rewrite sample ranges; denoise replaces samples.
final class EditSession {
    struct Snapshot {
        var samples: AudioSamples
        var selection: Range<Int>
        var playhead: Int
    }

    private(set) var samples: AudioSamples
    private(set) var selection: Range<Int>
    private(set) var playhead: Int
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let undoLimit = 8

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(samples: AudioSamples) {
        self.samples = samples
        self.selection = 0..<samples.frameCount
        self.playhead = 0
    }

    func setPlayhead(_ frame: Int) {
        guard samples.frameCount > 0 else {
            playhead = 0
            return
        }
        playhead = min(max(0, frame), samples.frameCount - 1)
    }

    func setSelection(lower: Int, upper: Int) {
        let count = samples.frameCount
        guard count > 0 else {
            selection = 0..<0
            return
        }
        let lo = min(max(0, lower), count - 1)
        var hi = min(max(0, upper), count)
        if hi <= lo {
            hi = min(count, lo + 1)
        }
        selection = lo..<hi
    }

    @discardableResult
    func trimToSelection() -> Bool {
        guard selection.count > 0, selection.count < samples.frameCount else { return false }
        pushUndo()
        samples = samples.trimming(to: selection)
        selection = 0..<samples.frameCount
        playhead = 0
        return true
    }

    @discardableResult
    func deleteSelection() -> Bool {
        guard selection.count > 0, selection.count < samples.frameCount else { return false }
        pushUndo()
        let join = selection.lowerBound
        samples = samples.deleting(selection)
        selection = 0..<samples.frameCount
        setPlayhead(join)
        return true
    }

    func replace(with samples: AudioSamples) {
        pushUndo()
        self.samples = samples
        if selection.upperBound > samples.frameCount || selection.lowerBound > samples.frameCount {
            selection = 0..<samples.frameCount
        }
        setPlayhead(playhead)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(capture())
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(capture())
        restore(snapshot)
    }

    private func pushUndo() {
        undoStack.append(capture())
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll()
    }

    private func capture() -> Snapshot {
        Snapshot(samples: samples, selection: selection, playhead: playhead)
    }

    private func restore(_ snapshot: Snapshot) {
        samples = snapshot.samples
        selection = snapshot.selection
        playhead = snapshot.playhead
    }
}
