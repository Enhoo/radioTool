import SwiftUI

#if os(macOS)
import AppKit
#endif

struct WaveformView: View {
    let peaks: WaveformPeaks
    var channels: [[Float]]
    var revision: Int
    let frameCount: Int
    var sampleRate: Double
    var playhead: Int
    var isPlaying: Bool
    var selectionLower: Int
    var selectionUpper: Int
    var onScrub: (Int) -> Void
    var onSelection: (_ lower: Int, _ upper: Int) -> Void

    @State private var zoom: CGFloat = 1
    @State private var startFrame: CGFloat = 0
    @State private var pinching = false
    @State private var pinchZoom: CGFloat = 1
    @State private var pinchFrame: CGFloat = 0
    @State private var pinchX: CGFloat = 0
    @State private var panning = false
    @State private var panOrigin: CGFloat = 0
    @State private var scrolling = false
    @State private var scrollOrigin: CGFloat = 0
    @State private var followPlayhead = true
    @State private var viewportWidth: CGFloat = 1
    @State private var detail: WaveformPeaks?
    @State private var detailRange: Range<Int> = 0..<0
    @State private var detailWait: Task<Void, Never>?

    private let rulerHeight: CGFloat = 28
    private let waveHeight: CGFloat = 180
    private let scrollRowHeight: CGFloat = 34

