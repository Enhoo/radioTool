import XCTest

final class SpectralDenoiserTests: XCTestCase {
    func testRoundTripErrorIsBelowMinus60dB() {
        let count = 48_000
        var input = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let time = Float(index) / 48_000
            input[index] = 0.4 * sin(2 * .pi * 440 * time) + 0.25 * sin(2 * .pi * 1_000 * time + 0.4)
        }
        let output = STFT.roundTrip(input)
        XCTAssertEqual(output.count, input.count)
        let decibels = errorDecibels(output, reference: input)
        XCTAssertLessThan(decibels, -60, "往返误差 \(decibels) dB")
    }

    func testDenoiseImprovesSignalToNoiseRatio() {
        let sampleRate = 48_000.0
        let noiseFrames = 48_000
        let total = noiseFrames + 48_000 * 2
        var generator = GaussianGenerator(seed: 42)
        var clean = [Float](repeating: 0, count: total)
        var noisy = [Float](repeating: 0, count: total)
        for index in 0..<total {
            let time = Float(index) / Float(sampleRate)
            let noise = generator.next() * 0.08
            let tone: Float = index >= noiseFrames ? 0.25 * sin(2 * .pi * 440 * time) : 0
            clean[index] = tone
            noisy[index] = tone + noise
        }

        let denoised = SpectralDenoiser.process(
            channel: noisy,
            sampleRate: sampleRate,
            strength: 1,
            noiseProfile: nil
        )
        XCTAssertEqual(denoised.count, noisy.count)
        let start = noiseFrames + STFT.fftSize
        let end = total - STFT.fftSize
        let inputRatio = signalToNoiseRatio(reference: clean, estimate: noisy, from: start, to: end)
        let outputRatio = signalToNoiseRatio(reference: clean, estimate: denoised, from: start, to: end)
        XCTAssertGreaterThan(outputRatio, inputRatio)
    }

    func testZeroStrengthReturnsTheOriginalSamples() {
        let input: [Float] = [0.1, -0.2, 0.3, -0.4]
        let output = SpectralDenoiser.process(channel: input, sampleRate: 48_000, strength: 0, noiseProfile: nil)
        XCTAssertEqual(output, input)
    }
}

final class EditSessionTests: XCTestCase {
    func testTrimAndDeleteChangeLengthAndCanUndo() {
        let channel = (0..<1_000).map { Float($0) }
        let samples = AudioSamples(sampleRate: 48_000, channels: [channel, channel])

        let trimmed = samples.trimming(to: 100..<250)
        XCTAssertEqual(trimmed.frameCount, 150)
        XCTAssertEqual(trimmed.channelCount, 2)
        XCTAssertEqual(trimmed.channels[0].first, 100)
        XCTAssertEqual(trimmed.channels[0].last, 249)
        XCTAssertEqual(trimmed.channels[1][0], 100)

        let deleted = samples.deleting(100..<250)
        XCTAssertEqual(deleted.frameCount, 850)
        XCTAssertEqual(deleted.channels[0][99], 99)
        XCTAssertEqual(deleted.channels[0][100], 250)

        let session = EditSession(samples: samples)
        session.setSelection(lower: 100, upper: 250)
        XCTAssertTrue(session.trimToSelection())
        XCTAssertEqual(session.samples.frameCount, 150)
        session.undo()
        XCTAssertEqual(session.samples.frameCount, 1_000)
        XCTAssertTrue(session.canRedo)

        session.setSelection(lower: 0, upper: 100)
        XCTAssertTrue(session.deleteSelection())
        XCTAssertEqual(session.samples.frameCount, 900)
        XCTAssertFalse(session.deleteSelection())
    }

    func testDeletingTheEntireBufferIsRejected() {
        let samples = AudioSamples(sampleRate: 1_000, channels: [[1, 2, 3, 4]])
        let session = EditSession(samples: samples)
        session.setSelection(lower: 0, upper: 4)
        XCTAssertFalse(session.deleteSelection())
        XCTAssertEqual(session.samples.frameCount, 4)
    }
}

final class AudioFileStoreTests: XCTestCase {
    func testWriteAndReadRoundTripWithinQuantization() throws {
        let count = 4_000
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let time = Float(index) / 48_000
            left[index] = 0.5 * sin(2 * .pi * 440 * time)
            right[index] = 0.25 * sin(2 * .pi * 660 * time)
        }
        let original = AudioSamples(sampleRate: 48_000, channels: [left, right])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("radio-tool-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioFileStore.write(original, to: url)
        let loaded = try AudioFileStore.read(url: url)
        XCTAssertEqual(loaded.channelCount, 2)
        XCTAssertEqual(loaded.frameCount, count)
        XCTAssertEqual(loaded.sampleRate, 48_000, accuracy: 0.1)
        let maxDifference = zip(loaded.channels[0], left).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDifference, 2.0 / 32_768.0 + 0.0001)
    }
}

private struct GaussianGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Float {
        let first = unit()
        let second = unit()
        let u1 = max(first, 1e-6)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * second)
    }

    private mutating func unit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return Float(state >> 40) / Float(1 << 24)
    }
}

private func errorDecibels(_ estimate: [Float], reference: [Float]) -> Float {
    var error: Float = 0
    var signal: Float = 0
    for index in 0..<min(estimate.count, reference.count) {
        let delta = estimate[index] - reference[index]
        error += delta * delta
        signal += reference[index] * reference[index]
    }
    guard signal > 0 else { return -160 }
    return 10 * log10(error / signal)
}

private func signalToNoiseRatio(reference: [Float], estimate: [Float], from start: Int, to end: Int) -> Float {
    var error: Float = 0
    var signal: Float = 0
    for index in start..<end {
        let delta = estimate[index] - reference[index]
        error += delta * delta
        signal += reference[index] * reference[index]
    }
    return 10 * log10(signal / max(error, 1e-12))
}
