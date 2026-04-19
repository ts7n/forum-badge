import AppKit
import SwiftUI

final class PreferencesState: ObservableObject {
    @Published var config: AppConfig
    @Published var password: String
    @Published var availableGroups: [ServerGroup] = []
    @Published var passwordMessage: String = ""
    @Published var passwordMessageIsError: Bool = false
    @Published var groupsMessage: String = ""
    @Published var groupsMessageIsError: Bool = false
    @Published var isBusy: Bool = false
    @Published var passwordVerified: Bool
    @Published var verifiedPassword: String

    init() {
        let loadedConfig = Config.load()
        let loadedPassword = Config.loadPassword()
        self.config = loadedConfig
        self.password = loadedPassword
        // If we previously saved a password and config, treat it as verified until proven otherwise.
        self.verifiedPassword = loadedPassword
        self.passwordVerified = !loadedPassword.isEmpty
    }

    func mode(for groupId: Int) -> GroupMode {
        config.groups.first(where: { $0.id == groupId })?.mode ?? .off
    }

    func setMode(_ mode: GroupMode, for groupId: Int) {
        if let idx = config.groups.firstIndex(where: { $0.id == groupId }) {
            config.groups[idx].mode = mode
        } else {
            config.groups.append(GroupPref(id: groupId, mode: mode))
        }
    }

    func mergeGroups(_ fetched: [ServerGroup]) {
        let existing = Dictionary(uniqueKeysWithValues: config.groups.map { ($0.id, $0.mode) })
        config.groups = fetched.map { GroupPref(id: $0.id, mode: existing[$0.id] ?? .off) }
        availableGroups = fetched
    }
}

struct PreferencesView: View {
    @ObservedObject var state: PreferencesState
    var onSaved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Forum Badge").font(.title2).bold()

            if state.passwordVerified {
                Toggle(isOn: $state.config.enabled) {
                    Text("Enabled — runs in the background and at login")
                }
            }

            serverAndPasswordSection

            if state.passwordVerified {
                Divider()
                groupsSection
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if state.passwordVerified {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 700, idealHeight: 760)
    }

