import SwiftUI

private let ink = Color(red: 0.16, green: 0.14, blue: 0.24)
private let muted = Color(red: 0.38, green: 0.35, blue: 0.45)
private let violet = Color(red: 0.34, green: 0.25, blue: 0.62)
private let paper = Color(red: 0.98, green: 0.97, blue: 0.95)
private let lavender = Color(red: 0.93, green: 0.89, blue: 0.98)
private let hairline = Color(red: 0.89, green: 0.86, blue: 0.88)

struct PanelView: View {
    private enum Deletion {
        case note(Sticky)
        case task(TaskItem)

        var title: String {
            switch self {
            case .note(let note): note.title.isEmpty ? "Untitled" : note.title
            case .task(let task): task.title
            }
        }
    }

    @ObservedObject var workspace: Workspace
    let quickSticky: Bool
    let close: () -> Void
    let openWorkspace: () -> Void
    @FocusState private var taskTitleFocused: Bool
    @State private var confirmDelete = false
    @State private var pendingDeletion: Deletion?

    var body: some View {
        VStack(spacing: 0) {
            if quickSticky || workspace.draft != nil { header }
            if let draft = workspace.draft {
                editor(workspace.editorBinding(for: draft))
                    .id(draft.editorID)
            } else if quickSticky {
                if workspace.busy {
                    Text("Opening note…")
                        .font(.callout)
                        .foregroundStyle(muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Button("Open Margin Workspace", action: openWorkspace)
                        .buttonStyle(FilledButtonStyle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                sectionPicker
                    .padding(.top, 16)
                if workspace.selection == .notes && !workspace.notesConnected {
                    noteConnection
                }
                if workspace.selection == .notes || workspace.tasksAvailable {
                    browser
                } else {
                    remindersSetup
                }
            }
            if let message = workspace.message {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(lavender, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .accessibilityLabel("Status: \(message)")
            }
            footer
        }
        .foregroundStyle(ink)
        .tint(violet)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(workspace.draft?.section == .notes
                    ? Color(nsColor: (workspace.draft?.tint ?? .butter).paperColor) : paper)
        .clipShape(RoundedRectangle(cornerRadius: quickSticky ? 17 : 0))
        .overlay {
            if quickSticky {
                RoundedRectangle(cornerRadius: 17).strokeBorder(hairline).allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.light)
        .onExitCommand { close() }
        .alert("Delete “\(pendingDeletion?.title ?? "")”?", isPresented: $confirmDelete, presenting: pendingDeletion) { target in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                let onDeleted = quickSticky ? close : {}
                switch target {
                case .note(let note): workspace.delete(note: note, onDeleted: onDeleted)
                case .task(let task): workspace.delete(task: task, onDeleted: onDeleted)
                }
                pendingDeletion = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text(panelTitle)
                .font(.system(size: 25, weight: .semibold, design: .serif))
            Spacer()
            if quickSticky {
                iconButton(workspace.pinned ? "pin.fill" : "pin",
                           label: workspace.pinned ? "Unpin sticky" : "Pin sticky") {
                    workspace.pinned.toggle()
                }
                iconButton("xmark", label: "Close sticky", action: close)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    private var panelTitle: String {
        guard let draft = workspace.draft else { return "Margin" }
        if draft.section == .tasks { return draft.task == nil ? "New task" : "Edit task" }
        return draft.sticky == nil ? "New note" : "Sticky note"
    }

    private var noteConnection: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud")
                .foregroundStyle(violet)
                .accessibilityHidden(true)
            Text("Sync notes to your iPhone")
                .font(.system(size: 12))
                .foregroundStyle(muted)
            Spacer(minLength: 4)
            Button("Connect Apple Notes") { workspace.connect() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(violet)
                .buttonStyle(.borderless)
                .disabled(workspace.busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(lavender.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 16)
        .padding(.top, 9)
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(Section.allCases, id: \.self) { section in
                Button {
                    workspace.showLibrary(section)
                } label: {
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(workspace.selection == section ? violet : muted)
                        .background {
                            if workspace.selection == section {
                                RoundedRectangle(cornerRadius: 7).fill(.white)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(workspace.selection == section ? .isSelected : [])
            }
        }
        .padding(3)
        .background(ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .disabled(workspace.busy)
    }

    private var browser: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(muted)
                        .accessibilityHidden(true)
                    TextField("Search \(workspace.selection.rawValue.lowercased())", text: $workspace.query)
                        .textFieldStyle(.plain)
                    if !workspace.query.isEmpty {
                        iconButton("xmark.circle.fill", label: "Clear search") { workspace.query = "" }
                            .frame(width: 17, height: 17)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(hairline).allowsHitTesting(false) }

                Button {
                    workspace.newItem(workspace.selection)
                } label: {
                    Label(workspace.selection == .notes ? "New Note" : "New Task", systemImage: "plus")
                }
                .buttonStyle(FilledButtonStyle())
                .help(workspace.selection == .notes ? "New note" : "New task")
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 16)

            if workspace.selection == .notes {
                noteList
            } else {
                taskList
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 5)
        .disabled(workspace.busy)
    }

    private var noteList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(workspace.filteredNotes) { note in
                    let isFavorite = workspace.favorites.contains(note.id)
                    let tint = workspace.tint(for: note.id)
                    HStack(spacing: 9) {
                        Button {
                            workspace.openNote(id: note.id)
                        } label: {
                            HStack(spacing: 11) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: tint.tabColor))
                                    .frame(width: 4)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Text(note.title.isEmpty ? "Untitled" : note.title)
                                            .font(.system(size: 14, weight: .semibold))
                                        if note.isLocal && !workspace.preview {
                                            Image(systemName: "desktopcomputer")
                                                .font(.system(size: 9))
                                                .foregroundStyle(muted)
                                                .accessibilityLabel("On this Mac")
                                        }
                                    }
                                    if !note.excerpt.isEmpty {
                                        Text(note.excerpt).font(.system(size: 12)).foregroundStyle(muted)
                                    }
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        iconButton(isFavorite ? "star.fill" : "star", label: isFavorite ? "Remove favorite" : "Add favorite") {
                            workspace.toggleFavorite(note)
                        }
                        if note.canDelete { deleteButton(.note(note)) }
                    }
                    .padding(.horizontal, 10)
                    .background(Color(nsColor: tint.paperColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(hairline).allowsHitTesting(false) }
                }

                if workspace.filteredNotes.isEmpty {
                    if workspace.query.isEmpty {
                        VStack(spacing: 9) {
                            emptyState("No notes yet", icon: "note.text")
                            Button("Create a note") { workspace.newItem(.notes) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(violet)
                        }
                    } else {
                        emptyState("No matching notes", icon: "note.text")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                let matches = workspace.filteredTasks
                ForEach(matches.filter { !$0.completed }) { task in taskRow(task) }
                let completed = matches.filter(\.completed)
                if !completed.isEmpty {
                    Text("Completed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(muted)
                        .padding(.top, 8)
                        .padding(.leading, 3)
                    ForEach(completed) { task in taskRow(task) }
                }
                if matches.isEmpty {
                    emptyState(workspace.query.isEmpty ? "No tasks yet" : "No matching tasks", icon: "checklist")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func taskRow(_ item: TaskItem) -> some View {
        let checked = item.completed != (workspace.pendingCompletionID == item.id)
        return HStack(spacing: 7) {
            Button {
                workspace.toggleCompleted(item)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(violet)
                    .frame(width: 31, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Mark \(item.title) incomplete" : "Complete \(item.title)")

            Button {
                workspace.editTask(item)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 13, weight: .medium))
                            .strikethrough(checked)
                            .foregroundStyle(checked ? muted : ink)
                        if let date = item.dueDate {
                            Text(date.formatted(date: .abbreviated, time: item.due?.hour == nil ? .omitted : .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(item.isOverdue ? Color(red: 0.61, green: 0.20, blue: 0.28) : muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(muted)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(item.title)")
            deleteButton(.task(item))
        }
        .padding(.leading, 6)
        .padding(.trailing, 11)
        .frame(minHeight: 47)
        .background(.white, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(hairline).allowsHitTesting(false) }
    }

    private var remindersSetup: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 24))
                .frame(width: 57, height: 57)
                .foregroundStyle(violet)
                .background(lavender, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            Text("Apple Reminders")
                .font(.system(size: 23, weight: .medium, design: .serif))
            Text("Connect the Margin list in iCloud to see and complete tasks here.")
                .font(.system(size: 13))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 258)
                .fixedSize(horizontal: false, vertical: true)
            Button(workspace.busy ? "Connecting…" : "Connect Apple Reminders") { workspace.connect() }
                .buttonStyle(FilledButtonStyle())
                .disabled(workspace.busy)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private func editor(_ draft: Binding<Draft>) -> some View {
        let value = draft.wrappedValue
        let shortcut = value.timeShortcut
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if quickSticky { openWorkspace() }
                    else { workspace.backToLibrary() }
                } label: {
                    Label(quickSticky ? "All Notes" : value.section.rawValue, systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(violet)
                }
                .buttonStyle(.plain)
                Spacer()
                if let note = value.sticky, note.canDelete {
                    deleteButton(.note(note))
                } else if let task = value.task {
                    deleteButton(.task(task))
                }
            }
            if value.section == .notes {
                if value.sticky?.editable == false, let sticky = value.sticky {
                    ScrollView {
                        Text(sticky.text.isEmpty ? sticky.title : sticky.text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Open this note in Apple Notes to edit it.")
                        .font(.caption)
                        .foregroundStyle(muted)
                } else {
                    NoteTextEditor(text: draft.text)
                        .padding(7)
                        .background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(hairline).allowsHitTesting(false) }
                }
                swatches(value.tint)
            } else {
                TextField("Task title", text: draft.text, prompt: Text("Task title @ 1m, 2hr, or 2:10 PM"))
                    .focused($taskTitleFocused)
                    .task {
                        await Task.yield()
                        taskTitleFocused = true
                    }
                    .onSubmit {
                        guard value.canSave, !shortcut.isInvalid, !workspace.busy,
                              workspace.tasksAvailable else { return }
                        workspace.save(value, onSaved: close)
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                switch shortcut {
                case let .scheduled(_, date):
                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "bell")
                        .font(.callout)
                        .foregroundStyle(violet)
                case let .invalid(reason):
                    Text(reason).font(.callout).foregroundStyle(muted)
                case .plain:
                    Toggle("Due date", isOn: draft.scheduled)
                    if value.scheduled {
                        DatePicker("Date", selection: draft.date, displayedComponents: .date)
                        Toggle("Set a time", isOn: draft.withTime)
                        if value.withTime {
                            DatePicker("Time", selection: draft.date, displayedComponents: .hourAndMinute)
                        }
                    }
                }
                Spacer()
            }
            HStack {
                if let sticky = value.sticky, !workspace.preview {
                    if !sticky.isLocal {
                        Button("Open in Notes") { workspace.openInNotes(sticky) }
                            .buttonStyle(.borderless)
                    } else if workspace.notesConnected {
                        Button("Copy to iCloud") { workspace.copyToiCloud(value) }
                            .buttonStyle(.borderless)
                            .disabled(!value.canSave)
                    }
                }
                Spacer()
                if value.section == .tasks && !workspace.tasksAvailable {
                    Button("Connect Apple Reminders") { workspace.connect() }
                        .buttonStyle(FilledButtonStyle())
                } else if value.section == .tasks {
                    Button("Save") { workspace.save(value, onSaved: close) }
                        .buttonStyle(FilledButtonStyle())
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!value.canSave || shortcut.isInvalid)
                } else if value.section == .notes {
                    Button("Done") {
                        workspace.flushAutosave()
                        if workspace.draft?.hasChanges != true { close() }
                    }
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 13)
        .frame(maxHeight: .infinity)
        .disabled(workspace.busy)
    }

    private func swatches(_ selected: StickyTint) -> some View {
        HStack(spacing: 8) {
            ForEach(StickyTint.allCases) { tint in
                Button {
                    workspace.chooseTint(tint)
                } label: {
                    Circle()
                        .fill(Color(nsColor: tint.tabColor))
                        .frame(width: 17, height: 17)
                        .overlay {
                            if selected == tint {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(ink)
                            }
                        }
                        .frame(width: 23, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tint.label) note color")
                .accessibilityAddTraits(selected == tint ? .isSelected : [])
            }
            Spacer()
        }
    }

    private var storageLabel: String {
        if workspace.preview { return "Preview" }
        if workspace.draft?.sticky?.isLocal == true { return "On this Mac" }
        if workspace.selection == .tasks {
            return workspace.tasksAvailable ? "iCloud · Tasks" : "Reminders disconnected"
        }
        if workspace.notesConnected { return "iCloud · Notes" }
        return workspace.selection == .notes ? "On this Mac" : "Reminders disconnected"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(workspace.isConnected(workspace.selection) ? violet : hairline)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(storageLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted)
            Spacer()
            if workspace.busy {
                Text("Working…")
                    .font(.system(size: 11))
                    .foregroundStyle(muted)
            } else if workspace.draft == nil && workspace.isConnected(workspace.selection) && !workspace.preview {
                iconButton("arrow.clockwise", label: "Refresh") { workspace.refresh() }
                Menu {
                    Button("Reconnect \(workspace.selection.appleApp)") { workspace.connect() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Connection options")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(ink.opacity(0.035))
    }

    private func emptyState(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13))
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(violet)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func deleteButton(_ target: Deletion) -> some View {
        iconButton("trash", label: "Delete \(target.title)") {
            pendingDeletion = target
            confirmDelete = true
        }
    }
}

private struct NoteTextEditor: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("First line is the title")
                    .font(.system(size: 14))
                    .foregroundStyle(muted.opacity(0.8))
                    .padding(.top, 1)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .accessibilityLabel("Note text")
                .task {
                    await Task.yield()
                    focused = true
                }
        }
    }
}

private struct FilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(violet.opacity(enabled ? (configuration.isPressed ? 0.80 : 1) : 0.45),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
