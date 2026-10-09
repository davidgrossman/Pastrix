import Foundation

struct ClipBoardPlacement: Equatable, Sendable {
    let clipID: String
    let boardID: String?
    let boardPosition: Int?
}

struct BoardAssignmentUndo: Equatable, Sendable {
    let placements: [ClipBoardPlacement]
    let destinationBoardID: String?
}

enum ClipSelectionRules {
    struct Result: Equatable {
        var selectedIDs: Set<String>
        var anchorID: String?
    }

    static func selecting(
        _ targetID: String,
        orderedIDs: [String],
        selectedIDs: Set<String>,
        anchorID: String?,
        extending: Bool,
        range: Bool
    ) -> Result {
        guard orderedIDs.contains(targetID) else {
            return Result(selectedIDs: selectedIDs, anchorID: anchorID)
        }

        if range,
           let anchorID,
           let start = orderedIDs.firstIndex(of: anchorID),
           let end = orderedIDs.firstIndex(of: targetID) {
            return Result(
                selectedIDs: Set(orderedIDs[min(start, end)...max(start, end)]),
                anchorID: anchorID
            )
        }

        if extending {
            var selection = selectedIDs
            if selection.contains(targetID) {
                selection.remove(targetID)
            } else {
                selection.insert(targetID)
            }
            return Result(selectedIDs: selection, anchorID: targetID)
        }

        return Result(selectedIDs: [targetID], anchorID: targetID)
    }

    static func dragIDs(
        startingWith targetID: String,
        orderedIDs: [String],
        selectedIDs: Set<String>
    ) -> [String] {
        guard selectedIDs.contains(targetID) else { return [targetID] }
        return orderedIDs.filter(selectedIDs.contains)
    }
}
