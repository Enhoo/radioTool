import Accelerate
import Foundation

enum STFT {
    static let fftSize = 2048
    static let hopSize = 512
    static let binCount = fftSize / 2 + 1

    /// Gain of 1. Pads so the Hann window still overlaps the first and last samples.
    static func roundTrip(_ signal: [Float]) -> [Float] {
        RealFFTProcessor().render(signal: signal, pad: hopSize) { _, _, _ in }
    }
}

/// Packed real FFT. DC lives in `real[0]`, Nyquist in `imag[0]`.
final class RealFFTProcessor {
    let window: [Float]
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private var real: [Float]
    private var imag: [Float]
    private var time: [Float]

    init() {
        log2n = vDSP_Length(log2(Double(STFT.fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("无法创建 FFT")
        }
        self.setup = setup
        window = (0..<STFT.fftSize).map { index in
            0.5 * (1 - cos(2 * .pi * Float(index) / Float(STFT.fftSize)))
        }
        real = [Float](repeating: 0, count: STFT.fftSize / 2)
        imag = [Float](repeating: 0, count: STFT.fftSize / 2)
        time = [Float](repeating: 0, count: STFT.fftSize)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func render(
        signal: [Float],
        pad: Int,
        modify: (inout [Float], inout [Float], Int) -> Void
    ) -> [Float] {
        guard !signal.isEmpty else { return [] }
        let padded: [Float]
        if pad > 0 {
            padded = [Float](repeating: 0, count: pad) + signal + [Float](repeating: 0, count: pad)
        } else {
            padded = signal
        }

        var output = [Float](repeating: 0, count: padded.count + STFT.fftSize)
        var weight = [Float](repeating: 0, count: output.count)
        var start = 0
        var frameIndex = 0
        while start < padded.count {
            var frame = [Float](repeating: 0, count: STFT.fftSize)
            let available = min(STFT.fftSize, padded.count - start)
            for index in 0..<available {
                frame[index] = padded[start + index] * window[index]
            }
            forward(frame)
            modify(&real, &imag, frameIndex)
            inverse()
            for index in 0..<STFT.fftSize {
                let destination = start + index
                guard destination < output.count else { continue }
                output[destination] += time[index] * window[index]
                weight[destination] += window[index] * window[index]
            }
            start += STFT.hopSize
            frameIndex += 1
        }

        var result = [Float](repeating: 0, count: signal.count)
        for index in 0..<signal.count {
            let source = index + pad
            if source < weight.count, weight[source] > 1e-6 {
                result[index] = output[source] / weight[source]
            } else {
                result[index] = signal[index]
            }
        }
        return result
    }

    /// Power spectrum of length `STFT.binCount` for one windowed frame.
    func powerSpectrum(of frame: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: STFT.fftSize)
        let count = min(frame.count, STFT.fftSize)
        for index in 0..<count {
            windowed[index] = frame[index] * window[index]
        }
        forward(windowed)
        return currentPower()
    }

    func currentPower() -> [Float] {
        var power = [Float](repeating: 0, count: STFT.binCount)
        power[0] = real[0] * real[0]
        power[STFT.binCount - 1] = imag[0] * imag[0]
        for bin in 1..<STFT.fftSize / 2 {
            power[bin] = real[bin] * real[bin] + imag[bin] * imag[bin]
        }
        return power
    }

    private func forward(_ frame: [Float]) {
        frame.withUnsafeBufferPointer { input in
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: STFT.fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(STFT.fftSize / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
        }
    }

    private func inverse() {
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                time.withUnsafeMutableBufferPointer { timePointer in
                    timePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: STFT.fftSize / 2) { complex in
                        vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(STFT.fftSize / 2))
                    }
                }
            }
        }
        var scale = 1 / (2 * Float(STFT.fftSize))
        time.withUnsafeMutableBufferPointer { timePointer in
            vDSP_vsmul(timePointer.baseAddress!, 1, &scale, timePointer.baseAddress!, 1, vDSP_Length(STFT.fftSize))
        }
    }
}
