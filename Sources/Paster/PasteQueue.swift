import Foundation

/// Session-only queue. Advance only after clipboard staging or a paste event succeeds.
struct PasteQueue: Sendable {
    private(set) var clips: [Clip] = []
    mutating func append(_ values: [Clip]) {
        var known = Set(clips.map(\.id))
        for clip in values where known.insert(clip.id).inserted { clips.append(clip) }
    }
    mutating func update(_ clip: Clip) { if let index = clips.firstIndex(where: { $0.id == clip.id }) { clips[index] = clip } }
    mutating func remove(id: String) { clips.removeAll { $0.id == id } }
    mutating func reverse() { clips.reverse() }
    mutating func clear() { clips.removeAll() }
}
