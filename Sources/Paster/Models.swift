import Foundation

enum ClipKind: String, Codable, CaseIterable, Sendable { case text, link, image, file, color }
struct ClipRepresentation: Codable, Hashable, Sendable { var type: String; var data: Data }
struct ClipPayload: Codable, Hashable, Sendable { var items: [[ClipRepresentation]] }
struct Clip: Identifiable, Codable, Sendable, Equatable {
    var id: String = UUID().uuidString
    var kind: ClipKind
    var title: String
    var customTitle: String? = nil
    var text: String
    var sourceApp: String
    var sourceBundleID: String
    var createdAt: Date = Date()
    var lastUsedAt: Date = Date()
    var copyCount: Int = 1
    var fingerprint: String
    var boardID: String? = nil
    var boardPosition: Int? = nil
    var payload: ClipPayload
    var displayTitle: String { customTitle ?? title }
    var byteCount: Int { payload.items.flatMap { $0 }.reduce(0) { $0 + $1.data.count } }
}
struct Pinboard: Identifiable, Codable, Sendable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var color: String
    var position: Int = 0
    var icon: String? = nil
}
