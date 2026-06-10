import Foundation

struct Health: Codable {
    let status: String
    let model: String
    let loaded: Bool
    let loading: Bool?          // true while a model is being loaded/downloaded
    let download_bytes: Int?    // HF cache size for that model, grows during download
    let sample_rate: Int
}

struct CustomVoice: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let ref_audio: String
    let ref_text: String?
    let speaker: String?
}

struct VoicesResponse: Codable {
    let model: String
    let speakers: [String]
    let custom: [CustomVoice]
}

private struct SynthBody: Encodable {
    let text: String
    let voice: String?
    let model: String?
    let speed: Double
    let temperature: Double?
    let repetition_penalty: Double?
}

private struct ImportBody: Encodable {
    let name: String
    let audio_path: String
    let transcript: String?
    let speaker: String?
}

/// Talks to the local sidecar. /synthesize is consumed as a byte stream so audio
/// starts playing while the rest is still being generated.
final class TTSClient: NSObject, URLSessionDataDelegate {
    private let base = URL(string: "http://\(SidecarProcess.host):\(SidecarProcess.port)")!
    private lazy var streamSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private let lock = NSLock()
    private var onData: [Int: (Data) -> Void] = [:]
    private var onDone: [Int: (Error?) -> Void] = [:]
    private var statusOK: [Int: Bool] = [:]

    struct ServerError: Error { let message: String }

    func health(timeout: TimeInterval = 60) async -> Health? {
        var req = URLRequest(url: base.appending(path: "health"))
        req.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(Health.self, from: data)
    }

    @discardableResult
    func warmup() async -> Bool {
        (try? await post("warmup", body: Optional<Int>.none)) != nil
    }

    func voices() async -> VoicesResponse? {
        guard let data = try? await get("voices") else { return nil }
        return try? JSONDecoder().decode(VoicesResponse.self, from: data)
    }

    func importVoice(name: String, audioPath: String, transcript: String?, speaker: String?) async -> CustomVoice? {
        let body = ImportBody(name: name, audio_path: audioPath, transcript: transcript, speaker: speaker)
        guard let data = try? await post("voices/import", body: body) else { return nil }
        return try? JSONDecoder().decode(CustomVoice.self, from: data)
    }

    func deleteVoice(id: String) async -> Bool {
        var req = URLRequest(url: base.appending(path: "voices/\(id)"))
        req.httpMethod = "DELETE"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Ask the sidecar to load `key` now (instead of lazily on the next read).
    /// Generous timeout: a first-time switch downloads the model.
    func switchModel(_ key: String) async -> Bool {
        var comps = URLComponents(url: base.appending(path: "model/switch"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "model", value: key)]
        guard let url = comps.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Stream synthesized PCM. `onChunk` is called as bytes arrive; the call
    /// returns when the stream completes (or throws on error).
    func synthesizeStream(
        text: String,
        voice: String?,
        model: String?,
        speed: Double,
        temperature: Double?,
        repetitionPenalty: Double?,
        onChunk: @escaping (Data) -> Void
    ) async throws {
        var req = URLRequest(url: base.appending(path: "synthesize"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            SynthBody(text: text, voice: voice, model: model, speed: speed,
                      temperature: temperature, repetition_penalty: repetitionPenalty)
        )
        let task = streamSession.dataTask(with: req)
        let id = task.taskIdentifier
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                statusOK[id] = true
                onData[id] = onChunk
                onDone[id] = { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? true
        lock.lock(); statusOK[dataTask.taskIdentifier] = ok; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let ok = statusOK[dataTask.taskIdentifier] ?? true
        let handler = onData[dataTask.taskIdentifier]
        lock.unlock()
        if ok { handler?(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock()
        let ok = statusOK[id] ?? true
        let done = onDone[id]
        onData[id] = nil
        onDone[id] = nil
        statusOK[id] = nil
        lock.unlock()
        if !ok && error == nil {
            done?(ServerError(message: "sidecar returned an error status"))
        } else {
            done?(error)
        }
    }

    // MARK: helpers

    private func get(_ path: String) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: base.appending(path: path))
        return data
    }

    private func post<T: Encodable>(_ path: String, body: T?) async throws -> Data {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
