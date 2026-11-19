import AppKit
import EventKit

struct Sticky: Identifiable {
    let id: String
    let title: String
    let text: String
    let originalHTML: String
    let editable: Bool
    var canDelete = true

    var isLocal: Bool { id.hasPrefix("local:") }

    var excerpt: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return "" }
        if first.trimmingCharacters(in: .whitespaces) == title {
            return lines.dropFirst().joined(separator: " ")
        }
        return lines.joined(separator: " ")
    }
}

struct TaskItem: Identifiable, Equatable {
    let id: String
    let title: String
    let due: DateComponents?
    let completed: Bool

    var dueDate: Date? {
        guard var due else { return nil }
        let calendar = due.calendar ?? .current
        if due.hour == nil {
            due.hour = 23
            due.minute = 59
        }
        return calendar.date(from: due)
    }

    var isOverdue: Bool {
        !completed && (dueDate.map { $0 < Date() } ?? false)
    }
}

struct WorkspaceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

@MainActor
protocol NotesStore {
    func connect() throws
    func notes() throws -> [Sticky]
    func note(id: String) throws -> Sticky?
    func save(text: String, replacing note: Sticky?) throws -> String
    func open(_ note: Sticky) throws
    func delete(_ note: Sticky) throws
}

@MainActor
final class AppleNotes: NotesStore {
    private var script: NSAppleScript?

    func connect() throws {
        _ = try call("connectnotes")
    }

    func notes() throws -> [Sticky] {
        let result = try call("listnotes")
        guard result.numberOfItems > 0 else { return [] }
        return try (1...result.numberOfItems).map { try decode(result.atIndex($0)) }
    }

    func note(id: String) throws -> Sticky? {
        let row = try call("getnote", [id])
        return row.numberOfItems == 0 ? nil : try decode(row)
    }

    private func decode(_ row: NSAppleEventDescriptor?) throws -> Sticky {
        guard let row, let id = row.atIndex(1)?.stringValue,
              let title = row.atIndex(2)?.stringValue, let text = row.atIndex(3)?.stringValue,
              let html = row.atIndex(4)?.stringValue else {
            throw WorkspaceError("Apple Notes returned a note that Margin couldn’t read.")
        }
        let allowsChanges = row.atIndex(5)?.booleanValue == true
        return Sticky(id: id, title: title, text: text, originalHTML: html,
                      editable: allowsChanges && Self.isPlainText(html), canDelete: allowsChanges)
    }

    func save(text: String, replacing note: Sticky?) throws -> String {
        let html = Self.html(for: text)
        if let note {
            guard note.editable else { throw WorkspaceError("Edit this note in Apple Notes.") }
            _ = try call("updatenote", [note.id, note.originalHTML, html])
            return note.id
        }
        guard let id = try call("createnote", [html]).stringValue, !id.isEmpty else {
            throw WorkspaceError("Apple Notes didn’t return a note ID. Refresh before trying again.")
        }
        return id
    }

    func open(_ note: Sticky) throws {
        _ = try call("opennote", [note.id])
    }

    func delete(_ note: Sticky) throws {
        _ = try call("deletenote", [note.id, note.originalHTML])
    }

    static func html(for text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .escapeHTML()
            .components(separatedBy: "\n")
        return lines.map { line in
            "<div>" + (line.isEmpty ? "<br>" : line.replacingOccurrences(of: "  ", with: "&nbsp; ")) + "</div>"
        }.joined()
    }

    static func isPlainText(_ html: String) -> Bool {
        // Notes exports HTML even for plain text. Preserve anything beyond
        // its basic paragraph markup by editing it in Notes.
        let simpleTags = #"</?(?:html|body|div|p|br|span)(?:\s*/)?\s*>"#
        let remainder = html.replacingOccurrences(of: simpleTags, with: "", options: [.regularExpression, .caseInsensitive])
        return !remainder.contains("<")
    }

    private func call(_ handler: String, _ arguments: [String] = []) throws -> NSAppleEventDescriptor {
        if script == nil {
            guard let url = Bundle.main.url(forResource: "Notes", withExtension: "applescript") else {
                throw WorkspaceError("The Apple Notes automation script is missing.")
            }
            script = NSAppleScript(source: try String(contentsOf: url, encoding: .utf8))
        }
        guard let script else { throw WorkspaceError("Couldn’t load the Apple Notes automation script.") }
        let event = NSAppleEventDescriptor(
            eventClass: 0x61736372, eventID: 0x70736272, targetDescriptor: nil,
            returnID: -1, transactionID: 0
        )
        // 'snam' is the AppleScript subroutine name, '----' its arguments.
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: 0x736e616d)
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(list, forKeyword: 0x2d2d2d2d)
        var failure: NSDictionary?
        let result = script.executeAppleEvent(event, error: &failure)
        if let failure {
            if (failure[NSAppleScript.errorNumber] as? Int) == -1743 {
                throw WorkspaceError("Allow Margin to control Notes in System Settings → Privacy & Security → Automation.")
            }
            throw WorkspaceError(failure[NSAppleScript.errorMessage] as? String ?? "Apple Notes couldn’t complete the action.")
        }
        return result
    }
}

