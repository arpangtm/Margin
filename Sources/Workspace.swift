import SwiftUI

enum Section: String, CaseIterable {
    case notes = "Notes"
    case tasks = "Tasks"

    var symbol: String { self == .notes ? "note.text" : "checklist" }
    var appleApp: String { self == .notes ? "Apple Notes" : "Apple Reminders" }
}

enum DraftKey: Hashable {
    case new(Section)
    case note(String)
    case task(String)
}

struct Draft {
    let editorID = UUID()
    let section: Section
    var sticky: Sticky?
    let task: TaskItem?
    var text: String
    var tint: StickyTint
    var scheduled: Bool
    var date: Date
    var withTime: Bool
    private let originalDate: Date

    init(section: Section, sticky: Sticky? = nil, task: TaskItem? = nil, tint: StickyTint = .butter) {
        self.section = section
        self.sticky = sticky
        self.task = task
        self.tint = tint
        text = sticky?.text ?? task?.title ?? ""
        scheduled = task?.due != nil
        date = task?.dueDate ?? Date()
        originalDate = date
        withTime = task?.due?.hour != nil
    }

    var due: DateComponents? {
        guard scheduled else { return nil }
        if let existing = task?.due, originalDate == date, withTime == (existing.hour != nil) {
            return existing
        }
        return Self.dueComponents(for: date, withTime: withTime)
    }

    static func dueComponents(for date: Date, withTime: Bool) -> DateComponents {
        var parts: Set<Calendar.Component> = [.year, .month, .day, .calendar]
        if withTime { parts.formUnion([.hour, .minute, .second]) }
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(parts, from: date)
        if withTime, let reconstructed = calendar.date(from: components),
           abs(reconstructed.timeIntervalSince(date)) >= 60 {
            // Preserve which occurrence was picked during the fall clock change.
            components.timeZone = TimeZone(secondsFromGMT: calendar.timeZone.secondsFromGMT(for: date))
        }
        return components
    }

