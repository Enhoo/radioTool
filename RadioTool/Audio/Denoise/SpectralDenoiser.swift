import Foundation

/// Offline additive-noise reduction.
///
/// Noise power is the minimum of about one-second block-averaged spectra.
/// A Wiener gain `G = ξ / (ξ + 1)` is applied to the magnitude; the noisy phase is kept.
/// `strength` is 0...1. Zero returns the input unchanged. Over-subtraction is `1 + strength`.
enum SpectralDenoiser {
    static func process(
        channel: [Float],
        sampleRate: Double,
        strength: Float,
        noiseProfile: [Float]?,
        progress: ((Double) -> Void)? = nil
    ) -> [Float] {
        let amount = min(max(strength, 0), 1)
        guard amount > 0, channel.count > 1 else { return channel }

        let fft = RealFFTProcessor()
        let profile: [Float]
        if let noiseProfile, noiseProfile.count == STFT.binCount {
            profile = noiseProfile
            progress?(0.45)
        } else {
            profile = minimumStatistics(channel: channel, sampleRate: sampleRate, fft: fft) { fraction in
                progress?(fraction * 0.45)
            }
        }
        return applyWiener(
            channel: channel,
            strength: amount,
            noisePSD: profile,
            fft: fft
        ) { fraction in
            progress?(0.45 + fraction * 0.55)
        }
    }

    static func processChannels(
        channels: [[Float]],
        sampleRate: Double,
        strength: Float,
        noiseFrameRange: Range<Int>?,
        applyFrameRange: Range<Int>,
        progress: ((Double) -> Void)? = nil
    ) -> [[Float]] {
        guard !channels.isEmpty else { return channels }
        let frameCount = channels[0].count
        let lower = min(max(0, applyFrameRange.lowerBound), frameCount)
        let upper = min(max(lower, applyFrameRange.upperBound), frameCount)
        let applyRange = lower..<upper
        guard applyRange.count > 1 else { return channels }

        var output = channels
        for index in channels.indices {
            let channel = channels[index]
            let profile = noiseProfile(channel: channel, range: noiseFrameRange)
            let slice = Array(channel[applyRange])
            let denoised = process(
                channel: slice,
                sampleRate: sampleRate,
                strength: strength,
                noiseProfile: profile
            ) { fraction in
                let overall = (Double(index) + fraction) / Double(channels.count)
                progress?(overall)
            }
            output[index].replaceSubrange(applyRange, with: crossfade(original: slice, denoised: denoised, sampleRate: sampleRate))
        }
        progress?(1)
        return output
    }

    static func averagePower(channel: [Float]) -> [Float] {
        let fft = RealFFTProcessor()
        var sum = [Float](repeating: 0, count: STFT.binCount)
        var frames = 0
        var start = 0
        while start < channel.count {
            let end = min(channel.count, start + STFT.fftSize)
            let frame = Array(channel[start..<end])
            let power = fft.powerSpectrum(of: frame)
            for bin in 0..<STFT.binCount {
                sum[bin] += power[bin]
            }
            frames += 1
            start += STFT.hopSize
        }
        guard frames > 0 else { return sum }
        let scale = 1 / Float(frames)
        return sum.map { $0 * scale }
    }

    private static func noiseProfile(channel: [Float], range: Range<Int>?) -> [Float]? {
        guard let range else { return nil }
        let lower = min(max(0, range.lowerBound), channel.count)
        let upper = min(max(lower, range.upperBound), channel.count)
        guard upper - lower > 1 else { return nil }
        return averagePower(channel: Array(channel[lower..<upper]))
    }

