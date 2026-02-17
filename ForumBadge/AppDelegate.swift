import AppKit

private let flowURL = "https://flow.snosites.com/assignments/home#submitted-to-my-groups"

private enum Log {
    static func logPath() -> String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Library/Logs/ForumBadge.log")
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
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
private let flowGroupsAPI = "https://flow.snosites.com/api/v1/dashboard/groups"
private let flowAssignmentAPI = "https://flow.snosites.com/api/v1/assignment/"
private let checkInterval: TimeInterval = 5 * 60  // 5 minutes

struct FlowAssignment: Sendable {
    let id: String
    let title: String
}

/// Group id (API key) and display name for the menu section.
struct GroupSection: Sendable {
    let id: String
    let displayName: String
    let assignments: [FlowAssignment]
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var sections: [GroupSection] = []
    private var primaryCount: Int = 0  // only primary group counts toward badge
    private var config: [String: String] = [:]
    private let queue = DispatchQueue(label: "forum-badge.flow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadConfig()
        ensureStatusItem()
        updateBadgeLabel(count: 0)
        fetchAssignmentsAndUpdateUI()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.fetchAssignmentsAndUpdateUI()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func envPath() -> String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".config/forum-badge.env")
    }

    private func loadConfig() {
        let path = envPath()
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            Log.write("Config file missing or unreadable: \(path)")
            return
        }
        for line in content.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                if value.hasPrefix("'") && value.hasSuffix("'") { value = String(value.dropFirst().dropLast()) }
                if let decoded = value.removingPercentEncoding { value = decoded }
                config[key] = value
            }
        }
    }

    /// Ordered list of (api key, display name) from GROUP_NAMES. Names are the keys in the API assignments object.
    private func groupSectionsConfig() -> [(id: String, displayName: String)] {
        let names: [String] = (config["GROUP_NAMES"] ?? "")
            .split(separator: ",")
            .map { String($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        return names.map { name in (id: name, displayName: name) }
    }

    private func ensureStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
        }
    }

    private func updateBadgeLabel(count: Int) {
        guard let button = statusItem?.button else { return }
        let serif = NSFont(name: "Times-Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        button.font = serif
        if count == 0 {
            button.title = "TF"
        } else {
            // Unicode circled numbers ① (U+2460) through ⑳ (U+2473)
            let badge: String
            if (1...20).contains(count), let scalar = Unicode.Scalar(0x2460 - 1 + count) {
                badge = String(Character(scalar))
            } else {
                badge = "\(count)"
            }
            button.title = "TF  \(badge)"
        }
    }

    private func fetchAssignmentsAndUpdateUI() {
        queue.async { [weak self] in
            guard let self else { return }
            let (sections, primaryCount) = self.fetchAllSections()
            DispatchQueue.main.async {
                self.sections = sections
                self.primaryCount = primaryCount
                self.updateMenuBarFromSections()
                self.updateBadgeLabel(count: primaryCount)
            }
        }
    }

    /// XSRF for requests: prefer XSRF-TOKEN from Cookie (so it always matches), else FLOW_XSRF.
    private func xsrfFromConfig(cookie: String) -> String? {
        for part in cookie.split(separator: ";") {
            let part = part.trimmingCharacters(in: .whitespaces)
            guard part.hasPrefix("XSRF-TOKEN=") else { continue }
            let value = String(part.dropFirst("XSRF-TOKEN=".count))
            return value.removingPercentEncoding ?? value
        }
        return config["FLOW_XSRF"]?.isEmpty == false ? config["FLOW_XSRF"] : nil
    }

    private func fetchAllSections() -> ([GroupSection], Int) {
        guard let cookie = config["FLOW_COOKIE"], !cookie.isEmpty else {
            Log.write("Missing FLOW_COOKIE in config")
            return ([], 0)
        }
        guard let xsrf = xsrfFromConfig(cookie: cookie) else {
            Log.write("Missing XSRF: set FLOW_XSRF or include XSRF-TOKEN=... in FLOW_COOKIE")
            return ([], 0)
        }
        let groupList = groupSectionsConfig()
        if groupList.isEmpty {
            Log.write("GROUP_NAMES missing or empty in config")
            return ([], 0)
        }

        var request = URLRequest(url: URL(string: flowGroupsAPI)!)
        setFlowHeaders(request: &request, cookie: cookie, xsrf: xsrf)
        let response: (Data?, HTTPURLResponse?)
        do {
            response = try URLSession.shared.synchronousDataWithResponse(with: request)
        } catch {
            Log.write("Groups API request failed: \(error.localizedDescription)")
            return ([], 0)
        }
        let (data, urlResponse) = response
        if let r = urlResponse, r.statusCode != 200 {
            Log.write("Groups API HTTP \(r.statusCode)")
        }
        guard let data else {
            Log.write("Groups API returned no data")
            return ([], 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "(non-UTF8)"
            Log.write("Groups API response not JSON. Preview: \(preview)")
            return ([], 0)
        }
        guard let assignmentsByGroup = json["assignments"] as? [String: Any] else {
            let keys = json.keys.sorted().joined(separator: ", ")
            let msg = (json["message"] as? String) ?? ""
            Log.write("Groups API JSON has no 'assignments'. Keys: \(keys). Message: \(msg)")
            return ([], 0)
        }

        let apiGroupKeys = assignmentsByGroup.keys.sorted().joined(separator: ", ")
        Log.write("Groups API assignments keys: \(apiGroupKeys)")

        let primaryGroupId = groupList.first?.id
        var primaryCount = 0
        var result: [GroupSection] = []

        for (groupId, displayName) in groupList {
            let raw: Any? = assignmentsByGroup[groupId]
            if raw == nil {
                Log.write("No data for group '\(groupId)' (check GROUP_NAMES vs API assignment keys)")
            }
            guard let rawList = raw as? [[String: Any]] else {
                result.append(GroupSection(id: groupId, displayName: displayName, assignments: []))
                continue
            }
            var assignments: [FlowAssignment] = []
            for (idx, item) in rawList.enumerated() {
                let aid: String? = (item["assignment_id"] as? String)
                    ?? (item["assignment_id"] as? Int).map { String($0) }
                    ?? (item["id"] as? String)
                    ?? (item["id"] as? Int).map { String($0) }
                guard let aid else {
                    let itemKeys = item.keys.sorted().joined(separator: ", ")
                    Log.write("Group \(groupId) item \(idx) has no assignment_id/id. Keys: \(itemKeys)")
                    continue
                }
                let title = fetchAssignmentTitle(assignmentId: aid, cookie: cookie, xsrf: xsrf)
                assignments.append(FlowAssignment(id: aid, title: title ?? "Assignment"))
            }
            Log.write("Group \(groupId) (\(displayName)): \(rawList.count) raw, \(assignments.count) assignments")
            if groupId == primaryGroupId {
                primaryCount = assignments.count
            }
            result.append(GroupSection(id: groupId, displayName: displayName, assignments: assignments))
        }
        Log.write("Total primary count: \(primaryCount)")
        return (result, primaryCount)
    }

    private func setFlowHeaders(request: inout URLRequest, cookie: String, xsrf: String) {
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(xsrf, forHTTPHeaderField: "x-xsrf-token")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://flow.snosites.com/assignments/home", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
    }

    private func fetchAssignmentTitle(assignmentId: String, cookie: String, xsrf: String) -> String? {
        var request = URLRequest(url: URL(string: flowAssignmentAPI + assignmentId)!)
        setFlowHeaders(request: &request, cookie: cookie, xsrf: xsrf)
        guard let data = try? URLSession.shared.synchronousData(with: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else { return nil }
        return title
    }

    private func updateMenuBarFromSections() {
        ensureStatusItem()
        let menu = NSMenu()
        for section in sections {
            if menu.items.isEmpty == false {
                menu.addItem(NSMenuItem.separator())
            }
            let header = NSMenuItem(title: section.displayName, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for a in section.assignments {
                let title = a.title.count > 60 ? String(a.title.prefix(57)) + "…" : a.title
                let item = NSMenuItem(title: title, action: #selector(openFlow), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        statusItem?.menu = menu
    }

    @objc private func openFlow() {
        NSWorkspace.shared.open(URL(string: flowURL)!)
    }

    @objc private func refresh() {
        fetchAssignmentsAndUpdateUI()
    }
}

// Synchronous URLSession helper (used on background queue)
private extension URLSession {
    func synchronousData(with request: URLRequest) throws -> Data? {
        try synchronousDataWithResponse(with: request).0
    }
    func synchronousDataWithResponse(with request: URLRequest) throws -> (Data?, HTTPURLResponse?) {
        var data: Data?
        var urlResponse: URLResponse?
        var error: Error?
        let sem = DispatchSemaphore(value: 0)
        dataTask(with: request) { d, r, e in
            data = d
            urlResponse = r
            error = e
            sem.signal()
        }.resume()
        sem.wait()
        if let error { throw error }
        return (data, urlResponse as? HTTPURLResponse)
    }
}