    var timeShortcut: TaskTimeShortcut {
        guard section == .tasks, text != task?.title else { return .plain }
        return TaskTimeShortcut.parse(text)
    }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sticky?.editable != false
    }

    var key: DraftKey {
        if let sticky { return .note(sticky.id) }
        if let task { return .task(task.id) }
        return .new(section)
    }

    var hasChanges: Bool {
        switch section {
        case .notes: text != (sticky?.text ?? "")
        case .tasks: text != (task?.title ?? "") || due != task?.due
        }
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var selection: Section = .notes
    @Published var query = ""
    @Published var pinned = false
    @Published var draft: Draft?
    @Published private(set) var busy = false
    @Published private(set) var notesConnected = false
    @Published private(set) var tasksConnected = false
    @Published private(set) var tasksAvailable = false
    @Published private(set) var pendingCompletionID: String?
    @Published private(set) var notes: [Sticky] = []
    @Published private(set) var tasks: [TaskItem] = [] {
        didSet { timedTasksChanged(tasks) }
    }
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var colors: [String: String] = [:]
    @Published var message: String?

    let preview: Bool
    var edgeTabsChanged: () -> Void = {}
    var timedTasksChanged: ([TaskItem]) -> Void = { _ in }
    var tasksViewed: () -> Void = {}
    private var pendingReminderRefresh = false

    private let defaults: UserDefaults
    private let file: LocalNotesFile
    private let appleNotes: any NotesStore
    private var local: [LocalSticky] = []
    private var cloud: [Sticky] = []
    private var cloudIDs: [String] = []
    private var latestSavedNoteID: String?
    private var unsaved: [DraftKey: Draft] = [:]
    private var autosaveWork: DispatchWorkItem?
    private var localLoadError: Error?
    private var reminderStore: AppleReminders?
    private var panelVisible = false

    init(preview: Bool, file: LocalNotesFile = .standard, defaults: UserDefaults = .standard,
         appleNotes: (any NotesStore)? = nil) {
        self.preview = preview
        self.file = file
        self.defaults = defaults
        self.appleNotes = appleNotes ?? AppleNotes()
        if preview {
            notesConnected = true
            tasksConnected = true
            tasksAvailable = true
            local = [
                LocalSticky(id: "local:today", text: "Today’s focus\nSend the draft. Make room for an afternoon walk."),
                LocalSticky(id: "local:weekend", text: "Weekend ideas\nTry the morning market and bring a notebook."),
                LocalSticky(id: "local:reading", text: "Reading list\nThe Creative Act\nA Field Guide to Getting Lost")
            ]
            colors = ["local:today": "butter", "local:weekend": "mint", "local:reading": "lilac"]
            favorites = ["local:today"]
            tasks = [
                TaskItem(id: "1", title: "Send the design draft", due: nil, completed: false),
                TaskItem(id: "2", title: "Pick up a notebook", due: nil, completed: false),
                TaskItem(id: "3", title: "Book a table for Friday", due: nil, completed: true)
            ]
        } else {
            notesConnected = defaults.bool(forKey: "margin.notes.connected")
            tasksConnected = defaults.bool(forKey: "margin.reminders.connected")
            favorites = Set(defaults.stringArray(forKey: "margin.notes.favorites") ?? [])
            colors = defaults.dictionary(forKey: "margin.notes.colors") as? [String: String] ?? [:]
            cloudIDs = defaults.stringArray(forKey: "margin.notes.edgeIDs") ?? []
            latestSavedNoteID = defaults.string(forKey: "margin.notes.latestSavedID")
            do { local = try file.load() }
            catch { localLoadError = error }
        }
        updateNotes()
    }

    var edgeStickies: [EdgeSticky] {
        let known = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let ids = local.map(\.id) + cloudIDs
        let remaining = ids.filter { $0 != latestSavedNoteID }
        let newest = ids.filter { $0 == latestSavedNoteID }
        let ordered = newest + remaining.filter { favorites.contains($0) }
            + remaining.filter { !favorites.contains($0) }
        return ordered.map { id in
            EdgeSticky(id: id, title: known[id] ?? "Note", tint: tint(for: id),
                       excerpt: notes.first { $0.id == id }?.excerpt ?? "")
        }
    }

    func tint(for id: String) -> StickyTint {
        colors[id].flatMap(StickyTint.init(rawValue:)) ?? StickyTint.forID(id)
    }

    func isConnected(_ section: Section) -> Bool {
        section == .notes ? notesConnected : tasksConnected
    }

    var filteredNotes: [Sticky] {
        let matching = notes.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || $0.text.localizedCaseInsensitiveContains(query) }
        return matching.filter { favorites.contains($0.id) } + matching.filter { !favorites.contains($0.id) }
    }

    var filteredTasks: [TaskItem] {
        tasks
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted {
                let left = $0.dueDate ?? .distantFuture
                let right = $1.dueDate ?? .distantFuture
                return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left < right
            }
    }

    func opened() {
        panelVisible = true
    }

    func closed() {
        panelVisible = false
        if !busy && !tasksConnected { reminderStore = nil }
    }

    func showLibrary(_ section: Section) {
        guard !busy else { return }
        stashDraft()
        if selection != section { query = "" }
        selection = section
        message = section == .notes && localLoadError != nil ? "Margin couldn’t read its saved notes." : nil
        if section == .tasks { tasksViewed() }
        refresh()
    }

    func newItem(_ section: Section) {
        guard !busy else { return }
        stashDraft()
        selection = section
        message = nil
        let palette = StickyTint.allCases
        let next = palette[notes.count % palette.count]
        draft = unsaved.removeValue(forKey: .new(section)) ?? Draft(section: section, tint: next)
        if section == .tasks && !tasksAvailable { refresh() }
    }

    func editorBinding(for snapshot: Draft) -> Binding<Draft> {
        Binding(
            get: {
                guard let current = self.draft, current.editorID == snapshot.editorID else { return snapshot }
                return current
            },
            set: { updated in
                guard self.draft?.editorID == snapshot.editorID else { return }
                self.draft = updated
                self.scheduleAutosave()
            }
        )
    }

    func openNote(id: String) {
        guard !busy else { return }
        if draft?.sticky?.id == id, draft?.hasChanges == true { return }
        stashDraft()
        selection = .notes
        message = nil
        if let pending = unsaved.removeValue(forKey: .note(id)) {
            draft = pending
        } else if !preview && !id.hasPrefix("local:") {
            perform {
                guard let note = try self.appleNotes.note(id: id) else {
                    self.cloud.removeAll { $0.id == id }
                    self.cloudIDs.removeAll { $0 == id }
                    self.updateNotes()
                    throw WorkspaceError("This note is no longer in the Margin folder.")
                }
                self.cloud.removeAll { $0.id == id }
                self.cloud.append(note)
                self.updateNotes()
                self.draft = Draft(section: .notes, sticky: note, tint: self.tint(for: id))
            }
        } else if let note = notes.first(where: { $0.id == id }) {
            draft = Draft(section: .notes, sticky: note, tint: tint(for: id))
        }
    }

    func editTask(_ task: TaskItem) {
        guard !busy else { return }
        stashDraft()
        if selection != .tasks { query = "" }
        selection = .tasks
        message = nil
        draft = unsaved.removeValue(forKey: .task(task.id)) ?? Draft(section: .tasks, task: task)
    }

    func backToLibrary() {
        stashDraft()
        message = nil
    }

    func refresh() {
        let section = selection
        guard !preview, isConnected(section) else { return }
        perform { try await self.reload(section) }
    }

    func refreshRemindersForEdge() {
        guard !preview, tasksConnected else { return }
        if busy {
            pendingReminderRefresh = true
            return
        }
        perform(reportErrors: false) { try await self.reload(.tasks) }
    }

    func connect() {
        let section = selection
        guard !preview else { return }
        perform {
            switch section {
            case .notes:
                try self.appleNotes.connect()
                self.notesConnected = true
                self.defaults.set(true, forKey: "margin.notes.connected")
            case .tasks:
                self.tasksAvailable = false
                try await self.reminders.connect()
                self.tasksConnected = true
                self.defaults.set(true, forKey: "margin.reminders.connected")
            }
            try await self.reload(section)
        }
    }

    func save(_ draft: Draft, onSaved: @escaping () -> Void = {}) {
        guard draft.canSave else { return }
        let shortcut = draft.timeShortcut
        if case let .invalid(reason) = shortcut {
            message = reason
            return
        }
        perform {
            switch draft.section {
            case .notes:
                let id: String
                if self.preview || draft.sticky?.isLocal == true || (draft.sticky == nil && !self.notesConnected) {
                    let note = draft.sticky.map { LocalSticky(id: $0.id, text: draft.text) }
                        ?? LocalSticky(text: draft.text)
                    let updated = [note] + self.local.filter { $0.id != note.id }
                    try self.writeLocal(updated)
                    id = note.id
                } else {
                    id = try self.appleNotes.save(text: draft.text, replacing: draft.sticky)
                    self.cacheAppleSave(id: id, text: draft.text)
                }
                self.draft = nil
                self.query = ""
                self.publishSavedNote(id: id, tint: draft.tint)
            case .tasks:
                let title: String
                let due: DateComponents?
                if case let .scheduled(parsedTitle, date) = shortcut {
                    title = parsedTitle
                    due = Draft.dueComponents(for: date, withTime: true)
                } else {
                    title = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    due = draft.due
                }
                if self.preview {
                    let id = draft.task?.id ?? UUID().uuidString
                    self.tasks.removeAll { $0.id == id }
                    self.tasks.append(TaskItem(id: id, title: title, due: due, completed: draft.task?.completed ?? false))
                } else {
                    try self.reminders.save(title: title, due: due, replacing: draft.task)
                }
                self.draft = nil
                self.query = ""
                try await self.reload(.tasks)
            }
            onSaved()
        }
    }

    func copyToiCloud(_ draft: Draft) {
        guard draft.sticky?.isLocal == true, notesConnected, !preview, draft.canSave else { return }
        perform {
            let id = try self.appleNotes.save(text: draft.text, replacing: nil)
            self.cacheAppleSave(id: id, text: draft.text)
            self.publishSavedNote(id: id, tint: draft.tint)
            self.message = "Copied to Apple Notes. The local note is still on this Mac."
        }
    }

    func toggleCompleted(_ item: TaskItem) {
        guard !busy else { return }
        pendingCompletionID = item.id
        perform {
            defer { self.pendingCompletionID = nil }
            // Keep the checked row in place long enough to see the change.
            try await Task.sleep(for: .milliseconds(325))
            if self.preview, let index = self.tasks.firstIndex(where: { $0.id == item.id }) {
                self.tasks[index] = TaskItem(id: item.id, title: item.title, due: item.due, completed: !item.completed)
            } else if !self.preview {
                try self.reminders.setCompleted(item)
            }
            try await self.reload(.tasks)
        }
    }

    func toggleFavorite(_ note: Sticky) {
        if favorites.remove(note.id) == nil { favorites.insert(note.id) }
        if !preview { defaults.set(Array(favorites), forKey: "margin.notes.favorites") }
        edgeTabsChanged()
    }

    func chooseTint(_ tint: StickyTint) {
        guard let current = draft, current.section == .notes else { return }
        draft?.tint = tint
        if let note = current.sticky {
            setTint(tint, for: note.id)
            edgeTabsChanged()
        }
    }

    func openInNotes(_ note: Sticky) {
        guard !preview, !note.isLocal else { return }
        perform { try self.appleNotes.open(note) }
    }

    func delete(note: Sticky, onDeleted: @escaping () -> Void = {}) {
        guard note.canDelete else { return }
        perform {
            if note.isLocal {
                try self.writeLocal(self.local.filter { $0.id != note.id })
            } else {
                // A just-saved preview does not have the canonical Apple Notes body yet.
                let snapshot = note.originalHTML.isEmpty ? try self.appleNotes.note(id: note.id) : note
                if let snapshot { try self.appleNotes.delete(snapshot) }
                self.cloud.removeAll { $0.id == note.id }
                self.cloudIDs.removeAll { $0 == note.id }
            }
            self.favorites.remove(note.id)
            self.colors.removeValue(forKey: note.id)
            if !self.preview {
                self.defaults.set(Array(self.favorites), forKey: "margin.notes.favorites")
                self.defaults.set(self.colors, forKey: "margin.notes.colors")
            }
            self.clearDraft(for: .note(note.id))
            self.updateNotes()
            onDeleted()
        }
    }

    func delete(task: TaskItem, onDeleted: @escaping () -> Void = {}) {
        perform {
            if !self.preview { try self.reminders.delete(task) }
            self.tasks.removeAll { $0.id == task.id }
            self.clearDraft(for: .task(task.id))
            onDeleted()
        }
    }

    private func clearDraft(for key: DraftKey) {
        unsaved.removeValue(forKey: key)
        if draft?.key == key { draft = nil }
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        guard draft?.section == .notes, draft?.hasChanges == true else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushAutosave() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func flushAutosave() {
        autosaveWork?.cancel()
        autosaveWork = nil
        guard var current = draft, current.section == .notes,
              current.hasChanges, current.canSave else { return }
        do {
            let id: String
            if preview || current.sticky?.isLocal == true || (current.sticky == nil && !notesConnected) {
                let note = current.sticky.map { LocalSticky(id: $0.id, text: current.text) }
                    ?? LocalSticky(text: current.text)
                try writeLocal([note] + local.filter { $0.id != note.id })
                id = note.id
            } else {
                id = try appleNotes.save(text: current.text, replacing: current.sticky)
                cacheAppleSave(id: id, text: current.text)
            }
            let title = current.text.split(separator: "\n").first.map(String.init) ?? "Untitled"
            if !preview && !id.hasPrefix("local:") {
                current.sticky = try appleNotes.note(id: id)
            } else {
                current.sticky = Sticky(id: id, title: title, text: current.text, originalHTML: "", editable: true)
            }
            draft = current
            publishSavedNote(id: id, tint: current.tint)
        } catch {
            message = "Couldn’t autosave: \(error.localizedDescription)"
        }
    }

    private func stashDraft() {
        flushAutosave()
        guard let draft else { return }
        if draft.hasChanges { unsaved[draft.key] = draft }
        self.draft = nil
    }

    private func setTint(_ tint: StickyTint, for id: String) {
        colors[id] = tint.rawValue
        if !preview { defaults.set(colors, forKey: "margin.notes.colors") }
    }

    private func cacheAppleSave(id: String, text: String) {
        // Publish a confirmed write immediately. Opening the note fetches its
        // authoritative body again before permitting edits.
        cloud.removeAll { $0.id == id }
        let title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled"
        cloud.insert(Sticky(id: id, title: title, text: text, originalHTML: "", editable: false), at: 0)
        if !cloudIDs.contains(id) { cloudIDs.insert(id, at: 0) }
    }

    private func publishSavedNote(id: String, tint: StickyTint) {
        latestSavedNoteID = id
        if !preview { defaults.set(id, forKey: "margin.notes.latestSavedID") }
        setTint(tint, for: id)
        updateNotes()
    }

    private func writeLocal(_ updated: [LocalSticky]) throws {
        if let localLoadError { throw localLoadError }
        if !preview { try file.save(updated) }
        local = updated
    }

    private func updateNotes() {
        notes = local.map(\.sticky) + cloud
        if !preview { defaults.set(cloudIDs, forKey: "margin.notes.edgeIDs") }
        edgeTabsChanged()
    }

    private var reminders: AppleReminders {
        if let reminderStore { return reminderStore }
        let store = AppleReminders()
        reminderStore = store
        return store
    }

    private func reload(_ section: Section) async throws {
        guard !preview else { return }
        switch section {
        case .notes:
            var fetched = try appleNotes.notes()
            if let id = latestSavedNoteID, !id.hasPrefix("local:"),
               !fetched.contains(where: { $0.id == id }),
               let recent = try appleNotes.note(id: id) {
                fetched.insert(recent, at: 0)
            }
            cloud = fetched
            cloudIDs = cloud.map(\.id)
            updateNotes()
        case .tasks:
            pendingReminderRefresh = false
            do {
                tasks = try await reminders.tasks()
                tasksAvailable = true
            } catch {
                tasksAvailable = false
                tasks = []
                throw error
            }
        }
    }

    private func perform(reportErrors: Bool = true, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        if reportErrors { message = nil }
        Task { @MainActor in
            do { try await operation() }
            catch { if reportErrors { message = error.localizedDescription } }
            busy = false
            if !panelVisible && !tasksConnected { reminderStore = nil }
            if pendingReminderRefresh {
                pendingReminderRefresh = false
                refreshRemindersForEdge()
            }
        }
    }
}