    private var showsScrollbar: Bool { zoom > 1.01 && frameCount > 1 }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                waveStack(width: width)
                    .onAppear { viewportWidth = width }
                    .onChange(of: width) { _, newWidth in
                        viewportWidth = newWidth
                        clampWindow(width: newWidth)
                    }
            }
            .frame(height: waveHeight + rulerHeight)
            if showsScrollbar {
                scrollRow
            }
        }
        .frame(height: waveHeight + rulerHeight + (showsScrollbar ? scrollRowHeight : 0))
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: playhead) { _, frame in
            reveal(frame: frame, width: viewportWidth)
        }
        .onChange(of: isPlaying) { _, playing in
            guard playing else { return }
            followPlayhead = true
            reveal(frame: playhead, width: viewportWidth)
        }
        .onChange(of: frameCount) { _, _ in
            clampWindow(width: viewportWidth)
            scheduleDetail(width: viewportWidth)
        }
        .onChange(of: revision) { _, _ in
            detail = nil
            detailRange = 0..<0
            scheduleDetail(width: viewportWidth)
        }
        .onChange(of: startFrame) { _, _ in
            scheduleDetail(width: viewportWidth)
        }
        .onChange(of: zoom) { _, _ in
            scheduleDetail(width: viewportWidth)
        }
        .onDisappear {
            detailWait?.cancel()
        }
    }

    private func waveStack(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let wave = CGRect(x: 0, y: 0, width: size.width, height: waveHeight)
                context.drawLayer { layer in
                    layer.clip(to: Path(wave))
                    drawWave(context: layer, width: size.width)
                    drawSelection(context: layer, width: size.width)
                    drawPlayhead(context: layer, width: size.width)
                }
                drawRuler(context: context, width: size.width)
            }
            .contentShape(Rectangle())
            .gesture(waveDrag(width: width))
            rulerPan(width: width)
            selectionHandles(width: width)
        }
        .coordinateSpace(name: "wave")
        .simultaneousGesture(pinch(width: width))
        .background {
            #if os(macOS)
            WaveformScrollMonitor { delta in
                guard showsScrollbar else { return false }
                let framesPerPoint = visibleFrames(width: width) / width
                startFrame -= delta * framesPerPoint
                clampWindow(width: width)
                noteUserScroll(width: width)
                return true
            }
            #endif
        }
    }

    private func waveDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
            .onChanged { value in
                guard value.startLocation.y < waveHeight, abs(value.translation.width) >= 6 else { return }
                let start = frame(at: value.startLocation.x, width: width)
                let end = frame(at: value.location.x, width: width)
                onSelection(min(start, end), max(start, end) + 1)
            }
            .onEnded { value in
                guard value.startLocation.y < waveHeight, abs(value.translation.width) < 6 else { return }
                onScrub(Self.playheadFrame(
                    at: value.location.x,
                    width: width,
                    count: frameCount,
                    start: startFrame,
                    visible: visibleFrames(width: width)
                ))
            }
    }

    @ViewBuilder
    private func selectionHandles(width: CGFloat) -> some View {
        if selectionUpper > selectionLower {
            let lowerX = xPosition(CGFloat(selectionLower), width: width)
            let upperX = xPosition(CGFloat(selectionUpper), width: width, endInclusive: selectionUpper >= frameCount)
            if lowerX >= -20 && lowerX <= width + 20 {
                handle(edge: .lower, x: lowerX, width: width)
            }
            if upperX >= -20 && upperX <= width + 20 {
                handle(edge: .upper, x: upperX, width: width)
            }
        }
    }

    private var scrollRow: some View {
        HStack(spacing: 8) {
            scrollbar
            Button("全部") {
                resetZoom()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(height: scrollRowHeight)
    }

    private var scrollbar: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let visible = visibleFrames(width: viewportWidth)
            let thumbWidth = min(width, max(36, width * visible / CGFloat(max(frameCount, 1))))
            let maxStart = max(0, CGFloat(frameCount) - visible)
            let travel = max(width - thumbWidth, 1)
            let thumbX = maxStart > 0 ? travel * (startFrame / maxStart) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .gesture(trackJump(width: width, visible: visible))
                if selectionUpper > selectionLower, frameCount > 0 {
                    let start = width * CGFloat(selectionLower) / CGFloat(frameCount)
                    let end = width * CGFloat(min(selectionUpper, frameCount)) / CGFloat(frameCount)
                    Capsule()
                        .fill(Color(red: 1, green: 0.86, blue: 0.35).opacity(0.85))
                        .frame(width: max(end - start, 3))
                        .offset(x: start)
                        .allowsHitTesting(false)
                }
                Capsule()
                    .fill(Color.primary.opacity(0.38))
                    .frame(width: thumbWidth)
                    .offset(x: min(max(0, thumbX), max(0, width - thumbWidth)))
                    .highPriorityGesture(thumbDrag(maxStart: maxStart, travel: travel))
                if frameCount > 0 {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 14)
                        .offset(x: min(max(0, width * CGFloat(playhead) / CGFloat(frameCount) - 1), width - 2))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
        }
        .frame(height: 14)
    }

    private func thumbDrag(maxStart: CGFloat, travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard maxStart > 0 else { return }
                if !scrolling {
                    scrolling = true
                    scrollOrigin = startFrame
                }
                startFrame = scrollOrigin + value.translation.width / travel * maxStart
                clampWindow(width: viewportWidth)
                noteUserScroll(width: viewportWidth)
            }
            .onEnded { _ in
                scrolling = false
                scheduleDetail(width: viewportWidth)
            }
    }

    private func trackJump(width: CGFloat, visible: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard abs(value.translation.width) < 4, frameCount > 0 else { return }
                let fraction = min(max(0, value.location.x / width), 1)
                startFrame = fraction * CGFloat(frameCount) - visible / 2
                clampWindow(width: viewportWidth)
                noteUserScroll(width: viewportWidth)
                scheduleDetail(width: viewportWidth)
            }
    }

    private func pinch(width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !pinching {
                    pinching = true
                    pinchZoom = zoom
                    pinchX = min(max(0, value.startLocation.x), width)
                    pinchFrame = startFrame + (pinchX / width) * visibleFrames(width: width)
                }
                let proposed = pinchZoom * value.magnification
                zoom = min(max(proposed, 1), maximumZoom(width: width))
                let visible = visibleFrames(width: width)
                startFrame = pinchFrame - (pinchX / width) * visible
                clampWindow(width: width)
            }
            .onEnded { _ in
                pinching = false
            }
    }

    private func rulerPan(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: rulerHeight)
            .contentShape(Rectangle())
            .offset(y: waveHeight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("wave"))
                    .onChanged { value in
                        guard zoom > 1 else { return }
                        if !panning {
                            panning = true
                            panOrigin = startFrame
                        }
                        let framesPerPoint = visibleFrames(width: width) / width
                        startFrame = panOrigin - value.translation.width * framesPerPoint
                        clampWindow(width: width)
                        noteUserScroll(width: width)
                    }
                    .onEnded { _ in
                        panning = false
                    }
            )
    }

    private enum Edge {
        case lower
        case upper
    }

    private func drawWave(context: GraphicsContext, width: CGFloat) {
        let visibleStart = Int(startFrame.rounded(.down))
        let visibleEnd = min(frameCount, Int((startFrame + visibleFrames(width: width)).rounded(.up)))
        if let detail,
           detail.mins.count > 0,
           detailRange.lowerBound <= visibleStart,
           detailRange.upperBound >= visibleEnd {
            drawBuckets(detail, range: detailRange, context: context, width: width)
            return
        }
        drawBuckets(peaks, range: 0..<frameCount, context: context, width: width)
    }

    private func drawBuckets(_ source: WaveformPeaks, range: Range<Int>, context: GraphicsContext, width: CGFloat) {
        let count = source.mins.count
        guard count > 0, range.count > 0 else { return }
        let mid = waveHeight / 2
        let scale = mid / CGFloat(max(source.amplitude, 0.001))
        let visible = visibleFrames(width: width)
        let rangeStart = CGFloat(range.lowerBound)
        let rangeSpan = CGFloat(range.count)
        let first = max(0, Int(((startFrame - rangeStart) / rangeSpan) * CGFloat(count)) - 1)
        let last = min(count, Int(((startFrame + visible - rangeStart) / rangeSpan) * CGFloat(count)) + 2)
        guard last > first else { return }
        var path = Path()
        for index in first..<last {
            let frame = rangeStart + CGFloat(index) / CGFloat(count) * rangeSpan
            let x = xPosition(frame, width: width)
            let high = mid - CGFloat(source.maxs[index]) * scale
            let low = mid - CGFloat(source.mins[index]) * scale
            path.move(to: CGPoint(x: x, y: high))
            path.addLine(to: CGPoint(x: x, y: low))
        }
        let step = width / CGFloat(max(last - first, 1))
        context.stroke(path, with: .color(.accentColor), lineWidth: max(min(step * 0.8, 3), 1))
    }

    private func drawSelection(context: GraphicsContext, width: CGFloat) {
        guard frameCount > 0, selectionUpper > selectionLower else { return }
        let start = xPosition(CGFloat(selectionLower), width: width)
        let end = xPosition(CGFloat(selectionUpper), width: width, endInclusive: selectionUpper >= frameCount)
        let rect = CGRect(x: start, y: 0, width: max(end - start, 1), height: waveHeight)
        context.fill(Path(rect), with: .color(Color(red: 1, green: 0.86, blue: 0.35).opacity(0.42)))
        let edge = Color(red: 0.92, green: 0.72, blue: 0.12)
        var marks = Path()
        marks.move(to: CGPoint(x: start, y: 0))
        marks.addLine(to: CGPoint(x: start, y: waveHeight))
        marks.move(to: CGPoint(x: end, y: 0))
        marks.addLine(to: CGPoint(x: end, y: waveHeight))
        context.stroke(marks, with: .color(edge), lineWidth: 4)
    }

    private func drawPlayhead(context: GraphicsContext, width: CGFloat) {
        guard frameCount > 0 else { return }
        let x = xPosition(CGFloat(playhead), width: width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: waveHeight))
        context.stroke(line, with: .color(.red), lineWidth: 1.5)
    }

    private func drawRuler(context: GraphicsContext, width: CGFloat) {
        guard frameCount > 0, sampleRate > 0 else { return }
        let top = waveHeight
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: top))
        baseline.addLine(to: CGPoint(x: width, y: top))
        context.stroke(baseline, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

        let visibleSeconds = Double(visibleFrames(width: width)) / sampleRate
        let interval = tickInterval(visibleSeconds: visibleSeconds, width: width)
        let startTime = Double(startFrame) / sampleRate
        let endTime = startTime + visibleSeconds
        var tick = ceil(startTime / interval) * interval
        if tick < startTime { tick += interval }
        while tick <= endTime + interval * 0.001 {
            let frame = tick * sampleRate
            let x = xPosition(frame, width: width)
            guard x >= -1, x <= width + 1 else {
                tick += interval
                continue
            }
            var mark = Path()
            mark.move(to: CGPoint(x: x, y: top))
            mark.addLine(to: CGPoint(x: x, y: top + 8))
            context.stroke(mark, with: .color(.secondary), lineWidth: 1)
            let label = Text(TimeFormat.clock(tick, tenths: interval < 1))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            let anchor: UnitPoint = x < 28 ? .topLeading : (x > width - 28 ? .topTrailing : .top)
            context.draw(label, at: CGPoint(x: x, y: top + 9), anchor: anchor)
            tick += interval
        }
    }

    private func handle(edge: Edge, x: CGFloat, width: CGFloat) -> some View {
        Color.clear
            .frame(width: 28, height: waveHeight)
            .contentShape(Rectangle())
            .offset(x: x - 14)
            .selectionEdgeCursor()
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                    .onChanged { value in
                        #if os(macOS)
                        NSCursor.resizeLeftRight.set()
                        #endif
                        let bound = Self.bound(
                            at: value.location.x,
                            width: width,
                            count: frameCount,
                            start: startFrame,
                            visible: visibleFrames(width: width)
                        )
                        switch edge {
                        case .lower:
                            let lower = min(bound, max(selectionUpper - 1, 0))
                            onSelection(lower, selectionUpper)
                        case .upper:
                            let upper = max(bound, selectionLower + 1)
                            onSelection(selectionLower, upper)
                        }
                    }
            )
    }

    private func xPosition(_ frame: CGFloat, width: CGFloat, endInclusive: Bool = false) -> CGFloat {
        let visible = visibleFrames(width: width)
        guard visible > 0 else { return 0 }
        var value = frame
        if endInclusive && Int(frame.rounded()) >= frameCount {
            value = CGFloat(frameCount)
        }
        return (value - startFrame) / visible * width
    }

    private func frame(at x: CGFloat, width: CGFloat) -> Int {
        Self.playheadFrame(at: x, width: width, count: frameCount, start: startFrame, visible: visibleFrames(width: width))
    }

    private func visibleFrames(width: CGFloat) -> CGFloat {
        guard frameCount > 0 else { return 1 }
        return max(1, CGFloat(frameCount) / zoom)
    }

    private func maximumZoom(width: CGFloat) -> CGFloat {
        guard frameCount > 1, width > 1 else { return 1 }
        return max(1, CGFloat(frameCount) / width)
    }

    private func clampWindow(width: CGFloat) {
        let visible = visibleFrames(width: width)
        if zoom <= 1 || visible >= CGFloat(frameCount) {
            zoom = 1
            startFrame = 0
            followPlayhead = true
            return
        }
        let maxStart = max(0, CGFloat(frameCount) - visible)
        startFrame = min(max(0, startFrame), maxStart)
    }

    private func resetZoom() {
        zoom = 1
        startFrame = 0
        followPlayhead = true
        detail = nil
        detailRange = 0..<0
        detailWait?.cancel()
    }

    private func noteUserScroll(width: CGFloat) {
        let visible = visibleFrames(width: width)
        let position = CGFloat(playhead)
        followPlayhead = position >= startFrame && position <= startFrame + visible
    }

    private func reveal(frame: Int, width: CGFloat) {
        guard followPlayhead, zoom > 1, frameCount > 0 else { return }
        let visible = visibleFrames(width: width)
        let position = CGFloat(frame)
        if position < startFrame || position > startFrame + visible {
            startFrame = position - visible * 0.35
            clampWindow(width: width)
        }
    }

    private func scheduleDetail(width: CGFloat) {
        detailWait?.cancel()
        let pixelCount = max(32, Int(width))
        detailWait = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            let start = max(0, Int(startFrame.rounded(.down)))
            let visible = max(1, Int(visibleFrames(width: width).rounded(.up)))
            let end = min(frameCount, start + visible)
            let range = start..<end
            guard range.count > 1, frameCount > 0, zoom > 1.02 else {
                detail = nil
                detailRange = 0..<0
                return
            }
            let overviewInView = peaks.mins.count * range.count / max(frameCount, 1)
            if overviewInView >= pixelCount {
                detail = nil
                detailRange = 0..<0
                return
            }
            if detailRange == range, detail != nil { return }
            let source = channels
            let floor = peaks.amplitude
            let built = await Task.detached(priority: .userInitiated) {
                WaveformPeaks.make(
                    channels: source,
                    range: range,
                    bucketCount: pixelCount,
                    preservedAmplitude: floor
                )
            }.value
            guard !Task.isCancelled else { return }
            detail = built
            detailRange = range
        }
    }

    private func tickInterval(visibleSeconds: Double, width: CGFloat) -> Double {
        let candidates = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let minimumSpacing: CGFloat = 68
        guard visibleSeconds > 0 else { return 1 }
        for interval in candidates {
            let spacing = width * CGFloat(interval / visibleSeconds)
            if spacing >= minimumSpacing { return interval }
        }
        return candidates[candidates.count - 1]
    }

    static func playheadFrame(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        playheadFrame(at: x, width: width, count: count, start: 0, visible: CGFloat(count))
    }

    static func playheadFrame(at x: CGFloat, width: CGFloat, count: Int, start: CGFloat, visible: CGFloat) -> Int {
        let bound = bound(at: x, width: width, count: count, start: start, visible: visible)
        return min(bound, max(count - 1, 0))
    }

    static func bound(at x: CGFloat, width: CGFloat, count: Int, start: CGFloat = 0, visible: CGFloat? = nil) -> Int {
        guard count > 0, width > 0 else { return 0 }
        let span = max(visible ?? CGFloat(count), 1)
        let clamped = min(max(0, x), width)
        if clamped >= width { return min(count, Int((start + span).rounded(.up))) }
        return min(count, max(0, Int(start + (clamped / width) * span)))
    }
}

private extension View {
    @ViewBuilder
    func selectionEdgeCursor() -> some View {
        #if os(macOS)
        onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.resizeLeftRight.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct WaveformScrollMonitor: NSViewRepresentable {
    var onScroll: (CGFloat) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class MonitorView: NSView {
        var onScroll: ((CGFloat) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window == window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let rawX = event.scrollingDeltaX
                let rawY = event.scrollingDeltaY
                let useVertical = event.modifierFlags.contains(.shift) && abs(rawY) > abs(rawX)
                var delta = useVertical ? rawY : rawX
                let horizontal = useVertical || abs(rawX) > abs(rawY)
                guard horizontal, delta != 0 else { return event }
                if !event.hasPreciseScrollingDeltas {
                    delta *= 28
                }
                return self.onScroll?(delta) == true ? nil : event
            }
        }

        deinit {
            stop()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
#endif
