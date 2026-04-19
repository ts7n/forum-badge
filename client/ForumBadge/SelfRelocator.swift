import AppKit

/// On launch, if the .app is anywhere other than /Applications or ~/Applications
/// (including the read-only App Translocation path Gatekeeper uses on a first
/// run from Downloads/DMG), copy the bundle into /Applications, strip the
/// quarantine attribute, relaunch from there, and exit the current instance.
/// Users never see a translocation or drag-to-Applications prompt.
enum SelfRelocator {
    /// If relocation happened, this function does not return.
    static func relocateIfNeeded() {
        if ProcessInfo.processInfo.environment["FORUMBADGE_SKIP_RELOCATE"] == "1" {
            return
        }
        let current = Bundle.main.bundleURL
        let path = current.path
        let home = NSHomeDirectory()
        let alreadyInApps =
            path.hasPrefix("/Applications/") ||
            path.hasPrefix(home + "/Applications/")
        if alreadyInApps { return }

        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(current.lastPathComponent)

        // If /Applications already has a copy, kill it first so we can replace it.
        killRunningInstances(exceptSelf: true)

        if FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                Log.write("Self-relocate: could not remove existing \(target.path): \(error.localizedDescription)")
                return
            }
        }

        do {
            try FileManager.default.copyItem(at: current, to: target)
        } catch {
            Log.write("Self-relocate: copy to /Applications failed: \(error.localizedDescription)")
            return
        }

        // Strip quarantine so the next launch isn't translocated.
        run("/usr/bin/xattr", arguments: ["-cr", target.path])

        // Relaunch from the new location and exit this (possibly translocated) process.
        run("/usr/bin/open", arguments: ["-n", target.path])
        exit(0)
    }

    private static func killRunningInstances(exceptSelf: Bool) {
        // pkill -x matches the process name exactly.
        let mine = getpid()
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "ForumBadge"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: { $0.isNewline })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        for pid in pids where !(exceptSelf && pid == Int(mine)) {
            kill(Int32(pid), SIGTERM)
        }
    }

    private static func run(_ path: String, arguments: [String]) {
        let p = Process()
        p.launchPath = path
        p.arguments = arguments
        do { try p.run() } catch { return }
        p.waitUntilExit()
    }
}
