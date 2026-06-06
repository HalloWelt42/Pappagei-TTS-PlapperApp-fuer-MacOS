import Foundation
import AppKit

/// Lightweight file logger so the capture/hotkey path can be diagnosed.
/// Writes to ~/Library/Application Support/pappagei/app.log
enum AppLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/pappagei")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "app.log")
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
