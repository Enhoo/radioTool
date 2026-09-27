import Foundation

struct AudioSamples: Equatable, Sendable {
    var sampleRate: Double
    var channels: [[Float]]

    var channelCount: Int { channels.count }
    var frameCount: Int { channels.first?.count ?? 0 }
    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    func trimming(to range: Range<Int>) -> AudioSamples {
        let clamped = clamp(range)
        return AudioSamples(
            sampleRate: sampleRate,
            channels: channels.map { Array($0[clamped]) }
        )
    }

    func inserting(_ clip: AudioSamples, at frame: Int) -> AudioSamples {
        let index = min(max(0, frame), frameCount)
        var updated = channels
        for channelIndex in updated.indices {
            let incoming = channelIndex < clip.channels.count ? clip.channels[channelIndex] : []
            updated[channelIndex].insert(contentsOf: incoming, at: index)
        }
        return AudioSamples(sampleRate: sampleRate, channels: updated)
    }

    func deleting(_ range: Range<Int>) -> AudioSamples {
        let clamped = clamp(range)
        return AudioSamples(
            sampleRate: sampleRate,
            channels: channels.map { channel in
                var copy = channel
                copy.removeSubrange(clamped)
                return copy
            }
        )
    }

    func replacing(range: Range<Int>, with replacement: [[Float]]) -> AudioSamples {
        let clamped = clamp(range)
        var updated = channels
        for index in updated.indices {
            let channelReplacement = index < replacement.count ? replacement[index] : []
            updated[index].replaceSubrange(clamped, with: channelReplacement)
        }
        return AudioSamples(sampleRate: sampleRate, channels: updated)
    }

    private func clamp(_ range: Range<Int>) -> Range<Int> {
        let lower = min(max(0, range.lowerBound), frameCount)
        let upper = min(max(lower, range.upperBound), frameCount)
        return lower..<upper
    }
}
