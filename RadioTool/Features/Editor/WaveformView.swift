import SwiftUI

struct WaveformView: View {
    let peaks: WaveformPeaks
    let frameCount: Int
    var playhead: Int
    var selectionLower: Int
    var selectionUpper: Int
    var onScrub: (Int) -> Void
    var onSelection: (_ lower: Int, _ upper: Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWave(context: context, size: size)
                    drawSelection(context: context, size: size)
                    drawPlayhead(context: context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                        .onChanged { value in
                            onScrub(Self.playheadFrame(at: value.location.x, width: width, count: frameCount))
                        }
                )
                handle(edge: .lower, x: xPosition(selectionLower, width: width, endInclusive: false), height: height, width: width)
                handle(edge: .upper, x: xPosition(selectionUpper, width: width, endInclusive: true), height: height, width: width)
            }
            .coordinateSpace(name: "wave")
        }
        .frame(height: 180)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private enum Edge {
        case lower
        case upper
    }

    private func drawWave(context: GraphicsContext, size: CGSize) {
        let count = peaks.mins.count
        guard count > 0 else { return }
        let mid = size.height / 2
        let step = size.width / CGFloat(count)
        let scale = mid / CGFloat(max(peaks.amplitude, 0.001))
        var path = Path()
        for index in 0..<count {
            let x = CGFloat(index) * step + step / 2
            let high = mid - CGFloat(peaks.maxs[index]) * scale
            let low = mid - CGFloat(peaks.mins[index]) * scale
            path.move(to: CGPoint(x: x, y: high))
            path.addLine(to: CGPoint(x: x, y: low))
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: max(step * 0.8, 1))
    }

    private func drawSelection(context: GraphicsContext, size: CGSize) {
        guard frameCount > 0 else { return }
        let start = xPosition(selectionLower, width: size.width, endInclusive: false)
        let end = xPosition(selectionUpper, width: size.width, endInclusive: true)
        let rect = CGRect(x: start, y: 0, width: max(end - start, 1), height: size.height)
        context.fill(Path(rect), with: .color(.accentColor.opacity(0.18)))
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard frameCount > 0 else { return }
        let x = xPosition(playhead, width: size.width, endInclusive: false)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(.red), lineWidth: 1.5)
    }

    private func handle(edge: Edge, x: CGFloat, height: CGFloat, width: CGFloat) -> some View {
        Color.clear
            .frame(width: 28, height: height)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4, height: height)
            }
            .offset(x: x - 14)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                    .onChanged { value in
                        let bound = Self.bound(at: value.location.x, width: width, count: frameCount)
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

    private func xPosition(_ frame: Int, width: CGFloat, endInclusive: Bool) -> CGFloat {
        guard frameCount > 0 else { return 0 }
        let clamped = min(max(frame, 0), frameCount)
        if endInclusive && clamped == frameCount {
            return width
        }
        return CGFloat(min(clamped, max(frameCount - 1, 0))) / CGFloat(frameCount) * width
    }

    private static func playheadFrame(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        let bound = bound(at: x, width: width, count: count)
        return min(bound, max(count - 1, 0))
    }

    private static func bound(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0, width > 0 else { return 0 }
        let clamped = min(max(0, x), width)
        if clamped >= width { return count }
        return Int((clamped / width) * CGFloat(count))
    }
}
