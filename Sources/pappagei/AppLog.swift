import Foundation
import AppKit

/// Lightweight file logger so the capture/hotkey path can be diagnosed.
/// Writes to ~/Library/Application Support/pappagei/app.log
enum AppLog {
    private static let maxBytes = 1_000_000

    private static let url: URL = {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/pappagei")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appending(path: "app.log")
        // Rotate once per launch so the log cannot grow without bound.
        if let size = (try? fm.attributesOfItem(atPath: log.path)[.size]) as? Int, size > maxBytes {
            let old = dir.appending(path: "app.log.old")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: log, to: old)
        }
        return log
    }()

    static func log(_ message: String) {
        NSLog("pappagei: %@", message)
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