private extension String {
    func escapeHTML() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

@MainActor
final class AppleReminders {
    private enum Settings {
        static let listID = "margin.reminders.listID"
    }

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard

    func connect() async throws {
        guard try await store.requestFullAccessToReminders() else { throw accessError }
        let existingLists = store.calendars(for: .reminder)
        let matches = existingLists.filter { $0.title == "Margin" && isCloud($0.source) }
        guard matches.count < 2 else {
            throw WorkspaceError("Keep one Margin list in iCloud Reminders, then try again.")
        }

        let list: EKCalendar
        if let existing = matches.first {
            list = existing
        } else {
            guard let source = existingLists.first(where: { isCloud($0.source) })?.source
                    ?? store.sources.first(where: isCloud) else {
                throw WorkspaceError("Enable iCloud Reminders on this Mac, then try again.")
            }
            list = EKCalendar(for: .reminder, eventStore: store)
            list.title = "Margin"
            list.source = source
            try store.saveCalendar(list, commit: true)
        }
        guard list.allowsContentModifications else {
            throw WorkspaceError("The Margin list in Reminders is read-only.")
        }
        defaults.set(list.calendarIdentifier, forKey: Settings.listID)
    }

    func tasks() async throws -> [TaskItem] {
        let list = try connectedList()
        let predicate = store.predicateForReminders(in: [list])
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: WorkspaceError("Apple Reminders couldn’t load the Margin list."))
                    return
                }
                continuation.resume(returning: reminders.map {
                    TaskItem(id: $0.calendarItemIdentifier, title: $0.title ?? "",
                             due: $0.dueDateComponents, completed: $0.isCompleted)
                })
            }
        }
    }

    func save(title: String, due: DateComponents?, replacing item: TaskItem?) throws {
        let list = try connectedList()
        let reminder: EKReminder
        if let item {
            reminder = try existingReminder(for: item, in: list)
            guard reminder.title == item.title, reminder.dueDateComponents == item.due else {
                throw WorkspaceError("This task changed in Reminders. Reopen it to see the latest version.")
            }
        } else {
            reminder = EKReminder(eventStore: store)
            reminder.calendar = list
        }
        reminder.title = title
        if item == nil || item?.due != due {
            // Replace a timed due-date alert while preserving unrelated alarms.
            if item?.due?.hour != nil, let previousDate = item?.dueDate {
                for alarm in reminder.alarms ?? [] where alarm.absoluteDate == previousDate {
                    reminder.removeAlarm(alarm)
                }
            }
            reminder.dueDateComponents = due
            if let due, due.hour != nil, let date = due.date,
               reminder.alarms?.contains(where: { $0.absoluteDate == date }) != true {
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
        }
        try store.save(reminder, commit: true)
    }

    func setCompleted(_ item: TaskItem) throws {
        let reminder = try existingReminder(for: item, in: connectedList())
        guard reminder.isCompleted == item.completed else { return }
        reminder.isCompleted = !item.completed
        try store.save(reminder, commit: true)
    }

    func delete(_ item: TaskItem) throws {
        let reminder = try existingReminder(for: item, in: connectedList())
        guard reminder.title == item.title, reminder.dueDateComponents == item.due,
              reminder.isCompleted == item.completed else {
            throw WorkspaceError("This task changed in Reminders. Reopen it to see the latest version.")
        }
        try store.remove(reminder, commit: true)
    }

    private var accessError: WorkspaceError {
        WorkspaceError("Allow Margin in System Settings → Privacy & Security → Reminders.")
    }

    private func isCloud(_ source: EKSource) -> Bool {
        source.title.caseInsensitiveCompare("iCloud") == .orderedSame
    }

    private func connectedList() throws -> EKCalendar {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw accessError }
        guard let id = defaults.string(forKey: Settings.listID),
              let list = store.calendar(withIdentifier: id), isCloud(list.source),
              list.allowedEntityTypes.contains(.reminder), list.allowsContentModifications else {
            throw WorkspaceError("The connected Margin list is unavailable. Reconnect Apple Reminders to select it again.")
        }
        return list
    }

    private func existingReminder(for item: TaskItem, in list: EKCalendar) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder,
              reminder.calendar.calendarIdentifier == list.calendarIdentifier else {
            throw WorkspaceError("This task is no longer in the Margin list.")
        }
        return reminder
    }
}
