import AVFoundation
import Foundation

final class PlayerEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: Timer?
    private var playToken = 0
    private var originFrame = 0
    private var totalFrames = 0
    private(set) var isPlaying = false
    var onFrame: ((Int) -> Void)?
    var onFinish: (() -> Void)?

    init() {
        engine.attach(player)
    }

    func play(samples: AudioSamples, from frame: Int) throws {
        stop()
        guard samples.frameCount > 0, samples.channelCount > 0 else { return }
        let start = min(max(0, frame), samples.frameCount - 1)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: samples.sampleRate,
            channels: AVAudioChannelCount(samples.channelCount),
            interleaved: false
        ), let buffer = Self.buffer(samples: samples, from: start, format: format) else {
            throw AudioToolError.unreadable
        }
        try AudioSession.activate()
        if engine.isRunning {
            engine.stop()
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        playToken += 1
        let token = playToken
        originFrame = start
        totalFrames = samples.frameCount
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playToken == token else { return }
                self.finish(at: self.totalFrames > 0 ? self.totalFrames - 1 : 0)
            }
        }
        player.play()
        isPlaying = true
        startTimer(token: token)
    }

    func pause() {
        guard isPlaying else { return }
        captureFrame()
        player.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        playToken += 1
        timer?.invalidate()
        timer = nil
        if player.isPlaying {
            player.stop()
        }
        isPlaying = false
    }

    private func finish(at frame: Int) {
        timer?.invalidate()
        timer = nil
        isPlaying = false
        onFrame?(frame)
        onFinish?()
    }

    private func startTimer(token: Int) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.playToken == token, self.isPlaying else { return }
            self.captureFrame()
        }
    }

    private func captureFrame() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
        let frame = originFrame + Int(playerTime.sampleTime)
        let clamped = min(max(originFrame, frame), max(originFrame, totalFrames - 1))
        onFrame?(clamped)
    }

    private static func buffer(samples: AudioSamples, from frame: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = samples.frameCount - frame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<samples.channelCount {
            samples.channels[channel].withUnsafeBufferPointer { source in
                channelData[channel].update(from: source.baseAddress!.advanced(by: frame), count: frames)
            }
        }
        return buffer
    }
}
