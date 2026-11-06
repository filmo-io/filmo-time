import AppKit

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// Releases are tagged `vX.Y` and carry `Filmo-Time.dmg`. The update is only
/// installed if the new app is signed by the same team as the running one.
@MainActor
final class Updater {
    static let repo = "filmo-io/filmo-time"
    static let assetName = "Filmo-Time.dmg"

    private var timer: Timer?
    private var busy = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        // A little after launch, then every 8 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            Task { await self?.check(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 8 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    struct Release {
        let version: String
        let notes: String
        let dmg: URL
        let page: URL
    }

    func latestRelease() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == Self.assetName }),
              let dmg = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: obj["body"] as? String ?? "", dmg: dmg, page: page)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        let release: Release?
        do { release = try await latestRelease() } catch {
            if userInitiated { alert("No se pudo comprobar si hay actualizaciones", error.localizedDescription) }
            return
        }
        guard let release, Self.isNewer(release.version, than: currentVersion) else {
            if userInitiated { alert("Filmo Time está al día", "Tienes la última versión (\(currentVersion)).") }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Hay una versión nueva de Filmo Time"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "Versión \(release.version) (tienes la \(currentVersion))."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        a.addButton(withTitle: "Actualizar ahora")
        a.addButton(withTitle: "Más tarde")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        await install(from: release.dmg, fallbackPage: release.page)
    }

    /// Downloads (or reads) the DMG, checks the app inside, swaps it in and relaunches.
    func install(from dmg: URL, fallbackPage: URL?) async {
        busy = true
        defer { busy = false }
        do {
            let local: URL
            if dmg.isFileURL {
                local = dmg
            } else {
                let (tmp, resp) = try await URLSession.shared.download(from: dmg)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("La descarga falló.") }
                local = FileManager.default.temporaryDirectory.appendingPathComponent("Filmo-Time-update.dmg")
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: tmp, to: local)
            }
            try await Task.detached { try Self.swapIn(dmg: local) }.value
            NSApp.terminate(nil)
        } catch {
            let a = NSAlert()
            a.messageText = "No se pudo actualizar"
            a.informativeText = "\(error.localizedDescription)\n\nPuedes descargar la versión nueva a mano."
            a.addButton(withTitle: "Abrir descarga")
            a.addButton(withTitle: "Cerrar")
            if a.runModal() == .alertFirstButtonReturn, let fallbackPage { NSWorkspace.shared.open(fallbackPage) }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Runs off the main thread: mounts, verifies, stages the new app and hands
    /// the final swap to a small script that waits for this process to quit.
    nonisolated private static func swapIn(dmg: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let mount = fm.temporaryDirectory.appendingPathComponent("filmo-time-mount-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]).status == 0 else {
            throw UpdateError("No se pudo abrir el DMG.")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

        guard let newApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("El DMG no contiene la app.") }

        // Only accept an app signed by the same team as this one.
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]).status == 0 else {
            throw UpdateError("La firma de la versión nueva no es válida.")
        }
        let mine = teamID(current), theirs = teamID(newApp)
        guard let mine, mine == theirs else { throw UpdateError("La versión nueva no está firmada por el mismo desarrollador.") }

        // Stage next to the current app so the final move is on the same volume.
        let staged = current.deletingLastPathComponent().appendingPathComponent(".Filmo Time update.app")
        try? fm.removeItem(at: staged)
        guard run("/usr/bin/ditto", [newApp.path, staged.path]).status == 0 else {
            throw UpdateError("No se pudo copiar la versión nueva a \(current.deletingLastPathComponent().path).")
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "$1" && mv "$2" "$1" && xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/pluginkit -a "$1/Contents/PlugIns/DeskTimeWidgetExtension.appex" 2>/dev/null
        open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "filmo-time-update", current.path, staged.path]
        try p.run()
    }

    nonisolated private static func teamID(_ app: URL) -> String? {
        let out = run("/usr/bin/codesign", ["-dv", app.path]).output
        return out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
