import Foundation

/// Offline effects applied to whole clips or a selection.
///
/// Rumble adds a saturated low body tone that follows the existing low-mid envelope,
/// close to the solid vibration felt through a surface under bare feet.
/// Gain raises loudness in decibels and eases off near full scale.
enum AudioEffects {
    static func applyRumble(
        channels: [[Float]],
        sampleRate: Double,
        strength: Float,
        applyFrameRange: Range<Int>,
        progress: ((Double) -> Void)? = nil
    ) -> [[Float]] {
        let amount = min(max(strength, 0), 1)
        return apply(channels: channels, sampleRate: sampleRate, applyFrameRange: applyFrameRange, progress: progress) { slice in
            rumble(channel: slice, sampleRate: sampleRate, strength: amount)
        }
    }

    static func applyGain(
        channels: [[Float]],
        sampleRate: Double,
        decibels: Float,
        applyFrameRange: Range<Int>,
        progress: ((Double) -> Void)? = nil
    ) -> [[Float]] {
        let gain = min(max(decibels, 0), 12)
        return apply(channels: channels, sampleRate: sampleRate, applyFrameRange: applyFrameRange, progress: progress) { slice in
            amplify(channel: slice, decibels: gain)
        }
    }

    private static func apply(
        channels: [[Float]],
        sampleRate: Double,
        applyFrameRange: Range<Int>,
        progress: ((Double) -> Void)?,
        transform: ([Float]) -> [Float]
    ) -> [[Float]] {
        guard !channels.isEmpty else { return channels }
        let frameCount = channels[0].count
        let lower = min(max(0, applyFrameRange.lowerBound), frameCount)
        let upper = min(max(lower, applyFrameRange.upperBound), frameCount)
        let range = lower..<upper
        guard range.count > 1 else { return channels }

        var output = channels
        for index in channels.indices {
            let slice = Array(channels[index][range])
            let processed = transform(slice)
            output[index].replaceSubrange(range, with: crossfade(original: slice, processed: processed, sampleRate: sampleRate))
            progress?(Double(index + 1) / Double(channels.count))
        }
        return output
    }

    private static func rumble(channel: [Float], sampleRate: Double, strength: Float) -> [Float] {
        guard strength > 0, channel.count > 1, sampleRate > 8_000 else { return channel }
        var low = Biquad.lowpass(frequency: 200, q: 0.707, sampleRate: sampleRate)
        let attack = Float(exp(-1 / (sampleRate * 0.004)))
        let release = Float(exp(-1 / (sampleRate * 0.080)))
        let shape = tanh(Float(1.6))
        var envelope: Float = 0
        var phase = 0.0
        let step = 58.0 / sampleRate
        var body = [Float](repeating: 0, count: channel.count)

        for index in channel.indices {
            let level = abs(low.process(channel[index]))
            let coefficient = level > envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * level
            phase += step
            if phase >= 1 { phase -= 1 }
            let sine = Float(sin(2 * Double.pi * phase))
            body[index] = tanh(sine * 1.6) / shape * envelope
        }

        let dryPower = meanSquare(channel)
        let bodyPower = meanSquare(body)
        guard dryPower > 1e-12, bodyPower > 1e-12 else { return channel }
        let scale = sqrt(dryPower / bodyPower) * 0.85 * strength
        return zip(channel, body).map { dry, lowEnd in
            softLimit(dry + lowEnd * scale)
        }
    }

    private static func amplify(channel: [Float], decibels: Float) -> [Float] {
        guard decibels > 0 else { return channel }
        let linear = Float(pow(10, Double(decibels) / 20))
        return channel.map { softLimit($0 * linear) }
    }

    private static func softLimit(_ sample: Float) -> Float {
        let threshold: Float = 0.9
        let magnitude = abs(sample)
        guard magnitude > threshold else { return sample }
        let headroom: Float = 1 - threshold
        let limited = threshold + headroom * tanh((magnitude - threshold) / headroom)
        return copysign(min(limited, 0.999), sample)
    }

    private static func meanSquare(_ channel: [Float]) -> Float {
        var sum: Float = 0
        for sample in channel {
            sum += sample * sample
        }
        return sum / Float(max(channel.count, 1))
    }

    private static func crossfade(original: [Float], processed: [Float], sampleRate: Double) -> [Float] {
        let count = original.count
        guard count > 0 else { return processed }
        var mixed = processed
        if mixed.count < count {
            mixed.append(contentsOf: original[mixed.count..<count])
        } else if mixed.count > count {
            mixed = Array(mixed.prefix(count))
        }
        let fade = min(Int(sampleRate * 0.010), count / 4)
        guard fade > 1 else { return mixed }
        for index in 0..<fade {
            let ramp = Float(index) / Float(fade)
            mixed[index] = original[index] * (1 - ramp) + mixed[index] * ramp
            let tail = count - 1 - index
            mixed[tail] = original[tail] * (1 - ramp) + mixed[tail] * ramp
        }
        return mixed
    }
}

private struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    static func lowpass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let angular = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(angular)
        let sine = sin(angular)
        let alpha = sine / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float(((1 - cosine) / 2) / a0),
            b1: Float((1 - cosine) / a0),
            b2: Float(((1 - cosine) / 2) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha) / a0)
        )
    }
}
