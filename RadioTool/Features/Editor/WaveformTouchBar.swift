#if os(macOS)
import AppKit
import SwiftUI

struct WaveformTouchBarInstaller: NSViewRepresentable {
    var peaks: WaveformPeaks
    var frameCount: Int
    var playhead: Int
    var selectionLower: Int
    var selectionUpper: Int
    var isEnabled: Bool
    var onScrub: (Int) -> Void

    func makeNSView(context: Context) -> WaveformTouchBarAnchor {
        WaveformTouchBarAnchor()
    }

    func updateNSView(_ view: WaveformTouchBarAnchor, context: Context) {
        view.update(
            peaks: peaks,
            frameCount: frameCount,
            playhead: playhead,
            selectionLower: selectionLower,
            selectionUpper: selectionUpper,
            isEnabled: isEnabled,
            onScrub: onScrub
        )
    }
}

final class WaveformTouchBarAnchor: NSView, NSTouchBarDelegate {
    private let waveformView = WaveformTouchBarView(frame: NSRect(x: 0, y: 0, width: 640, height: 30))
    private var bar: NSTouchBar?
    private var item: NSCustomTouchBarItem?
    private weak var attachedWindow: NSWindow?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let attachedWindow, attachedWindow !== window, attachedWindow.touchBar === bar {
            attachedWindow.touchBar = nil
        }
        attachedWindow = window
        guard let window else { return }
        if bar == nil {
            let touchBar = NSTouchBar()
            touchBar.delegate = self
            touchBar.defaultItemIdentifiers = [.radioToolWaveform]
            touchBar.principalItemIdentifier = .radioToolWaveform
            bar = touchBar
        }
        window.touchBar = bar
    }

    func update(
        peaks: WaveformPeaks,
        frameCount: Int,
        playhead: Int,
        selectionLower: Int,
        selectionUpper: Int,
        isEnabled: Bool,
        onScrub: @escaping (Int) -> Void
    ) {
        waveformView.peaks = peaks
        waveformView.frameCount = frameCount
        waveformView.playhead = playhead
        waveformView.selectionLower = selectionLower
        waveformView.selectionUpper = selectionUpper
        waveformView.isEnabled = isEnabled
        waveformView.onScrub = onScrub
        waveformView.needsDisplay = true
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .radioToolWaveform else { return nil }
        if let item { return item }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = waveformView
        item.customizationLabel = "波形"
        self.item = item
        return item
    }
}

private extension NSTouchBarItem.Identifier {
    static let radioToolWaveform = NSTouchBarItem.Identifier("com.enhoo.radioTool.waveform")
}

final class WaveformTouchBarView: NSView {
    var peaks = WaveformPeaks.empty
    var frameCount = 0
    var playhead = 0
    var selectionLower = 0
    var selectionUpper = 0
    var isEnabled = true
    var onScrub: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.direct]
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 640, height: 30)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func touchesBegan(with event: NSEvent) {
        scrub(event)
    }

    override func touchesMoved(with event: NSEvent) {
        scrub(event)
    }

    override func touchesEnded(with event: NSEvent) {
        scrub(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)
        guard peaks.mins.count > 0, bounds.width > 1, bounds.height > 1 else { return }

        if frameCount > 0 {
            let start = xPosition(selectionLower, endInclusive: false)
            let end = xPosition(selectionUpper, endInclusive: true)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor)
            context.fill(CGRect(x: start, y: 0, width: max(end - start, 1), height: bounds.height))
        }

        let count = peaks.mins.count
        let mid = bounds.midY
        let scale = bounds.height * 0.45 / CGFloat(max(peaks.amplitude, 0.001))
        let columns = max(Int(bounds.width), 1)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.beginPath()
        for column in 0..<columns {
            let startBucket = column * count / columns
            let endBucket = min(count, max(startBucket + 1, (column + 1) * count / columns))
            var low = Float.greatestFiniteMagnitude
            var high = -Float.greatestFiniteMagnitude
            if startBucket < endBucket {
                for bucket in startBucket..<endBucket {
                    low = min(low, peaks.mins[bucket])
                    high = max(high, peaks.maxs[bucket])
                }
            }
            let x = CGFloat(column) + 0.5
            context.move(to: CGPoint(x: x, y: mid - CGFloat(high) * scale))
            context.addLine(to: CGPoint(x: x, y: mid - CGFloat(low) * scale))
        }
        context.strokePath()

        guard frameCount > 0 else { return }
        let playheadX = xPosition(playhead, endInclusive: false)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(2)
        context.beginPath()
        context.move(to: CGPoint(x: playheadX, y: 0))
        context.addLine(to: CGPoint(x: playheadX, y: bounds.height))
        context.strokePath()
    }

    private func scrub(_ event: NSEvent) {
        guard isEnabled, let touch = event.touches(for: self).first else { return }
        let frame = WaveformView.playheadFrame(at: touch.location(in: self).x, width: bounds.width, count: frameCount)
        onScrub?(frame)
    }

    private func xPosition(_ frame: Int, endInclusive: Bool) -> CGFloat {
        guard frameCount > 0 else { return 0 }
        let clamped = min(max(frame, 0), frameCount)
        if endInclusive && clamped == frameCount {
            return bounds.width
        }
        return CGFloat(min(clamped, max(frameCount - 1, 0))) / CGFloat(frameCount) * bounds.width
    }
}
#endif
