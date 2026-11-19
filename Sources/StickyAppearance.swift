import AppKit

enum StickyTint: String, CaseIterable, Codable, Identifiable {
    case butter, lilac, mint, peach, sky, rose

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var tabColor: NSColor {
        switch self {
        case .butter: NSColor(srgbRed: 0.99, green: 0.80, blue: 0.40, alpha: 1)
        case .lilac: NSColor(srgbRed: 0.78, green: 0.67, blue: 0.99, alpha: 1)
        case .mint: NSColor(srgbRed: 0.54, green: 0.83, blue: 0.65, alpha: 1)
        case .peach: NSColor(srgbRed: 1.00, green: 0.68, blue: 0.49, alpha: 1)
        case .sky: NSColor(srgbRed: 0.51, green: 0.77, blue: 0.98, alpha: 1)
        case .rose: NSColor(srgbRed: 0.97, green: 0.62, blue: 0.72, alpha: 1)
        }
    }

    var paperColor: NSColor {
        tabColor.blended(withFraction: 0.75, of: .white) ?? tabColor
    }

    static func forID(_ id: String) -> Self {
        let index = id.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return allCases[Int(UInt(bitPattern: index) % UInt(allCases.count))]
    }
}

struct LocalSticky: Codable {
    let id: String
    var text: String

    init(id: String = "local:" + UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }

    var sticky: Sticky {
        let title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled"
        return Sticky(id: id, title: title, text: text, originalHTML: "", editable: true)
    }
}

struct LocalNotesFile {
    let url: URL

    static var standard: Self {
        Self(url: URL.applicationSupportDirectory
            .appendingPathComponent("Margin", isDirectory: true)
            .appendingPathComponent("Notes.json"))
    }

    func load() throws -> [LocalSticky] {
        do {
            return try JSONDecoder().decode([LocalSticky].self, from: Data(contentsOf: url))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
    }

    func save(_ notes: [LocalSticky]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(notes).write(to: url, options: .atomic)
    }
}

struct EdgeSticky: Equatable {
    let id: String
    let title: String
    let tint: StickyTint
    var excerpt: String = ""
}
