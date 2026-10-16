import Foundation

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class PilotAPI {
    let base: URL
    private let session: URLSession
    init(base: URL = URL(string: "http://127.0.0.1:3018")!) {
        self.base = base
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 130
        session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    }
    private func call(_ path: String, method: String = "GET", token: String? = nil,
                      body: Data? = nil, query: [URLQueryItem] = [], type: String = "application/json", uncertain: Bool = false) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = method == "POST" ? 120 : 10
        if let token { request.setValue(token, forHTTPHeaderField: "X-Pilot-Token") }
        if body != nil { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch { throw uncertain ? PilotError.uncertainUpload : PilotError.message("無法連到語音服務，請確認服務仍在執行後重試。") }
        guard let http = result.1 as? HTTPURLResponse else { throw PilotError.message("無法辨認服務回應。") }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
            throw PilotError.message((obj?["error"] as? String) ?? "語音服務回應錯誤（\(http.statusCode)）。")
        }
        return result.0
    }
    func config() async throws -> PilotConfig {
        let cfg = try JSONDecoder().decode(PilotConfig.self, from: await call("api/config"))
        guard cfg.app == "dex-voice-pilot", cfg.nativeProtocol == 1 else {
            throw PilotError.message("3018 的服務版本不相容，請停止舊服務後重新啟動 keyboardless。")
        }
        return cfg
    }
    func savePreferences(cleanup: String, key: String, remove: Bool, migrate: Bool, token: String) async throws {
        _ = try await call("api/preferences", method: "PUT", token: token,
            body: JSONSerialization.data(withJSONObject: ["cleanup":cleanup,"key":key,"removeKey":remove,"migrateKey":migrate]))
    }
    func checkPreferences(token: String) async throws {
        _ = try await call("api/preferences/check", method: "POST", token: token, body: Data("{}".utf8))
    }
    func upload(_ audio: URL, token: String) async throws -> PilotRun {
        let boundary = "DexVoice-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("sourceType", "real"), ("timingOrigin", "recording_stop")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"mac-dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audio)); append("\r\n--\(boundary)--\r\n")
        let data = try await call("api/runs", method: "POST", token: token, body: body,
                                  type: "multipart/form-data; boundary=\(boundary)", uncertain: true)
        do { return try JSONDecoder().decode(PilotRun.self, from: data) }
        catch { throw PilotError.uncertainUpload }
    }
    func run(_ id: String) async throws -> PilotRun {
        guard UUID(uuidString: id) != nil else { throw PilotError.message("無效的紀錄編號。") }
        return try JSONDecoder().decode(PilotRun.self, from: await call("api/runs/\(id)"))
    }
    func insights() async throws -> DictationInsights {
        do {return try JSONDecoder().decode(DictationInsights.self,from:await call("api/insights"))}
        catch {throw PilotError.message("統計尚未載入，請確認已重新啟動新版本機服務。")}
    }
    func usage(period: String = "all") async throws -> UsageReport {
        do {return try JSONDecoder().decode(UsageReport.self,from:await call("api/usage", query: [URLQueryItem(name:"period",value:period)]))}
        catch {throw PilotError.message("用量尚未載入，請確認已重新啟動新版本機服務。")}
    }
    func runs() async throws -> [PilotRun] {
        try JSONDecoder().decode([PilotRun].self, from: await call("api/runs"))
    }
    func saveGlossary(_ glossary: [String], token: String) async throws -> PilotSettings {
        try JSONDecoder().decode(PilotSettings.self, from: await call("api/glossary", method: "PUT", token: token,
            body: JSONEncoder().encode(PilotSettings(glossary: glossary))))
    }
    func retry(_ run: PilotRun, token: String) async throws -> PilotRun {
        let mode = run.rawText == nil ? "full" : "cleanup"
        let data = try await call("api/runs/\(run.id)/retry", method: "POST", token: token,
                                  body: JSONSerialization.data(withJSONObject: ["mode": mode]), uncertain: true)
        do { return try JSONDecoder().decode(PilotRun.self, from: data) }
        catch { throw PilotError.uncertainUpload }
    }
    func timing(_ id: String, token: String, milliseconds: Double) async {
        _ = try? await call("api/runs/\(id)", method: "PATCH", token: token,
                            body: JSONSerialization.data(withJSONObject: ["endToEndMs": milliseconds]))
    }
}