    @ViewBuilder private var serverAndPasswordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Server").font(.headline).frame(width: 90, alignment: .leading)
                TextField("Server URL", text: $state.config.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onChange(of: state.config.serverURL) { _ in
                        state.passwordVerified = false
                        state.passwordMessage = ""
                    }
            }
            HStack {
                Text("Password").font(.headline).frame(width: 90, alignment: .leading)
                SecureField("Password", text: $state.password)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: state.password) { newValue in
                        if newValue != state.verifiedPassword {
                            state.passwordVerified = false
                            state.passwordMessage = ""
                        } else if !newValue.isEmpty {
                            state.passwordVerified = true
                        }
                    }
                Button(state.passwordVerified ? "Verified ✓" : "Check") {
                    Task { await verifyPassword() }
                }
                .disabled(state.isBusy || state.password.isEmpty || state.passwordVerified || state.config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !state.passwordMessage.isEmpty {
                Text(state.passwordMessage)
                    .font(.callout)
                    .foregroundColor(state.passwordMessageIsError ? .red : .secondary)
            }
        }
    }

    @ViewBuilder private var groupsSection: some View {
        HStack {
            Text("Groups").font(.headline)
            Spacer()
            if !state.groupsMessage.isEmpty {
                Text(state.groupsMessage)
                    .font(.callout)
                    .foregroundColor(state.groupsMessageIsError ? .red : .secondary)
                    .lineLimit(1)
            }
            Button("Reload groups") { Task { await reloadGroups() } }
                .disabled(state.isBusy)
            if state.isBusy { ProgressView().controlSize(.small) }
        }

        Text("Off: ignored. Menu only: stories appear in the dropdown but don't affect the badge number. Menu + count: stories appear and count toward the badge number.")
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if state.availableGroups.isEmpty {
                    Text("No groups loaded yet. Click Reload groups.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(state.availableGroups, id: \.id) { group in
                    HStack {
                        Text(group.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                        Picker("", selection: Binding(
                            get: { state.mode(for: group.id) },
                            set: { state.setMode($0, for: group.id) }
                        )) {
                            Text("Off").tag(GroupMode.off)
                            Text("Menu only").tag(GroupMode.menuOnly)
                            Text("Menu + count").tag(GroupMode.menu)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 320)
                        .labelsHidden()
                    }
                }
            }
        }
        .frame(minHeight: 180)
    }

    @MainActor
    private func verifyPassword() async {
        state.isBusy = true
        state.passwordMessage = ""
        state.passwordMessageIsError = false
        defer { state.isBusy = false }
        let client = FlowClient(baseURL: state.config.serverURL, password: state.password)
        do {
            try await client.verify()
            state.verifiedPassword = state.password
            state.passwordVerified = true
            state.passwordMessage = ""
            if state.availableGroups.isEmpty {
                await reloadGroups()
            }
        } catch FlowClientError.unauthorized {
            state.passwordVerified = false
            state.passwordMessage = "Incorrect password."
            state.passwordMessageIsError = true
        } catch FlowClientError.invalidURL {
            state.passwordVerified = false
            state.passwordMessage = "Server URL is not valid. Contact whoever gave you this app."
            state.passwordMessageIsError = true
        } catch FlowClientError.http(let code) {
            state.passwordVerified = false
            state.passwordMessage = "Server returned HTTP \(code)."
            state.passwordMessageIsError = true
        } catch FlowClientError.transport(let msg) {
            state.passwordVerified = false
            state.passwordMessage = "Network error: \(msg)"
            state.passwordMessageIsError = true
        } catch {
            state.passwordVerified = false
            state.passwordMessage = "Error: \(error.localizedDescription)"
            state.passwordMessageIsError = true
        }
    }

    @MainActor
    private func reloadGroups() async {
        state.groupsMessage = ""
        state.groupsMessageIsError = false
        state.isBusy = true
        defer { state.isBusy = false }
        let client = FlowClient(baseURL: state.config.serverURL, password: state.password)
        do {
            let groups = try await client.groups()
            state.mergeGroups(groups)
            state.groupsMessage = "Loaded \(groups.count) groups."
        } catch FlowClientError.unauthorized {
            state.passwordVerified = false
            state.groupsMessage = "Authentication failed."
            state.groupsMessageIsError = true
        } catch FlowClientError.invalidURL {
            state.groupsMessage = "Server URL is not valid."
            state.groupsMessageIsError = true
        } catch FlowClientError.http(let code) {
            state.groupsMessage = "Server returned HTTP \(code)."
            state.groupsMessageIsError = true
        } catch FlowClientError.transport(let msg) {
            state.groupsMessage = "Network error: \(msg)"
            state.groupsMessageIsError = true
        } catch {
            state.groupsMessage = "Error: \(error.localizedDescription)"
            state.groupsMessageIsError = true
        }
    }

    private func save() {
        do {
            try Config.save(state.config)
            Config.savePassword(state.password)
            onSaved()
        } catch {
            state.passwordMessage = "Save failed: \(error.localizedDescription)"
            state.passwordMessageIsError = true
        }
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    let state: PreferencesState
    private let onSaved: () -> Void

    init(state: PreferencesState, onSaved: @escaping () -> Void) {
        self.state = state
        self.onSaved = onSaved
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Forum Badge — Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        let view = PreferencesView(
            state: state,
            onSaved: { [weak self] in
                onSaved()
                self?.close()
            }
        )
        window.contentViewController = NSHostingController(rootView: view)
    }

    // Closing the prefs window with the app "disabled" on disk means the user
    // never configured it (or just turned it off and saved). In either case
    // there's no background process to stay resident for, so quit. When
    // enabled, keep running silently in the menu bar.
    func windowWillClose(_ notification: Notification) {
        let saved = Config.load()
        if !saved.enabled {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndBringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
