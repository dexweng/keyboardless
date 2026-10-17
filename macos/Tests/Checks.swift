import Foundation
@main struct Checks {
    static func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
    }
    static func main() async throws {
        var state = CaptureState()
        require(state.begin(), "first key down starts")
        require(!state.begin(), "repeated key down does not restart")
        require(state.release(duration: 1), "key up submits")
        require(!state.release(duration: 1), "repeated key up does not submit")
        require(!state.begin(), "processing blocks next recording")
        state.reset(); require(state.begin(), "new recording after completion")
        require(!state.release(duration: 0.1) && state.phase == .idle, "short recording discarded")
        require(state.begin(), "start before cancel"); state.reset()
        require(!state.release(duration: 10), "cancelled key up does not submit")
        require(state.retry(), "explicit retry starts processing"); require(!state.retry(), "duplicate retry blocked")
        for bits in 0..<32 {
            let evidence = FocusEvidence(trusted: bits & 1 != 0, sameApp: bits & 2 != 0, sameElement: bits & 4 != 0,
                                         sameSelection: bits & 8 != 0, secure: bits & 16 != 0)
            require(evidence.mayInsert == (bits == 15), "focus guard combination \(bits)")
        }
        print("PASS: capture transitions and all 32 focus guards")
        guard CommandLine.arguments.count > 1 else { return }
        let api = PilotAPI(base: URL(string: CommandLine.arguments[1])!)
        let cfg = try await api.config(); require(cfg.configured, "configured")
        let foreign = PilotAPI(base: api.base, expectedInstance: "different-launch")
        do { _ = try await foreign.config(); fatalError("foreign service accepted") }
        catch PilotError.message(let message) { require(message.contains("占用"), "foreign service is rejected") }
        require(cfg.models?.cleanup == "fixture-cleanup", "model names decoded")
        do { _ = try await api.insights(); fatalError("old service accepted as insights") } catch PilotError.message(let message) { require(message.contains("新版本機服務"), "old service has useful insights message") }
        do { _ = try await api.usage(); fatalError("old service accepted as usage") } catch PilotError.message(let message) { require(message.contains("新版本機服務"), "old service has useful usage message") }
        let partial = PilotAPI(base: URL(string:CommandLine.arguments[1]+"/partial")!)
        do { _ = try await partial.insights(); fatalError("partial insights accepted") } catch PilotError.message {}
        do { _ = try await partial.usage(); fatalError("partial usage accepted") } catch PilotError.message {}
        print("PASS: old service and missing analytics fields handled safely")
        let records = try await api.runs()
        let summary = HubSummary(records)
        require(summary.count == 2 && summary.seconds == 17.5, "exclude scripted, failed and retry records")
        require(HubRules.matching(records, query: "ENGLISH").count == 2, "case insensitive bilingual search and long text")
        require(HubRules.matching(records, query: "原始").count == 1, "search raw transcript")
        require(HubRules.matching(records, query: "absent").isEmpty, "empty search results")
        require(records.last?.cleanText?.count == 22000, "long text preserved")
        let emptyAPI = PilotAPI(base: URL(string: CommandLine.arguments[1] + "/empty")!)
        let empty = try await emptyAPI.runs(); require(empty.isEmpty && HubSummary(empty).count == 0, "empty history")
        let words = try HubRules.glossary(" OpenAI \n\nOpenAI\n中英夾雜\r\n")
        require(words == ["OpenAI", "中英夾雜"], "glossary trim and deduplicate")
        do { _ = try HubRules.glossary(String(repeating: "a", count: 101)); fatalError("long term accepted") } catch PilotError.message {}
        do { _ = try HubRules.glossary((0...300).map(String.init).joined(separator: "\n")); fatalError("too many terms accepted") } catch PilotError.message {}
        let saved = try await api.saveGlossary(words, token: cfg.token)
        let reloaded = try await api.config()
        require(saved.glossary == words && reloaded.settings?.glossary == words, "glossary read back")
        let failureAPI = PilotAPI(base: URL(string: CommandLine.arguments[1] + "/failure")!)
        do { _ = try await failureAPI.runs(); fatalError("failed list accepted") } catch PilotError.message {}
        do { _ = try await failureAPI.saveGlossary(words, token: cfg.token); fatalError("failed save accepted") } catch PilotError.message {}
        do { _ = try await api.saveGlossary(words, token: "wrong"); fatalError("write without token accepted") } catch PilotError.message {}
        var revision = Revision(); let stale = revision.next(); let current = revision.next()
        require(!revision.accepts(stale) && revision.accepts(current), "stale load and dismissal ignored")
        print("PASS: hub history, statistics, search, long text, glossary validation/readback/errors and stale revisions")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("native-contract-test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let run = try await api.upload(file, token: cfg.token)
        require(run.status == "transcribing", "upload accepted once")
        let failed = try await api.run(run.id); require(failed.failedStage == "cleanup", "failure stage decoded")
        let retried = try await api.retry(failed, token: cfg.token)
        require(retried.cleanText == "Keep English，保留中文。", "mixed result decoded")
        await api.timing(retried.id, token: cfg.token, milliseconds: 1234)
        print("PASS: native multipart, polling, cleanup-only retry, mixed-language result and timing")
        do { _ = try await api.upload(file, token: cfg.token); fatalError("busy response accepted") }
        catch PilotError.message(let text) { require(text.contains("正在處理"), "busy response shown") }
        do { _ = try await api.upload(file, token: cfg.token); fatalError("malformed acceptance accepted") }
        catch PilotError.uncertainUpload { print("PASS: malformed upload acceptance requires history check") }
        let redirect = PilotAPI(base: URL(string: CommandLine.arguments[1] + "/redirect")!)
        do { _ = try await redirect.config(); fatalError("redirect followed") }
        catch PilotError.message { print("PASS: redirect refused") }
    }
}
