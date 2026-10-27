import Foundation
import AppKit

/// Checks GitHub about once a day for a newer build and, on request, runs the installer.
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Where updates come from. A fork would change this one line.
    static let repoRaw = "https://raw.githubusercontent.com/jydubbs/gratitude-ledger/main"

    enum State: Equatable {
        case idle
        case upToDate               // only shown after a manual check
        case available
        case updating
        case failed
    }

    @Published private(set) var state: State = .idle

    /// The fingerprint baked into this build by the installer ("unknown" for builds made before updates existed).
    let currentBuild: String =
        (Bundle.main.object(forInfoDictionaryKey: "GLBuildHash") as? String) ?? "unknown"

    let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gratitude Ledger update.log")

    private let lastCheckKey = "lastUpdateCheck"
    private let checkEvery: TimeInterval = 24 * 3600

    /// Called every minute; only actually checks once a day.
    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        if Date().timeIntervalSince1970 - last >= checkEvery { check(manual: false) }
    }

    func check(manual: Bool) {
        guard state != .updating, let url = URL(string: Self.repoRaw + "/VERSION") else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let remote = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                // Offline or odd reply: stay quiet and try again tomorrow.
                guard ok, !remote.isEmpty, remote.count <= 64 else { return }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                if remote != self.currentBuild {
                    self.state = .available
                } else {
                    self.state = manual ? .upToDate : .idle
                }
            }
        }.resume()
    }

    /// Runs the same install command as the README. The installer quits this app,
    /// replaces it and opens the new one; the journal file in iCloud is untouched.
    func runUpdate() {
        state = .updating
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: Data("Update started \(Date())\n".utf8))
        guard let log = try? FileHandle(forWritingTo: logURL) else { state = .failed; return }
        log.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -o pipefail; curl -fsSL '\(Self.repoRaw)/install-gratitude-ledger.sh' | bash"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] proc in
            // On success the installer has already quit this app, so reaching here means it stopped early.
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 { self?.state = .failed }
            }
        }
        do {
            try process.run()
        } catch {
            log.write(Data("Couldn't start the installer: \(error.localizedDescription)\n".utf8))
            state = .failed
        }
    }

    func dismissMessage() {
        if state == .upToDate || state == .failed { state = .idle }
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    /// Short form shown in settings.
    var editionLabel: String {
        currentBuild == "unknown" ? "first edition" : "edition \(currentBuild.prefix(7))"
    }
}
