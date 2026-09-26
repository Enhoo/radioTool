import AVFoundation
import Foundation

final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let file: AVAudioFile
    private let targetFormat: AVAudioFormat
    private var closed = false
    private var storedFrames = 0
    private var storedLevel: Float = 0

    var framesWritten: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return storedLevel
    }

    init(file: AVAudioFile, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        self.file = file
        self.converter = converter
        self.targetFormat = targetFormat
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(outputCapacity, 1)) else {
            lock.unlock()
            return
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if output.frameLength > 0, error == nil {
            try? file.write(from: output)
            storedFrames += Int(output.frameLength)
        }
        storedLevel = Self.peak(of: buffer)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        if buffer.format.isInterleaved {
            let count = frames * channels
            for index in 0..<count {
                peak = max(peak, abs(channelData[0][index]))
            }
        } else {
            for channel in 0..<channels {
                for index in 0..<frames {
                    peak = max(peak, abs(channelData[channel][index]))
                }
            }
        }
        return min(peak, 1)
    }
}

final class RecorderEngine {
    private let engine = AVAudioEngine()
    private var writer: RecordingWriter?
    private var timer: Timer?
    var onLevel: ((Float, TimeInterval) -> Void)?

    func start(url: URL) throws {
        try AudioSession.activate()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioToolError.microphoneUnavailable
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioToolError.microphoneUnavailable
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let writer = RecordingWriter(file: file, converter: converter, targetFormat: targetFormat)
        self.writer = writer
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            writer.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer.close()
            self.writer = nil
            throw error
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    func stop() -> Int {
        teardown()
        return writer?.framesWritten ?? 0
    }

    func cancel() {
        teardown()
    }

    private func publish() {
        guard let writer else { return }
        let level = max(writer.level, 0)
        let elapsed = Double(writer.framesWritten) / 48_000
        onLevel?(level, elapsed)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
    }
}
