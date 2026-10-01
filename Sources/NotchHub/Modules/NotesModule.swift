import AppKit
import Combine
import SwiftUI

/// Module 5: one plain-text scratchpad, autosaved (debounced 300 ms) to UserDefaults.
@MainActor
final class NotesModule: ObservableObject, NotchModule {
    static let key = "notes.text"
    static let saveDelay: UInt64 = 300_000_000

    let id = "notes"
    let title = "Notes"
    let systemImage = "note.text"
    let panelHeight: CGFloat = 220

    @Published var text: String {
        didSet { scheduleSave() }
    }

    private let defaults: UserDefaults
    private let notify: TransientSink
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults, notify: @escaping TransientSink) {
        self.defaults = defaults
        self.notify = notify
        text = defaults.string(forKey: Self.key) ?? ""
    }

    func start() {}
    func stop() { saveNow() }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        notify(Transient("Copied", systemImage: "doc.on.doc.fill", tint: .white))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        defaults.set(text, forKey: Self.key)
    }

    var expandedView: AnyView { AnyView(NotesView(module: self)) }
    var settingsView: AnyView {
        AnyView(Text("Autosaved 300 ms after every change. Nothing to configure.")
            .font(.caption).foregroundColor(.secondary))
    }
}

struct NotesView: View {
    @ObservedObject var module: NotesModule

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                TextEditor(text: $module.text)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if module.text.isEmpty {
                    Text("Scratchpad. Click to type.")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.dim)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Text("\(module.wordCount) word\(module.wordCount == 1 ? "" : "s")")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Palette.dim)
                Spacer()
                Button("Copy all") { module.copyAll() }
                    .buttonStyle(PillButtonStyle(fill: .white, prominent: false))
                    .disabled(module.text.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}
