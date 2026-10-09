import Foundation

struct PinboardIconOption: Identifiable, Equatable, Sendable {
    let symbol: String
    let name: String
    let category: PinboardIconCategory
    let keywords: [String]

    var id: String { symbol }

    func matches(_ query: String) -> Bool {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return true }
        let searchableText = ([name, symbol] + keywords).joined(separator: " ")
        return terms.allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
    }
}

enum PinboardIconCategory: String, CaseIterable, Identifiable, Sendable {
    case favorites = "Favorites"
    case work = "Work & Planning"
    case ideas = "Ideas & Creativity"
    case life = "Life & Home"
    case tools = "Tools & Files"
    case places = "Places & Nature"
    case current = "Current Icon"

    var id: String { rawValue }
}

struct PinboardIconSection: Identifiable, Equatable, Sendable {
    let category: PinboardIconCategory
    let options: [PinboardIconOption]

    var id: PinboardIconCategory { category }
}

enum PinboardIconCatalog {
    static let defaultSymbol = "pin.fill"

    static let all: [PinboardIconOption] = [
        option("pin.fill", "Pin", .favorites, "keep", "saved"),
        option("star.fill", "Star", .favorites, "favorite", "important"),
        option("heart.fill", "Heart", .favorites, "love", "personal"),
        option("bookmark.fill", "Bookmark", .favorites, "save", "reading"),
        option("flag.fill", "Flag", .favorites, "priority", "later"),
        option("bolt.fill", "Bolt", .favorites, "quick", "energy"),

        option("briefcase.fill", "Briefcase", .work, "work", "business"),
        option("folder.fill", "Folder", .work, "project", "files"),
        option("tray.full.fill", "Inbox", .work, "tray", "inbox"),
        option("doc.text.fill", "Document", .work, "notes", "text"),
        option("calendar", "Calendar", .work, "date", "schedule"),
        option("clock.fill", "Clock", .work, "time", "later"),
        option("checkmark.circle.fill", "Completed", .work, "done", "tasks"),
        option("person.2.fill", "Team", .work, "people", "group"),
        option("building.2.fill", "Office", .work, "company", "business"),
        option("chart.bar.fill", "Chart", .work, "report", "analytics"),

        option("lightbulb.fill", "Lightbulb", .ideas, "idea", "inspiration"),
        option("sparkles", "Sparkles", .ideas, "magic", "inspiration"),
        option("paintbrush.fill", "Paintbrush", .ideas, "art", "design"),
        option("pencil", "Pencil", .ideas, "write", "draft"),
        option("book.fill", "Book", .ideas, "read", "research"),
        option("graduationcap.fill", "Learning", .ideas, "study", "school"),
        option("brain.head.profile", "Thinking", .ideas, "brain", "research"),
        option("wand.and.stars", "Magic Wand", .ideas, "creative", "magic"),
        option("music.note", "Music", .ideas, "audio", "song"),
        option("camera.fill", "Camera", .ideas, "photo", "image"),
        option("film.fill", "Film", .ideas, "video", "movie"),

        option("house.fill", "Home", .life, "personal", "house"),
        option("cart.fill", "Cart", .life, "shopping", "buy"),
        option("bag.fill", "Bag", .life, "shopping", "store"),
        option("gift.fill", "Gift", .life, "present", "birthday"),
        option("fork.knife", "Food", .life, "meal", "recipe"),
        option("creditcard.fill", "Card", .life, "money", "payment"),
        option("dollarsign.circle.fill", "Money", .life, "finance", "budget"),
        option("key.fill", "Key", .life, "access", "password"),
        option("lock.fill", "Lock", .life, "private", "secure"),
        option("pawprint.fill", "Pets", .life, "animal", "dog", "cat"),
        option("figure.run", "Fitness", .life, "exercise", "health"),

        option("shippingbox.fill", "Package", .tools, "box", "delivery"),
        option("archivebox.fill", "Archive", .tools, "storage", "box"),
        option("externaldrive.fill", "Drive", .tools, "disk", "storage"),
        option("printer.fill", "Printer", .tools, "print", "paper"),
        option("wrench.and.screwdriver.fill", "Tools", .tools, "repair", "settings"),
        option("hammer.fill", "Build", .tools, "tool", "workshop"),
        option("terminal.fill", "Terminal", .tools, "code", "developer"),
        option("chevron.left.forwardslash.chevron.right", "Code", .tools, "developer", "programming"),
        option("envelope.fill", "Mail", .tools, "email", "message"),
        option("bubble.left.and.bubble.right.fill", "Conversation", .tools, "chat", "messages"),
        option("phone.fill", "Phone", .tools, "call", "contact"),
        option("link", "Link", .tools, "url", "web"),
        option("paperplane.fill", "Send", .tools, "share", "message"),

        option("globe", "Globe", .places, "world", "web"),
        option("location.fill", "Location", .places, "place", "pin"),
        option("map.fill", "Map", .places, "travel", "place"),
        option("airplane", "Airplane", .places, "travel", "flight"),
        option("car.fill", "Car", .places, "drive", "travel"),
        option("leaf.fill", "Leaf", .places, "nature", "garden"),
        option("sun.max.fill", "Sun", .places, "weather", "day"),
        option("moon.fill", "Moon", .places, "night", "sleep"),
        option("drop.fill", "Drop", .places, "water", "weather"),
        option("flame.fill", "Flame", .places, "fire", "hot")
    ]

    static let quickChoices: [PinboardIconOption] = [
        "star.fill", "briefcase.fill", "lightbulb.fill", "heart.fill",
        "house.fill", "book.fill", "folder.fill", "shippingbox.fill"
    ].compactMap { symbol in all.first { $0.symbol == symbol } }

    static func defaultOption(preferredSymbol: String? = nil) -> PinboardIconOption {
        if let preferredSymbol, let match = all.first(where: { $0.symbol == preferredSymbol }) {
            return match
        }
        return all.first(where: { $0.symbol == defaultSymbol })!
    }

    static func sections(matching query: String, currentSymbol: String?) -> [PinboardIconSection] {
        var options = all
        if let currentSymbol, !currentSymbol.isEmpty, !options.contains(where: { $0.symbol == currentSymbol }) {
            options.insert(
                PinboardIconOption(
                    symbol: currentSymbol,
                    name: "Current Icon",
                    category: .current,
                    keywords: ["existing", "custom"]
                ),
                at: 0
            )
        }

        return PinboardIconCategory.allCases.compactMap { category in
            let matches = options.filter { $0.category == category && $0.matches(query) }
            return matches.isEmpty ? nil : PinboardIconSection(category: category, options: matches)
        }
    }

    private static func option(
        _ symbol: String,
        _ name: String,
        _ category: PinboardIconCategory,
        _ keywords: String...
    ) -> PinboardIconOption {
        PinboardIconOption(symbol: symbol, name: name, category: category, keywords: keywords)
    }
}
