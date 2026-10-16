import Foundation

enum Phase: Equatable { case idle, recording, processing }
enum ShortcutSignal { case pressed, released }
enum CaptureCommand { case none, begin, stop }
enum RecordingMode: String, CaseIterable {
    case hold, toggle
    var title: String { self == .hold ? "按住說話" : "按一下開始／再按一下停止" }
    var hint: String { self == .hold ? "按住說話 · 放開送出" : "按一下開始 · 再按一下停止並送出" }
    var stopHint: String { self == .hold ? "放開快捷鍵送出" : "再按一次快捷鍵送出" }
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .hold
    }
    func command(_ signal: ShortcutSignal, phase: Phase, single: Bool) -> CaptureCommand {
        guard phase != .processing else { return .none }
        if self == .hold {
            if signal == .pressed && phase == .idle { return .begin }
            if signal == .released && phase == .recording { return .stop }
            return .none
        }
        // A standalone modifier must be released without joining a normal chord.
        guard signal == (single ? .released : .pressed) else { return .none }
        return phase == .idle ? .begin : .stop
    }
}
struct CaptureState {
    private(set) var phase: Phase = .idle
    mutating func begin() -> Bool {
        guard phase == .idle else { return false }; phase = .recording; return true
    }
    mutating func release(duration: Double) -> Bool {
        guard phase == .recording else { return false }
        phase = duration >= 0.25 ? .processing : .idle
        return phase == .processing
    }
    mutating func retry() -> Bool {
        guard phase == .idle else { return false }; phase = .processing; return true
    }
    mutating func reset() { phase = .idle }
}
struct FocusEvidence {
    let trusted: Bool
    let sameApp: Bool
    let sameElement: Bool
    let sameSelection: Bool
    let secure: Bool
    var mayInsert: Bool { trusted && sameApp && sameElement && sameSelection && !secure }
}
struct PilotConfig: Decodable {
    let app: String?
    let nativeProtocol: Int?
    let token: String
    let configured: Bool
    let keySource: String?
    let keychainError: Bool?
    let settings: PilotSettings?
    let models: PilotModels?
}
struct PilotSettings: Codable { let glossary: [String] }
struct PilotModels: Decodable { let transcribe: String; let cleanup: String }
struct PilotRun: Decodable {
    let id: String
    let status: String
    let rawText: String?
    let cleanText: String?
    let error: String?
    let failedStage: String?
    let createdAt: String?
    let parentId: String?
    let sourceType: String?
    let duration: Double?
}

struct HubSummary {
    let count: Int
    let seconds: Double
    init(_ runs: [PilotRun]) {
        let completed = runs.filter { $0.sourceType == "real" && $0.status == "done" && $0.parentId == nil }
        count = completed.count
        seconds = completed.reduce(0) { $0 + max(0, $1.duration ?? 0) }
    }
}
enum HubRules {
    static func matching(_ runs: [PilotRun], query: String) -> [PilotRun] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return runs.filter { term.isEmpty || ($0.cleanText ?? "").localizedCaseInsensitiveContains(term) || ($0.rawText ?? "").localizedCaseInsensitiveContains(term) }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }
    static func glossary(_ draft: String) throws -> [String] {
        var words: [String] = []; var seen = Set<String>()
        for line in draft.components(separatedBy: .newlines) {
            let word = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            // Match the server's JavaScript UTF-16 length validation.
            guard word.utf16.count <= 100 else { throw PilotError.message("每個詞條最多 100 字，請縮短過長的詞條。") }
            if seen.insert(word).inserted { words.append(word) }
        }
        guard words.count <= 300 else { throw PilotError.message("詞庫最多 300 個詞條。") }
        return words
    }
}
// Shared by async page loading and overlay dismissal: old work cannot replace new UI.
struct Revision {
    private(set) var value = 0
    mutating func next() -> Int { value += 1; return value }
    func accepts(_ candidate: Int) -> Bool { candidate == value }
}
enum PilotError: LocalizedError {
    case message(String), uncertainUpload
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .uncertainUpload: return "上傳回應不明，請先到歷史確認是否已有結果，避免重複送出。原錄音保留在本機。"
        }
    }
}

struct InsightDay: Decodable { let date: String; let count: Int; let words: Int; let seconds: Double }
struct DictationInsights: Decodable {
    let count: Int; let words: Int; let seconds: Double; let speed: Double?
    let activeDays: Int; let currentStreak: Int; let longestStreak: Int
    let days: [InsightDay]; let counting: String
}
struct UsageTotal: Decodable { let usd: Double; let tokens: Int; let input: Int; let output: Int; let cached: Int; let seconds: Double; let unknown: Int }
struct UsageDay: Decodable { let date: String; let usd: Double; let tokens: Int; let unknown: Int }
struct UsageRecord: Decodable {
    struct Cost: Decodable { let usd: Double?; let basis: String; let source: String; let checked: String }
    struct Tokens: Decodable { let input: Int?; let output: Int?; let cached: Int?; let total: Int?; let seconds: Double? }
    let id: String; let startedAt: String; let stage: String; let model: String; let status: String; let origin: String
    let usage: Tokens; let cost: Cost
}
struct UsageReport: Decodable {
    struct Stages: Decodable { let transcribe: UsageTotal; let cleanup: UsageTotal }
    let period: String; let usd: Double; let tokens: Int; let input: Int; let output: Int; let cached: Int
    let seconds: Double; let unknown: Int; let firstDate: String?; let stages: Stages; let days: [UsageDay]; let entries: [UsageRecord]
}
enum InsightFormat {
    static func usd(_ value: Double) -> String {value > 0 && value < 0.0001 ? "< $0.0001" : String(format:"$%.4f",value)}
    static func savedMinutes(words: Int, seconds: Double, speed: Double) -> Double? {
        guard speed.isFinite, speed > 0, speed <= 1000 else {return nil}
        return max(0,Double(words)/speed-seconds/60)
    }
}
