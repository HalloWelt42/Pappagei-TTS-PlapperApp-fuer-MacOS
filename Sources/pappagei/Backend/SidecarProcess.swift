import Foundation

/// Launches and supervises the local Python TTS sidecar (uvicorn on 127.0.0.1:8765).
/// For this personal-tool build the backend lives at ~/pappagei/backend with its
/// own .venv; a distributable .app would bundle these instead.
final class SidecarProcess {
    static let host = "127.0.0.1"
    static let port = 8765

    private var process: Process?
    private let backendDir: URL
    private let python: URL
    private let logURL: URL

    init() {
        let fm = FileManager.default
        func hasVenv(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appending(path: ".venv/bin/python").path)
        }
        func hasSources(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appending(path: "server.py").path)
        }
        // 1) absolute path baked in at build time (survives app translocation and any
        //    clone location); 2) sibling of the .app; 3) ~/pappagei fallback.
        let baked = (Bundle.main.object(forInfoDictionaryKey: "PGBackendPath") as? String)
            .map { URL(fileURLWithPath: $0) }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "backend")
        let home = fm.homeDirectoryForCurrentUser.appending(path: "pappagei/backend")
        let candidates = [baked, sibling, home].compactMap { $0 }
        // Prefer a candidate with a working venv; failing that, one that at
        // least has the sources (broken venv -> repair hint with the right
        // path, instead of drifting off to the fallback).
        backendDir = candidates.first(where: hasVenv)
            ?? candidates.first(where: hasSources)
            ?? home
        python = backendDir.appending(path: ".venv/bin/python")
        logURL = backendDir.appending(path: "sidecar.log")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: python.path)
    }

    /// The backend sources exist even though the venv may be broken; used to
    /// tell "repo not found" apart from "venv needs repair".
    var sourcesPresent: Bool {
        FileManager.default.fileExists(atPath: backendDir.appending(path: "server.py").path)
    }

    var isRunning: Bool { process?.isRunning ?? false }

    var backendPath: String { backendDir.path }

    func start() {
        guard isInstalled, process == nil else { return }

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "uvicorn", "server:app",
                       "--host", Self.host, "--port", String(Self.port)]
        p.currentDirectoryURL = backendDir
        var env = ProcessInfo.processInfo.environment
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        p.environment = env
        if let log {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil      // health watchdog sees isRunning == false
                AppLog.log("sidecar exited unexpectedly (status \(proc.terminationStatus))")
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("pappagei: failed to start sidecar: \(error)")
        }
    }

    func stop() {
        guard let p = process else { return }
        p.terminationHandler = nil      // intentional shutdown: no exit callback
        process = nil                   // start() may run again right away
        p.terminate()
        // A hung Metal call can ignore SIGTERM; follow up so the port frees.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}
