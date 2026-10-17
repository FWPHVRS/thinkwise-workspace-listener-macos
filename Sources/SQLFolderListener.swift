import AppKit
import CryptoKit
import UniformTypeIdentifiers

struct Stamp: Equatable {
    let digest: String
    let modified: Date
}

// The scanner never changes the watched files. Two seconds without a detected
// change avoids opening the short-lived empty file created by browser writes.
final class SQLWatcher {
    struct Pending { var stamp: Stamp; var since: Date }
    let folder: URL
    let updates: Bool
    let recursive: Bool
    var known: [URL: Stamp] = [:]
    var pending: [URL: Pending] = [:]
    var initialized = false
    init(folder: URL, updates: Bool, recursive: Bool) {
        self.folder = folder; self.updates = updates; self.recursive = recursive
    }
    func snapshot() throws -> [URL: Stamp] {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else {
            throw NSError(domain: "SQLListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected folder is unavailable."])
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let urls: [URL]
        if recursive {
            var failure: Error?
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else {
                throw NSError(domain: "SQLListener", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read the selected folder."])
            }
            urls = enumerator.allObjects.compactMap { $0 as? URL }
            if let error = failure { throw error }
        } else {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        var result: [URL: Stamp] = [:]
        for url in urls where url.pathExtension.lowercased() == "sql" {
            let info = try url.resourceValues(forKeys: Set(keys))
            guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            let data = try Data(contentsOf: url)
            let after = try url.resourceValues(forKeys: [.contentModificationDateKey])
            // A file that changed during the read is retried on the next scan.
            guard info.contentModificationDate == after.contentModificationDate else { continue }
            result[url] = Stamp(digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), modified: after.contentModificationDate ?? .distantPast)
        }
        return result
    }
    func scan(now: Date = Date()) throws -> [URL] {
        let current = try snapshot()
        if !initialized { known = current; initialized = true; return [] }
        known = known.filter { current[$0.key] != nil }
        pending = pending.filter { current[$0.key] != nil }
        var ready: [URL] = []
        for (url, stamp) in current {
            if let old = known[url], (!updates || old == stamp) {
                pending.removeValue(forKey: url)
                continue
            }
            if let item = pending[url], item.stamp == stamp {
                if now.timeIntervalSince(item.since) >= 2 {
                    ready.append(url); known[url] = stamp; pending.removeValue(forKey: url)
                }
            } else { pending[url] = Pending(stamp: stamp, since: now) }
        }
        return ready.sorted { $0.path < $1.path }
    }
}

final class ListenerApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    var window: NSWindow!
    var settingsStack: NSStackView?
    let folderLabel = NSTextField(wrappingLabelWithString: "No folder selected")
    let editorPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    let statusTitle = NSTextField(labelWithString: "Ready to set up")
    let statusIcon = NSImageView()
    let helpPopover = NSPopover()
    let stateLabel = NSTextField(wrappingLabelWithString: "Choose a folder to begin.")
    let updates = NSButton(checkboxWithTitle: "Also open updated SQL files", target: nil, action: nil)
    let recursive = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    let toggle = NSButton(title: "Start monitoring", target: nil, action: nil)
    var folder: URL?
    var watcher: SQLWatcher?
    var timer: Timer?
    var busy = false
    var generation = 0
    var retryFiles: Set<URL> = []
    let queue = DispatchQueue(label: "sql-folder-listener.scan", qos: .utility)
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preserve settings when upgrading the original local TablePlus-only app.
        if defaults.string(forKey: "folder") == nil,
           let legacy = defaults.persistentDomain(forName: "nl.lef.local.sql-folder-listener"),
           legacy["folder"] is String {
            for key in ["folder", "updates", "recursive"] {
                if let value = legacy[key] { defaults.set(value, forKey: key) }
            }
            defaults.set("com.tinyapp.TablePlus", forKey: "editorBundleID")
        }
        defaults.register(defaults: ["updates": true, "recursive": true])
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "SQL"
        statusItem.button?.toolTip = "SQL Folder Listener"
        let menu = NSMenu()
        menu.addItem(withTitle: "SQL Folder Listener", action: nil, keyEquivalent: "")
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let mainQuit = appMenu.addItem(withTitle: "Quit SQL Folder Listener", action: #selector(quitApp), keyEquivalent: "q")
        mainQuit.target = self; appItem.submenu = appMenu; mainMenu.addItem(appItem); NSApp.mainMenu = mainMenu
        makeWindow()
        if let path = defaults.string(forKey: "folder") {
            folder = URL(fileURLWithPath: path); folderLabel.stringValue = path; folderLabel.toolTip = path
            start()
        }
        showSettings()
    }
    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight); view.textColor = color
        return view
    }
    func vertical(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    func horizontal(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    func card(_ contents: NSStackView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom; box.titlePosition = .noTitle
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor
        box.borderWidth = 0.5; box.cornerRadius = 10
        box.contentViewMargins = NSSize(width: 16, height: 16)
        let container = NSView(); box.contentView = container
        contents.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contents.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contents.topAnchor.constraint(equalTo: container.topAnchor),
            contents.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        box.heightAnchor.constraint(equalTo: contents.heightAnchor, constant: 32).isActive = true
        return box
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 510),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SQL Folder Listener"; window.delegate = self; window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        let title = label("Your SQL workspace", size: 20, weight: .semibold)
        let intro = label("Open SQL files from Software Factory in your preferred editor.", color: .secondaryLabelColor)
        let heading = vertical([title, intro], spacing: 5)

        statusIcon.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([statusIcon.widthAnchor.constraint(equalToConstant: 9), statusIcon.heightAnchor.constraint(equalToConstant: 9)])
        statusTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        toggle.target = self; toggle.action = #selector(toggleWatching)
        toggle.bezelStyle = .rounded
        let statusRow = horizontal([statusIcon, statusTitle, flexibleSpace(), toggle])
        stateLabel.font = .systemFont(ofSize: 12); stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 3
        stateLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let statusContent = vertical([statusRow, stateLabel], spacing: 7)
        statusRow.widthAnchor.constraint(equalTo: statusContent.widthAnchor).isActive = true
        stateLabel.widthAnchor.constraint(equalTo: statusContent.widthAnchor).isActive = true
        let statusCard = card(statusContent)

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder)); choose.bezelStyle = .rounded
        let folderHeader = horizontal([label("Workspace folder", weight: .semibold), flexibleSpace(), choose])
        folderLabel.font = .systemFont(ofSize: 13); folderLabel.textColor = .labelColor
        folderLabel.isSelectable = true; folderLabel.maximumNumberOfLines = 1
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folderHint = label("Use the folder selected in Software Factory.", size: 11, color: .secondaryLabelColor)
        let folderContent = vertical([folderHeader, folderLabel, folderHint], spacing: 5)
        folderHeader.widthAnchor.constraint(equalTo: folderContent.widthAnchor).isActive = true
        folderLabel.widthAnchor.constraint(equalTo: folderContent.widthAnchor).isActive = true
        let folderCard = card(folderContent)

        editorPicker.bezelStyle = .rounded
        editorPicker.setAccessibilityLabel("SQL editor")
        editorPicker.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateEditorLabel()
        let editorRow = horizontal([label("Open files with", weight: .semibold), flexibleSpace(), editorPicker])
        let editorContent = vertical([editorRow], spacing: 0)
        editorRow.widthAnchor.constraint(equalTo: editorContent.widthAnchor).isActive = true
        let editorCard = card(editorContent)

        updates.title = "Open updated files"; recursive.title = "Include subfolders"
        updates.state = defaults.bool(forKey: "updates") ? .on : .off
        recursive.state = defaults.bool(forKey: "recursive") ? .on : .off
        updates.target = self; updates.action = #selector(optionsChanged)
        recursive.target = self; recursive.action = #selector(optionsChanged)
        updates.toolTip = "Reopen SQL files when their contents or modification time changes."
        recursive.toolTip = "Also watch folders inside the selected workspace."
        let options = vertical([label("Monitoring options", size: 12, weight: .semibold, color: .secondaryLabelColor), updates, recursive], spacing: 9)

        let help = NSButton(title: "How it works", target: self, action: #selector(showHelp(_:)))
        help.bezelStyle = .inline; help.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        help.imagePosition = .imageLeading
        let quit = NSButton(title: "Quit listener", target: self, action: #selector(quitApp)); quit.bezelStyle = .inline
        let footer = horizontal([help, flexibleSpace(), quit])
        let separator = NSBox(); separator.boxType = .separator
        let stack = vertical([heading, statusCard, folderCard, editorCard, options, separator, footer], spacing: 16)
        for view in [heading, statusCard, folderCard, editorCard, options, separator, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        settingsStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22)
        ])
        fitSettingsWindow()
        window.center()
    }
    func fitSettingsWindow() {
        guard let stack = settingsStack else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: stack.fittingSize.height + 42))
    }
    @objc func showHelp(_ sender: NSButton) {
        if helpPopover.isShown { helpPopover.close(); return }
        let content = vertical([
            label("How it works", size: 15, weight: .semibold),
            label("When monitoring starts", weight: .semibold),
            label("Files already in the folder are skipped. New files open automatically; enable Open updated files to include later edits.", size: 12, color: .secondaryLabelColor),
            label("After a file changes", weight: .semibold),
            label("The listener waits for writing to settle before sending the file to your editor. Keep your editor ready.", size: 12, color: .secondaryLabelColor),
            label("When you close this window", weight: .semibold),
            label("The listener stays in the menu bar. Use SQL → Settings to return, or Quit listener to stop the app.", size: 12, color: .secondaryLabelColor)
        ], spacing: 8)
        let controller = NSViewController(); controller.view = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -18),
            content.widthAnchor.constraint(equalToConstant: 294)
        ])
        controller.view.layoutSubtreeIfNeeded()
        controller.preferredContentSize = NSSize(width: 330, height: content.fittingSize.height + 36)
        helpPopover.behavior = .transient; helpPopover.contentViewController = controller
        helpPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    func showStatus(_ title: String, detail: String, color: NSColor) {
        statusTitle.stringValue = title; stateLabel.stringValue = detail; stateLabel.toolTip = detail
        statusIcon.contentTintColor = color
        stateLabel.textColor = color == .systemRed ? .systemRed : .secondaryLabelColor
        fitSettingsWindow()
    }
    @objc func showSettings() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Monitor this folder"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.stop(); self.folder = url; self.folderLabel.stringValue = url.path; self.folderLabel.toolTip = url.path
            self.defaults.set(url.path, forKey: "folder"); self.start()
        }
    }
    @objc func optionsChanged() {
        defaults.set(updates.state == .on, forKey: "updates")
        defaults.set(recursive.state == .on, forKey: "recursive")
        if watcher != nil { stop(); start() }
    }
    @objc func toggleWatching() { if watcher == nil { start() } else { stop(); showStatus("Paused", detail: "Resume to watch for new changes.", color: .secondaryLabelColor) } }
    func start() {
        guard let folder = folder else { chooseFolder(); return }
        watcher = SQLWatcher(folder: folder, updates: updates.state == .on, recursive: recursive.state == .on)
        generation += 1
        toggle.title = "Pause"; statusItem.button?.title = "SQL ●"
        showStatus("Monitoring", detail: updates.state == .on ? "Watching for new and updated SQL files." : "Watching for new SQL files.", color: .systemGreen)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() {
        timer?.invalidate(); timer = nil; watcher = nil; generation += 1; retryFiles.removeAll()
        toggle.title = "Resume"; statusItem.button?.title = "SQL"
    }
    func tick() {
        guard !busy, let watcher = watcher else { return }
        busy = true; let token = generation
        let retries = retryFiles; retryFiles.removeAll()
        queue.async {
            for url in retries { watcher.known.removeValue(forKey: url) }
            let result = Result { try watcher.scan() }
            DispatchQueue.main.async {
                self.busy = false
                guard self.generation == token else { return }
                switch result {
                case .success(let urls):
                    if urls.isEmpty, self.statusTitle.stringValue == "Folder unavailable" {
                        self.showStatus("Monitoring", detail: "Watching for SQL files.", color: .systemGreen)
                    }
                    for url in urls { self.openInEditor(url) }
                case .failure(let error): self.showStatus("Folder unavailable", detail: error.localizedDescription, color: .systemRed)
                }
            }
        }
    }
    func selectedEditor() -> URL? {
        if let identifier = defaults.string(forKey: "editorBundleID"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        if let path = defaults.string(forKey: "editorPath"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
    var hasExplicitEditor: Bool { defaults.string(forKey: "editorBundleID") != nil || defaults.string(forKey: "editorPath") != nil }
    func updateEditorLabel() {
        let name: String
        if let app = selectedEditor() {
            name = app.deletingPathExtension().lastPathComponent
        } else {
            name = hasExplicitEditor ? "Editor unavailable" : "macOS default"
        }
        editorPicker.removeAllItems()
        editorPicker.addItem(withTitle: name)
        let current = NSMenuItem(title: name, action: nil, keyEquivalent: ""); current.isEnabled = false
        editorPicker.menu?.addItem(current)
        editorPicker.menu?.addItem(.separator())
        let choose = NSMenuItem(title: "Choose application…", action: #selector(chooseEditor), keyEquivalent: ""); choose.target = self
        editorPicker.menu?.addItem(choose)
        let systemDefault = NSMenuItem(title: "Use macOS default", action: #selector(useDefaultEditor), keyEquivalent: ""); systemDefault.target = self
        systemDefault.state = hasExplicitEditor ? .off : .on
        editorPicker.menu?.addItem(systemDefault)
    }
    @objc func chooseEditor() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "Use this editor"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            self.defaults.set(app.path, forKey: "editorPath")
            if let identifier = Bundle(url: app)?.bundleIdentifier { self.defaults.set(identifier, forKey: "editorBundleID") }
            else { self.defaults.removeObject(forKey: "editorBundleID") }
            self.updateEditorLabel()
        }
    }
    @objc func useDefaultEditor() {
        defaults.removeObject(forKey: "editorBundleID"); defaults.removeObject(forKey: "editorPath"); updateEditorLabel()
    }
    func openInEditor(_ url: URL) {
        let editor = selectedEditor() ?? (hasExplicitEditor ? nil : NSWorkspace.shared.urlForApplication(toOpen: url))
        guard let app = editor else {
            retryFiles.insert(url)
            showStatus("Choose an editor", detail: "Select an installed application under Open files with.", color: .systemRed); return
        }
        let token = generation
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                if let error = error {
                    // Retry after another settling period instead of dropping the file.
                    self.retryFiles.insert(url)
                    self.showStatus("Could not open file", detail: "\(url.lastPathComponent): \(error.localizedDescription)", color: .systemRed)
                } else {
                    self.showStatus("Monitoring", detail: "Last opened: \(url.lastPathComponent)", color: .systemGreen)
                }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

func selfTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ file: String, _ body: String) throws { try Data(body.utf8).write(to: root.appendingPathComponent(file)) }
    func check(_ yes: Bool, _ message: String) { if !yes { fatalError(message) } }
    let t = Date()
    try write("existing.sql", "-- existing")
    let watcher = SQLWatcher(folder: root, updates: true, recursive: false)
    check(try watcher.scan(now: t).isEmpty, "Existing files must be skipped")
    try write("new.sql", "")
    check(try watcher.scan(now: t).isEmpty, "Must wait for writes")
    try write("new.sql", "-- completed")
    check(try watcher.scan(now: t.addingTimeInterval(1)).isEmpty, "Changed file resets settling")
    check(try watcher.scan(now: t.addingTimeInterval(2)).isEmpty, "Still settling")
    check(try watcher.scan(now: t.addingTimeInterval(3)).map(\.lastPathComponent) == ["new.sql"], "New SQL opens once")
    check(try watcher.scan(now: t.addingTimeInterval(4)).isEmpty, "No duplicates")
    try write("new.sql", "-- updated")
    _ = try watcher.scan(now: t.addingTimeInterval(5))
    check(try watcher.scan(now: t.addingTimeInterval(7)).count == 1, "Updates detected")
    try write("ignored.txt", "ignored")
    check(try watcher.scan(now: t.addingTimeInterval(8)).isEmpty, "Non SQL ignored")
    try write("deleted.sql", "-- disappearing")
    _ = try watcher.scan(now: t.addingTimeInterval(9))
    try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.sql"))
    check(try watcher.scan(now: t.addingTimeInterval(11)).isEmpty, "Removed pending file ignored")
    let newOnly = SQLWatcher(folder: root, updates: false, recursive: false)
    _ = try newOnly.scan(now: t)
    try write("new.sql", "-- another update")
    _ = try newOnly.scan(now: t.addingTimeInterval(1))
    check(try newOnly.scan(now: t.addingTimeInterval(4)).isEmpty, "New-only skips updates")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    let nested = SQLWatcher(folder: root, updates: false, recursive: true)
    _ = try nested.scan(now: t)
    try write("sub/nested.SQL", "-- nested")
    _ = try nested.scan(now: t.addingTimeInterval(1))
    check(try nested.scan(now: t.addingTimeInterval(3)).count == 1, "Recursive and uppercase SQL")
    check(try newOnly.scan(now: t.addingTimeInterval(5)).isEmpty, "Root-only skips subfolders")
    print("PASS: existing files, settling writes, new files, updates, duplicates, filtering, deletion, new-only, recursion")
}

if CommandLine.arguments.contains("--self-test") {
    do { try selfTest() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = ListenerApp()
    app.delegate = delegate
    app.run()
}
