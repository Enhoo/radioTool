import AVFoundation
import Foundation

enum AudioSession {
    static func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif
    }
}

enum AudioFileStore {
    static func read(url: URL) throws -> AudioSamples {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw AudioToolError.empty }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioToolError.unreadable
        }
        try file.read(into: buffer)
        return try samples(from: buffer, sampleRate: format.sampleRate)
    }

    static func write(_ samples: AudioSamples, to url: URL) throws {
        guard samples.channelCount > 0, samples.frameCount > 0 else { throw AudioToolError.empty }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: samples.sampleRate,
            AVNumberOfChannelsKey: samples.channelCount,
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
        let chunk = 16_384
        var offset = 0
        while offset < samples.frameCount {
            let frames = min(chunk, samples.frameCount - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let channelData = buffer.floatChannelData else {
                throw AudioToolError.unreadable
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<samples.channelCount {
                let destination = channelData[channel]
                samples.channels[channel].withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress!.advanced(by: offset), count: frames)
                }
            }
            try file.write(from: buffer)
            offset += frames
        }
    }

    private static func samples(from buffer: AVAudioPCMBuffer, sampleRate: Double) throws -> AudioSamples {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0, let channelData = buffer.floatChannelData else {
            throw AudioToolError.unreadable
        }
        var channels = Array(repeating: [Float](repeating: 0, count: frames), count: channelCount)
        if buffer.format.isInterleaved {
            let interleaved = channelData[0]
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    channels[channel][frame] = interleaved[frame * channelCount + channel]
                }
            }
        } else {
            for channel in 0..<channelCount {
                channels[channel].withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.update(from: channelData[channel], count: frames)
                }
            }
        }
        return AudioSamples(sampleRate: sampleRate, channels: channels)
    }
}
