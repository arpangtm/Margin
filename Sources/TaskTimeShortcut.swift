import Foundation

enum TaskTimeShortcut: Equatable {
    case plain
    case scheduled(title: String, date: Date)
    case invalid(String)

    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }

    private static let timePattern = try! NSRegularExpression(
        pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s+(.+))?$"#,
        options: .caseInsensitive
    )

    private static let durationPattern = try! NSRegularExpression(
        pattern: #"^(\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)$"#,
        options: .caseInsensitive
    )

    static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Self {
        guard let separator = text.range(of: " @ ", options: .backwards) else { return .plain }
        let suffix = text[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.isEmpty || suffix.first?.isASCII == true && suffix.first?.isNumber == true else {
            return .plain
        }
        let title = text[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)
        if let match = durationPattern.firstMatch(in: suffix, range: range),
           let amountRange = Range(match.range(at: 1), in: suffix),
           let unitRange = Range(match.range(at: 2), in: suffix) {
            guard !title.isEmpty else { return .invalid("Enter a reminder title before @.") }
            guard let amount = Double(suffix[amountRange]), amount > 0 else {
                return .invalid("Enter a duration greater than zero, like 1m or 2hr.")
            }
            let seconds = amount * (suffix[unitRange].lowercased().hasPrefix("h") ? 3600 : 60)
            let date = now.addingTimeInterval(seconds)
            guard seconds.isFinite, date < Date.distantFuture else {
                return .invalid("Choose a shorter reminder duration.")
            }
            return .scheduled(title: title, date: date)
        }
        guard let match = timePattern.firstMatch(in: suffix, range: range), !title.isEmpty else {
            return .invalid("Use a time like 2:10 PM, 2:10 Nov 20, or a duration like 1m or 2hr.")
        }

        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: suffix).map { String(suffix[$0]) }
        }

        guard let hour = group(1).flatMap(Int.init), hour < 24 else {
            return .invalid("Enter a valid hour.")
        }
        let minute = group(2).flatMap(Int.init) ?? 0
        guard minute < 60 else { return .invalid("Enter minutes from 00 to 59.") }
        let hours: [Int]
        if let period = group(3)?.lowercased() {
            guard (1...12).contains(hour) else { return .invalid("Use an hour from 1 to 12 with AM or PM.") }
            hours = [hour % 12 + (period == "pm" ? 12 : 0)]
        } else if (1...12).contains(hour) {
            hours = [hour % 12, hour % 12 + 12]
        } else {
            hours = [hour]
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        if let dateText = group(4) {
            guard let day = dayFor(dateText, now: now, calendar: calendar) else {
                return .invalid("Use a date like Nov 20 or Nov 20 2026.")
            }
            guard let date = occurrences(on: day, hours: hours, minute: minute, calendar: calendar)
                    .first(where: { $0 >= now }) else {
                return .invalid("Choose a time on that date that is still upcoming.")
            }
            return .scheduled(title: title, date: date)
        }

        let today = calendar.startOfDay(for: now)
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if let date = occurrences(on: day, hours: hours, minute: minute, calendar: calendar)
                .first(where: { $0 >= now }) {
                return .scheduled(title: title, date: date)
            }
        }
        return .invalid("Choose an upcoming time.")
    }

    private static func dayFor(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let parts = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard (2...3).contains(parts.count),
              let month = (0..<12).first(where: {
                  calendar.monthSymbols[$0].lowercased() == parts[0]
                      || calendar.shortMonthSymbols[$0].lowercased() == parts[0]
              }),
              let day = Int(parts[1]), (1...31).contains(day) else { return nil }
        let currentYear = calendar.component(.year, from: now)
        let explicitYear = parts.count == 3
        let year = explicitYear ? Int(parts[2]) : currentYear
        guard let year, (1...9999).contains(year) else { return nil }
        let monthNumber = month + 1
        let currentDay = calendar.startOfDay(for: now)
        let lastYear = explicitYear ? year : min(year + 8, 9999)
        for candidate in year...lastYear {
            let components = DateComponents(year: candidate, month: monthNumber, day: day)
            guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { continue }
            if explicitYear || date >= currentDay { return date }
        }
        return nil
    }

    private static func occurrences(on day: Date, hours: [Int], minute: Int, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: day).addingTimeInterval(-1)
        return hours.flatMap { hour in
            [Calendar.RepeatedTimePolicy.first, .last].compactMap { policy in
                guard let date = calendar.nextDate(after: start,
                    matching: DateComponents(hour: hour, minute: minute, second: 0),
                    matchingPolicy: .strict, repeatedTimePolicy: policy),
                    calendar.isDate(date, inSameDayAs: day) else { return nil }
                return date
            }
        }.sorted()
    }
}
