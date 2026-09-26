import AVFoundation
import Foundation
import Observation

@Observable
final class RecorderModel {
    var isRecording = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var permissionDenied = false
    var errorMessage: String?
    var didFinish = false

    private let store: LibraryStore
    private let engine = RecorderEngine()
    private var destination: URL?
    private var didStart = false
    private var smoothedLevel: Float = 0

    init(store: LibraryStore) {
        self.store = store
        engine.onLevel = { [weak self] peak, elapsed in
            guard let self else { return }
            self.smoothedLevel = max(peak, self.smoothedLevel * 0.85)
            self.level = self.smoothedLevel
            self.elapsed = elapsed
        }
    }

    func startIfNeeded() async {
        let shouldStart = await MainActor.run { () -> Bool in
            if didStart { return false }
            didStart = true
            return true
        }
        guard shouldStart else { return }
        let granted = await requestPermission()
        await MainActor.run {
            guard granted else {
                permissionDenied = true
                errorMessage = AudioToolError.permissionDenied.errorDescription
                return
            }
            let url = store.makeRecordingURL()
            destination = url
            do {
                try engine.start(url: url)
                isRecording = true
            } catch {
                errorMessage = error.localizedDescription
                try? FileManager.default.removeItem(at: url)
                destination = nil
            }
        }
    }

    func stopAndSave() {
        let frames = engine.stop()
        isRecording = false
        smoothedLevel = 0
        level = 0
        guard let destination else { return }
        if frames < 4_800 {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = "录音太短，没有保存。"
            self.destination = nil
            return
        }
        do {
            try store.addRecordedFile(at: destination, frameCount: frames)
            didFinish = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        engine.cancel()
        isRecording = false
        if let destination {
            try? FileManager.default.removeItem(at: destination)
        }
        destination = nil
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let current = AVAudioApplication.shared.recordPermission
                if current == .granted {
                    continuation.resume(returning: true)
                    return
                }
                if current == .denied {
                    continuation.resume(returning: false)
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
