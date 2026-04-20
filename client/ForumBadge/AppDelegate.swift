import AppKit
import ServiceManagement

enum Log {
    static func logPath() -> String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Library/Logs/ForumBadge.log")
    }
    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = logPath()
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

private let flowURL = "https://flow.snosites.com/assignments/home#submitted-to-my-groups"
private let pollInterval: TimeInterval = 120

enum FetchState {
    case idle
    case ok(fetchedAt: Date)
    case unreachable
    case unauthorized
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var prefsController: PreferencesWindowController?

    private var config = AppConfig()
    private var password = ""
    private var latestGroups: [ServerGroup] = []
    private var latestStories: [Int: [ServerStory]] = [:]
    private var fetchState: FetchState = .idle
    private var isUserLaunch: Bool = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApplication.launchIsDefaultLaunchKey is false when launched by a
        // login item / autosave / Launch Services helper, true when the user
        // double-clicks or a document open is requested. The PPID-based check
        // is unreliable because `open` reparents every launch under launchd.
        let info = notification.userInfo ?? [:]
        // Raw string to avoid Swift-interface name drift across SDKs.
        let isDefaultLaunch =
            (info["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool) ?? true
        isUserLaunch = isDefaultLaunch

        config = Config.load()
        password = Config.loadPassword()
        syncStatusItemVisibility()
        updateBadgeLabel()

        if shouldAutoOpenPreferences() {
            openPreferences()
        }

        if config.enabled && canPoll() {
            startPolling()
            Task { await fetchNow(includeGroups: true) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences()
        return true
    }

    // MARK: - UI affordances

    private func shouldAutoOpenPreferences() -> Bool {
        // Login-item launches (!isUserLaunch) must stay silent when the app is
        // fully configured; otherwise the prefs pop open every time the user
        // logs in. But if the app was never configured (or is disabled), show
        // the window even on a login-item launch so the user has a path back.
        let fullyConfigured = config.enabled && !password.isEmpty &&
            !config.groups.allSatisfy { $0.mode == .off }
        if !isUserLaunch && fullyConfigured { return false }
        if !config.enabled { return true }
        if password.isEmpty { return true }
        if config.groups.allSatisfy({ $0.mode == .off }) { return true }
        return false
    }

    private func syncStatusItemVisibility() {
        if config.enabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem = item
                if let button = item.button {
                    button.target = self
                    button.action = #selector(statusBarClicked(_:))
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func updateBadgeLabel() {
        guard let button = statusItem?.button else { return }
        button.font = NSFont(name: "Times-Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let count = currentCount()
        if !config.enabled || count == 0 {
            button.title = "TF"
            return
        }
        let badge: String
        if (1...20).contains(count), let scalar = Unicode.Scalar(0x2460 - 1 + count) {
            badge = String(Character(scalar))
        } else {
            badge = "\(count)"
        }
        button.title = "TF  \(badge)"
    }

    private func currentCount() -> Int {
        let countedIds = Set(config.groups.filter { $0.mode == .menu }.map { $0.id })
        var total = 0
        for id in countedIds {
            total += latestStories[id]?.count ?? 0
        }
        return total
    }

    // MARK: - Status item click handling

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick =
            event?.type == .rightMouseUp ||
            (event?.modifierFlags.contains(.control) ?? false)

        let menu = isRightClick ? buildRightClickMenu() : buildLeftClickMenu()
        // Assign to the status item for display, trigger, and clear so the next
        // click routes back through our action handler.
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    private func buildLeftClickMenu() -> NSMenu {
        let menu = NSMenu()

        if let header = stateHeader() {
            let item = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        let nameById = Dictionary(uniqueKeysWithValues: latestGroups.map { ($0.id, $0.name) })
        var wroteAny = false
        for pref in config.groups where pref.mode == .menu || pref.mode == .menuOnly {
            let name = nameById[pref.id] ?? "Group \(pref.id)"
            let stories = latestStories[pref.id] ?? []
            if wroteAny { menu.addItem(NSMenuItem.separator()) }
            wroteAny = true
            let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if stories.isEmpty {
                let empty = NSMenuItem(title: "      (no stories)", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for s in stories {
                    let title = s.title.count > 60 ? String(s.title.prefix(57)) + "…" : s.title
                    let item = NSMenuItem(title: title, action: #selector(openStoryURL(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = s.url
                    menu.addItem(item)
                }
            }
        }

        if wroteAny { menu.addItem(NSMenuItem.separator()) }

        let openFlowItem = NSMenuItem(title: "Open FLOW", action: #selector(openFlow), keyEquivalent: "")
        openFlowItem.target = self
        menu.addItem(openFlowItem)

        return menu
    }

    private func buildRightClickMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferencesMenuItem), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
        let quit = NSMenuItem(title: "Disable & Quit", action: #selector(disableAndQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func stateHeader() -> String? {
        if password.isEmpty { return "⚠ Not configured — right-click for Preferences" }
        switch fetchState {
        case .unauthorized: return "⚠ Authentication failed — right-click for Preferences"
        case .unreachable: return "⚠ Server unreachable"
        default: return nil
        }
    }

    // MARK: - Polling

    private func canPoll() -> Bool {
        !config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func startPolling() {
        stopPolling()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.fetchNow(includeGroups: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @MainActor
    private func fetchNow(includeGroups: Bool) async {
        guard config.enabled, canPoll() else { return }
        let client = FlowClient(baseURL: config.serverURL, password: password)
        let countedIds = config.groups.filter { $0.mode == .menu || $0.mode == .menuOnly }.map { $0.id }
        do {
            if includeGroups {
                async let groupsTask = client.groups()
                async let storiesTask = client.stories(forGroupIds: countedIds)
                let (groups, stories) = try await (groupsTask, storiesTask)
                self.latestGroups = groups
                var byId: [Int: [ServerStory]] = [:]
                for entry in stories { byId[entry.groupId] = entry.stories }
                self.latestStories = byId
            } else {
                let stories = try await client.stories(forGroupIds: countedIds)
                var byId: [Int: [ServerStory]] = [:]
                for entry in stories { byId[entry.groupId] = entry.stories }
                self.latestStories = byId
            }
            self.fetchState = .ok(fetchedAt: Date())
        } catch FlowClientError.unauthorized {
            self.fetchState = .unauthorized
            Log.write("Server rejected bearer token")
        } catch FlowClientError.invalidURL {
            self.fetchState = .unreachable
            Log.write("Invalid server URL: \(config.serverURL)")
        } catch {
            self.fetchState = .unreachable
            Log.write("Fetch failed: \(error)")
        }
        updateBadgeLabel()
    }

    // MARK: - Preferences lifecycle

    private func openPreferences() {
        if prefsController == nil {
            let state = PreferencesState()
            if !latestGroups.isEmpty {
                state.availableGroups = latestGroups
            }
            prefsController = PreferencesWindowController(state: state) { [weak self] in
                self?.applySavedPreferences()
            }
        } else {
            prefsController?.state.config = Config.load()
            prefsController?.state.password = Config.loadPassword()
        }
        prefsController?.showAndBringToFront()
    }

    private func applySavedPreferences() {
        let newConfig = Config.load()
        let newPassword = Config.loadPassword()
        let disabling = !newConfig.enabled && config.enabled
        config = newConfig
        password = newPassword

        reconcileLoginItem()

        if disabling {
            stopPolling()
            latestStories.removeAll()
            fetchState = .idle
            syncStatusItemVisibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
            return
        }

        syncStatusItemVisibility()
        updateBadgeLabel()
        if config.enabled && canPoll() {
            startPolling()
            Task { await fetchNow(includeGroups: true) }
        } else {
            stopPolling()
        }
    }

    private func reconcileLoginItem() {
        let p = Bundle.main.bundlePath
        let home = NSHomeDirectory()
        let inApps = p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/")
        guard inApps else { return }
        let svc = SMAppService.mainApp
        do {
            if config.enabled {
                if svc.status != .enabled {
                    try svc.register()
                }
            } else {
                if svc.status == .enabled {
                    try svc.unregister()
                }
            }
        } catch {
            Log.write("SMAppService reconcile failed: \(error)")
        }
    }

    // MARK: - Selectors

    @objc private func openStoryURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openFlow() {
        if let u = URL(string: flowURL) { NSWorkspace.shared.open(u) }
    }

    @objc private func refreshNow() {
        Task { await fetchNow(includeGroups: true) }
    }

    @objc private func openPreferencesMenuItem() {
        openPreferences()
    }

    @objc private func disableAndQuit() {
        // "Disabled" across this app means not a running background process and
        // not a login item. Persist the flag, unregister, then terminate.
        config.enabled = false
        try? Config.save(config)
        reconcileLoginItem()
        NSApp.terminate(nil)
    }
}
