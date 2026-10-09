import Foundation

enum ClipSortOrder: String, Codable, Sendable, CaseIterable {
    case newestFirst, manual
    var title: String { self == .manual ? "Manual Order" : "Newest First" }
}

enum ItemOrdering {
    static func inserting(_ selection: [String], at target: String, after: Bool, in ids: [String]) -> [String] {
        let selected = Set(selection)
        guard !selected.isEmpty, selected.count == selection.count,
              selected.isSubset(of: Set(ids)), !selected.contains(target) else { return ids }
        let moving = ids.filter { selected.contains($0) }
        var remaining = ids.filter { !selected.contains($0) }
        guard let index = remaining.firstIndex(of: target) else { return ids }
        remaining.insert(contentsOf: moving, at: index + (after ? 1 : 0))
        return remaining
    }

    /// Move a selection to the target's position. Moving right lands after the
    /// target, moving left lands before it, including either end of the list.
    static func moving(_ selection: [String], to target: String, in ids: [String]) -> [String] {
        let selected = Set(selection)
        guard !selected.isEmpty, selected.count == selection.count,
              selected.isSubset(of: Set(ids)), !selected.contains(target),
              let start = ids.firstIndex(where: { selected.contains($0) }),
              let destination = ids.firstIndex(of: target) else { return ids }
        let moving = ids.filter { selected.contains($0) }
        var remaining = ids.filter { !selected.contains($0) }
        guard let targetIndex = remaining.firstIndex(of: target) else { return ids }
        remaining.insert(contentsOf: moving, at: targetIndex + (start < destination ? 1 : 0))
        return remaining
    }
}