    /// Minimum across one-second block averages. A quiet second keeps the noise floor
    /// from following speech or other signals that are not always present.
    private static func minimumStatistics(
        channel: [Float],
        sampleRate: Double,
        fft: RealFFTProcessor,
        progress: (Double) -> Void
    ) -> [Float] {
        let framesPerBlock = max(1, Int(sampleRate / Double(STFT.hopSize)))
        var blockAverages: [[Float]] = []
        var accumulator = [Float](repeating: 0, count: STFT.binCount)
        var count = 0
        var start = 0
        var scanned = 0
        let estimatedFrames = max(1, (channel.count + STFT.hopSize - 1) / STFT.hopSize)
        while start < channel.count {
            let end = min(channel.count, start + STFT.fftSize)
            let power = fft.powerSpectrum(of: Array(channel[start..<end]))
            for bin in 0..<STFT.binCount {
                accumulator[bin] += power[bin]
            }
            count += 1
            scanned += 1
            if count == framesPerBlock {
                blockAverages.append(accumulator.map { $0 / Float(count) })
                accumulator = [Float](repeating: 0, count: STFT.binCount)
                count = 0
            }
            if scanned % 32 == 0 {
                progress(Double(scanned) / Double(estimatedFrames))
            }
            start += STFT.hopSize
        }
        if count > 0 {
            blockAverages.append(accumulator.map { $0 / Float(count) })
        }
        guard var noise = blockAverages.first else {
            return [Float](repeating: 1e-8, count: STFT.binCount)
        }
        for block in blockAverages.dropFirst() {
            for bin in 0..<STFT.binCount {
                noise[bin] = min(noise[bin], block[bin])
            }
        }
        return noise
    }

    private static func applyWiener(
        channel: [Float],
        strength: Float,
        noisePSD: [Float],
        fft: RealFFTProcessor,
        progress: (Double) -> Void
    ) -> [Float] {
        let oversubtraction = 1 + strength
        let gainFloor = pow(10, -1.5 * strength)
        let decisionDirected: Float = 0.98
        var previousGain = [Float](repeating: 1, count: STFT.binCount)
        var previousGamma = [Float](repeating: 1, count: STFT.binCount)
        let estimatedFrames = max(1, (channel.count + STFT.hopSize - 1) / STFT.hopSize)
        var frameIndex = 0

        return fft.render(signal: channel, pad: 0) { real, imag, _ in
            var power = [Float](repeating: 0, count: STFT.binCount)
            power[0] = real[0] * real[0]
            power[STFT.binCount - 1] = imag[0] * imag[0]
            for bin in 1..<STFT.fftSize / 2 {
                power[bin] = real[bin] * real[bin] + imag[bin] * imag[bin]
            }

            var gain = [Float](repeating: 1, count: STFT.binCount)
            for bin in 0..<STFT.binCount {
                let noise = max(oversubtraction * noisePSD[bin], 1e-12)
                let gamma = power[bin] / noise
                let prior = decisionDirected * previousGain[bin] * previousGain[bin] * previousGamma[bin]
                    + (1 - decisionDirected) * max(gamma - 1, 0)
                gain[bin] = max(prior / (1 + prior), gainFloor)
                previousGamma[bin] = gamma
            }
            var smoothed = gain
            if STFT.binCount > 2 {
                for bin in 1..<(STFT.binCount - 1) {
                    smoothed[bin] = (gain[bin - 1] + gain[bin] + gain[bin + 1]) / 3
                }
            }
            previousGain = smoothed

            real[0] *= smoothed[0]
            imag[0] *= smoothed[STFT.binCount - 1]
            for bin in 1..<STFT.fftSize / 2 {
                real[bin] *= smoothed[bin]
                imag[bin] *= smoothed[bin]
            }

            frameIndex += 1
            if frameIndex % 32 == 0 {
                progress(Double(frameIndex) / Double(estimatedFrames))
            }
        }
    }

    private static func crossfade(original: [Float], denoised: [Float], sampleRate: Double) -> [Float] {
        let count = min(original.count, denoised.count)
        guard count > 0 else { return denoised }
        var mixed = denoised
        if mixed.count != count {
            mixed = Array(denoised.prefix(count))
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
