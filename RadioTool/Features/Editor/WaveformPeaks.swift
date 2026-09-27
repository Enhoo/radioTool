import Foundation

struct WaveformPeaks: Sendable {
    var mins: [Float]
    var maxs: [Float]
    var amplitude: Float

    static let empty = WaveformPeaks(mins: [], maxs: [], amplitude: 1)

    static func make(channels: [[Float]], bucketCount: Int = 2400) -> WaveformPeaks {
        guard let frameCount = channels.first?.count, frameCount > 0 else { return .empty }
        return make(channels: channels, range: 0..<frameCount, bucketCount: bucketCount, preservedAmplitude: 0)
    }

    /// Peaks for one slice. `preservedAmplitude` keeps the zoomed wave on the same scale as the whole clip.
    static func make(
        channels: [[Float]],
        range: Range<Int>,
        bucketCount: Int,
        preservedAmplitude: Float
    ) -> WaveformPeaks {
        let total = channels.first?.count ?? 0
        let lower = min(max(0, range.lowerBound), total)
        let upper = min(max(lower, range.upperBound), total)
        let frameCount = upper - lower
        guard frameCount > 0 else { return .empty }
        let buckets = min(max(bucketCount, 1), frameCount)
        var mins = [Float](repeating: 0, count: buckets)
        var maxs = [Float](repeating: 0, count: buckets)
        var amplitude = max(preservedAmplitude, 0.001)
        for bucket in 0..<buckets {
            let start = lower + bucket * frameCount / buckets
            let end = min(upper, lower + max(bucket * frameCount / buckets + 1, (bucket + 1) * frameCount / buckets))
            var low: Float = .greatestFiniteMagnitude
            var high: Float = -.greatestFiniteMagnitude
            for channel in channels where channel.count >= end {
                for index in start..<end {
                    let sample = channel[index]
                    if sample < low { low = sample }
                    if sample > high { high = sample }
                }
            }
            mins[bucket] = low == .greatestFiniteMagnitude ? 0 : low
            maxs[bucket] = high == -.greatestFiniteMagnitude ? 0 : high
            amplitude = max(amplitude, abs(mins[bucket]), abs(maxs[bucket]))
        }
        return WaveformPeaks(mins: mins, maxs: maxs, amplitude: amplitude)
    }
}
