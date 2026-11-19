import AppKit
import Carbon
import SwiftUI

private struct Shortcut: Codable {
    let key: UInt32
    let modifiers: UInt32
    let label: String
}

final class GlobalShortcuts: ObservableObject {
    @Published private(set) var labels: [String] = ["Not set", "Not set"]
    @Published var recording: Int?
    @Published var error: String?
    var invoke: (Int) -> Void = { _ in }
    private var shortcuts: [Shortcut?] = [nil, nil]
    private var registrations: [EventHotKeyRef?] = [nil, nil]
    private var handler: EventHandlerRef?
    private var recorder: Any?
    private let defaults: UserDefaults
    private let signature: OSType = 0x4D52474E

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x4D52474E else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.invoke(Int(id.id) - 1) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for index in 0..<2 {
            if let data = defaults.data(forKey: storageKey(index)),
               let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) {
                apply(shortcut, index: index, persist: false)
            }
        }
    }

    private func storageKey(_ index: Int) -> String { "margin.globalShortcut.\(index)" }

    func beginRecording(_ index: Int) {
        stopRecording()
        error = nil
        recording = index
        // Temporarily release our hotkeys so recording an existing combination works.
        for i in 0..<2 {
            if let ref = registrations[i] { UnregisterEventHotKey(ref) }
            registrations[i] = nil
        }
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                self.error = "Include Command, Control, or Option. Escape cancels."
                return nil
            }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let key = UInt32(event.keyCode)
            let other = 1 - index
            if let existing = self.shortcuts[other], existing.key == key, existing.modifiers == modifiers {
                self.error = "That shortcut is assigned to the other action."
                return nil
            }
            let symbols = (flags.contains(.control) ? "⌃" : "")
                + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "")
                + (flags.contains(.command) ? "⌘" : "")
            let name = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(key)"
            let shortcut = Shortcut(key: key, modifiers: modifiers, label: symbols + name)
            self.stopRecording()
            self.apply(shortcut, index: index, persist: true)
            return nil
        }
    }

    func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = nil
        for index in 0..<2 where registrations[index] == nil {
            if let shortcut = shortcuts[index] { apply(shortcut, index: index, persist: false) }
        }
    }

    func clear(_ index: Int) {
        stopRecording()
        if let ref = registrations[index] { UnregisterEventHotKey(ref) }
        registrations[index] = nil
        shortcuts[index] = nil
        labels[index] = "Not set"
        defaults.removeObject(forKey: storageKey(index))
        error = nil
    }

    private func apply(_ shortcut: Shortcut, index: Int, persist: Bool) {
        // Register the replacement before removing the old shortcut.
        if let existing = shortcuts[index], existing.key == shortcut.key,
           existing.modifiers == shortcut.modifiers, registrations[index] != nil { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: UInt32(index + 1))
        let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            error = "Couldn’t register \(shortcut.label). It may be used by another app."
            return
        }
        if let old = registrations[index] { UnregisterEventHotKey(old) }
        registrations[index] = ref
        shortcuts[index] = shortcut
        labels[index] = shortcut.label
        if persist, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: storageKey(index))
        }
    }

    deinit {
        if let recorder { NSEvent.removeMonitor(recorder) }
        for ref in registrations.compactMap({ $0 }) { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: GlobalShortcuts

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Global Shortcuts").font(.title2.bold())
            Text("Create a note or task from any app while Margin is running.")
                .foregroundStyle(.secondary)
            ForEach(0..<2, id: \.self) { index in
                HStack {
                    Text(index == 0 ? "New Note" : "New Task")
                    Spacer()
                    Button(shortcuts.recording == index ? "Press shortcut…" : shortcuts.labels[index]) {
                        shortcuts.beginRecording(index)
                    }
                    .frame(minWidth: 135)
                    Button("Clear") { shortcuts.clear(index) }
                }
            }
            Text("Click a shortcut, then press a key with ⌘, ⌃, or ⌥. Press Escape to cancel. Shortcuts are saved automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = shortcuts.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onDisappear { shortcuts.stopRecording() }
    }
}
