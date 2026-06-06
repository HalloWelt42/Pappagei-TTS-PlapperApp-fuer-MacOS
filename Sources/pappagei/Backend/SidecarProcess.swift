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
        let home = FileManager.default.homeDirectoryForCurrentUser
        backendDir = home.appending(path: "pappagei/backend")
        python = backendDir.appending(path: ".venv/bin/python")
        logURL = backendDir.appending(path: "sidecar.log")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: python.path)
    }

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
        do {
            try p.run()
            process = p
        } catch {
            NSLog("pappagei: failed to start sidecar: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
