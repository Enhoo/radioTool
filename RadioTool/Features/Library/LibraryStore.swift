import Foundation
import Observation

private struct LibraryIndex: Codable {
    var recordings: [Recording]
}

@Observable
final class LibraryStore {
    private(set) var recordings: [Recording] = []
    var lastError: String?

    private let directory: URL
    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func recording(id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func fileURL(id: UUID) -> URL? {
        guard let recording = recording(id: id) else { return nil }
        return directory.appendingPathComponent(recording.fileName)
    }

    func makeRecordingURL() -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).wav")
    }

    func addRecordedFile(at url: URL, frameCount: Int) throws {
        let fileName = url.lastPathComponent
        let recording = Recording(
            id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(),
            title: "录音 \(TimeFormat.dateTime.string(from: Date()))",
            createdAt: Date(),
            duration: Double(frameCount) / 48_000,
            sampleRate: 48_000,
            channelCount: 1,
            fileName: fileName
        )
        recordings.insert(recording, at: 0)
        try saveIndex()
    }

    func importAudio(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let samples = try AudioFileStore.read(url: url)
        let rawTitle = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "导入的音频" : String(rawTitle.prefix(80))
        try add(samples: samples, title: title)
    }

    func replaceAudio(id: UUID, samples: AudioSamples) throws {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let destination = directory.appendingPathComponent(recordings[index].fileName)
        let temporary = destination.appendingPathExtension("tmp")
        try AudioFileStore.write(samples, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        recordings[index].duration = samples.duration
        recordings[index].sampleRate = samples.sampleRate
        recordings[index].channelCount = samples.channelCount
        try saveIndex()
    }

    func delete(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let url = directory.appendingPathComponent(recordings[index].fileName)
        recordings.remove(at: index)
        try? FileManager.default.removeItem(at: url)
        try? saveIndex()
    }

    private func add(samples: AudioSamples, title: String) throws {
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        try AudioFileStore.write(samples, to: directory.appendingPathComponent(fileName))
        let recording = Recording(
            id: id,
            title: title,
            createdAt: Date(),
            duration: samples.duration,
            sampleRate: samples.sampleRate,
            channelCount: samples.channelCount,
            fileName: fileName
        )
        recordings.insert(recording, at: 0)
        try saveIndex()
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            recordings = []
            return
        }
        let data = try Data(contentsOf: indexURL)
        let index = try Self.decoder.decode(LibraryIndex.self, from: data)
        recordings = index.recordings.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveIndex() throws {
        let data = try Self.encoder.encode(LibraryIndex(recordings: recordings))
        try data.write(to: indexURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
