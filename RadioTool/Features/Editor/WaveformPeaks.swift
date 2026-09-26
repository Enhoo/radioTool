import Foundation

struct WaveformPeaks: Sendable {
    var mins: [Float]
    var maxs: [Float]
    var amplitude: Float

    static let empty = WaveformPeaks(mins: [], maxs: [], amplitude: 1)

    static func make(channels: [[Float]], bucketCount: Int = 2400) -> WaveformPeaks {
        guard let frameCount = channels.first?.count, frameCount > 0 else { return .empty }
        let buckets = min(max(bucketCount, 1), frameCount)
        var mins = [Float](repeating: 0, count: buckets)
        var maxs = [Float](repeating: 0, count: buckets)
        var amplitude: Float = 0.001
        for bucket in 0..<buckets {
            let start = bucket * frameCount / buckets
            let end = max(start + 1, (bucket + 1) * frameCount / buckets)
            var low: Float = .greatestFiniteMagnitude
            var high: Float = -.greatestFiniteMagnitude
            for channel in channels {
                for index in start..<end {
                    let sample = channel[index]
                    if sample < low { low = sample }
                    if sample > high { high = sample }
                }
            }
            mins[bucket] = low
            maxs[bucket] = high
            amplitude = max(amplitude, abs(low), abs(high))
        }
        return WaveformPeaks(mins: mins, maxs: maxs, amplitude: amplitude)
    }
}
