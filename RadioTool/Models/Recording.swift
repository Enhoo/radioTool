import Foundation

struct Recording: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var fileName: String
}
