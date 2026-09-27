import AVFoundation
import Foundation

final class PlayerEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var timer: Timer?
    private var playToken = 0
    private var originFrame = 0
    private var totalFrames = 0
    private var sampleRate = 48_000.0
    private(set) var isPlaying = false
    var onFrame: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var rate: Float = 1 {
        didSet {
            timePitch.rate = min(max(rate, 0.5), 3)
        }
    }

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.rate = 1
    }

    func play(samples: AudioSamples, from frame: Int) throws {
        stop()
        guard samples.frameCount > 0, samples.channelCount > 0 else { return }
        let requested = min(max(0, frame), samples.frameCount - 1)
        let start = samples.frameCount - requested <= 1 ? 0 : requested
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
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = min(max(rate, 0.5), 3)
        engine.prepare()
        try engine.start()
        playToken += 1
        let token = playToken
        originFrame = start
        totalFrames = samples.frameCount
        sampleRate = samples.sampleRate
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playToken == token else { return }
                self.finish()
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
        player.stop()
        isPlaying = false
    }

    private func finish() {
        let restart = originFrame
        playToken += 1
        timer?.invalidate()
        timer = nil
        player.stop()
        isPlaying = false
        onFrame?(restart)
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
        let rendered = originFrame + Int(playerTime.sampleTime)
        let pending = Int((timePitch.latency * sampleRate * Double(timePitch.rate)).rounded())
        let frame = rendered - pending
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
