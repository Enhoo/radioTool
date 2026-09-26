import SwiftUI

struct RecorderView: View {
    var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var model: RecorderModel

    @MainActor
    init(store: LibraryStore) {
        self.store = store
        _model = State(initialValue: RecorderModel(store: store))
    }

    var body: some View {
        let level = CGFloat(min(max(model.level, 0), 1))
        VStack(spacing: 28) {
            Text(model.isRecording ? "正在录音" : "录音")
                .font(.title2)
            Text(TimeFormat.clock(model.elapsed, tenths: true))
                .font(.system(size: 48, weight: .medium, design: .monospaced))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * level)
                }
            }
            .frame(height: 12)
            .padding(.horizontal, 8)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                Button("取消") {
                    model.cancel()
                    dismiss()
                }
                Button("停止") {
                    model.stopAndSave()
                    if model.didFinish {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isRecording)
            }
        }
        .padding(32)
        .frame(minWidth: 320, minHeight: 280)
        .interactiveDismissDisabled(model.isRecording)
        .task {
            await model.startIfNeeded()
        }
    }
}
