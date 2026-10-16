import AppKit
import AVFoundation
import ApplicationServices

struct RuntimeConfig: Decodable { let projectRoot: String; let nodePath: String }
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, AVAudioRecorderDelegate {
    let runtime: RuntimeConfig
    let api = PilotAPI()
    let hotkey = HotKey()
    let panel = StatusPanel()
    var state = CaptureState()
    var statusItem: NSStatusItem!
    var settings: SettingsWindow!
    var recorder: AVAudioRecorder?
    var startSound: AVAudioPlayer?
    var timer: Timer?
    var testNextInput = false
    var diagnosticTask: Task<Void, Never>?
    var target: TextTarget?
    var pendingAudio: URL?
    var lastRun: PilotRun?
    var lastText: String?
    var uploadUncertain = false
    var backendReady = false
    var keyReady = false
    var shortcut = Shortcut.load()
    var recordingMode = RecordingMode.load()
    var shortcutRegistered = false
    var serviceProcess: Process?
    var operation: Task<Void, Never>?
    var stoppedAt = Date()
    var operationID = UUID()
    var root: URL { URL(fileURLWithPath: runtime.projectRoot) }
    var pendingDir: URL { root.appendingPathComponent(".local/mac-pending") }
    init(runtime: RuntimeConfig) { self.runtime = runtime; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).filter({ $0.processIdentifier != getpid() }).count > 0 {
            NSApp.terminate(nil); return
        }
        try? FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        UserDefaults.standard.register(defaults: ["recordingStartSound": true])
        if let cue = Bundle.main.url(forResource: "recording-start", withExtension: "wav") {
            startSound = try? AVAudioPlayer(contentsOf: cue); startSound?.volume = 0.55; startSound?.prepareToPlay()
        }
        hotkey.pressed = { [weak self] in self?.handleShortcut(.pressed) }
        hotkey.released = { [weak self] in self?.handleShortcut(.released) }
        hotkey.cancelled = { [weak self] in if self?.recordingMode == .hold {self?.cancel()} }
        hotkey.interrupted = { [weak self] in self?.cancel() }
        shortcutRegistered = hotkey.register(shortcut)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "keyboardless")
        statusItem.button?.toolTip = "keyboardless · \(shortcut.title) · \(recordingMode.hint)"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        settings = SettingsWindow(shortcut: shortcut, recordingMode: recordingMode, api: api,
            onMode: { [weak self] value in
                guard let self else {return "App 尚未就緒"}
                guard self.state.phase == .idle, !self.hotkey.suspended else {return "請先結束錄音、處理或快捷鍵錄製，再更改錄音方式。"}
                self.recordingMode=value;UserDefaults.standard.set(value.rawValue,forKey:"recordingMode")
                self.statusItem.button?.toolTip="keyboardless · \(self.shortcut.title) · \(value.hint)"
                return nil
            },
            onShortcut: { [weak self] value in
                guard let self else {return "App 尚未就緒"}
                return self.changeShortcut(value)
            },
            captureShortcut: { [weak self] active in
                guard let self else {return false}
                if active && self.state.phase != .idle {return false}
                self.hotkey.suspended=active;return true
            },
            soundEnabled: UserDefaults.standard.bool(forKey: "recordingStartSound"),
            onSound: { UserDefaults.standard.set($0, forKey: "recordingStartSound") },
            microphone: { [weak self] in self?.requestMicrophone() },
            accessibility: { [weak self] in self?.openAccessibility() },
            refresh: { [weak self] in self?.refresh() },
            history: { [weak self] in self?.openLaboratory() },
            pending: { [weak self] in self?.openPending() },
            testInput: { [weak self] in
                guard let self, self.state.phase == .idle else { return }
                self.diagnosticTask?.cancel()
                self.testNextInput = true
                self.settings.service.stringValue = "八秒後會測試目前文字欄位，不錄音、不呼叫模型。請點選測試欄位。"
                self.settings.orderOut(nil)
                NSApp.hide(nil)
                self.panel.present("請點選要測試的文字欄位", detail: "八秒後記住游標，再等三秒測試填入；不錄音、不呼叫模型。")
                self.diagnosticTask = Task {
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    if self.testNextInput && !Task.isCancelled { self.begin() }
                }
            }, quit: { [weak self] in self?.quit() },
            retry: { [weak self] run in self?.retryHistory(run) },
            canRetry: { [weak self] in self?.state.phase == .idle && self?.uploadUncertain == false })
        settings.configurationLoaded = { [weak self] cfg in
            guard let self else { return }
            self.backendReady = true; self.keyReady = cfg.configured
            self.settings.service.stringValue = cfg.configured ? "本機服務已連線" : "請到設定填入自己的 OpenAI 金鑰。"
            self.refreshPermissions()
        }
        refreshPermissions(); menuNeedsUpdate(menu)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            settings.show(); UserDefaults.standard.set(true, forKey: "onboarded")
        }
        Task { await connect(startIfNeeded: true) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { refreshPermissions(); settings.show(); return true }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, enabled: Bool = true) {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: ""); row.target = self; row.isEnabled = enabled; menu.addItem(row)
        }
        item(state.phase == .recording ? "● 錄音中 · \(recordingMode.stopHint)" : state.phase == .processing ? "正在辨識與整理…" : "\(shortcut.title) · \(recordingMode.hint)", nil, enabled: false)
        menu.addItem(.separator())
        item("開啟 keyboardless…", #selector(showHome))
        item("設定與權限…", #selector(showSettings))
        item("歷史紀錄…", #selector(openHistory))
        item("詞庫…", #selector(showGlossary))
        item("複製最近結果", #selector(copyLast), enabled: lastText != nil)
        item("重試上一筆", #selector(retryLast), enabled: state.phase == .idle && !uploadUncertain && (lastRun?.status == "failed" || (pendingAudio != nil) || lastRun?.status == "transcribing" || lastRun?.status == "cleaning"))
        item("查看待送出錄音…", #selector(openPending))
        item("取消錄音", #selector(cancel), enabled: state.phase == .recording)
        menu.addItem(.separator()); item("退出 keyboardless", #selector(quit))
        refreshPermissions()
    }
    @objc func showHome() { refreshPermissions(); settings.show(page: .home) }
    @objc func showSettings() { refreshPermissions(); settings.show(page: .settings) }
    @objc func showGlossary() { settings.show(page: .glossary) }
    @objc func openHistory() { settings.show(page: .history) }
    func openLaboratory() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:3018")!) }
    @objc func openPending() { NSWorkspace.shared.open(pendingDir) }
    @objc func copyLast() {
        guard let text = lastText else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        panel.present("已複製", detail: "切換到需要的位置，按 Command＋V 貼上。", buttons: [("關閉", { [weak self] in self?.panel.orderOut(nil) })])
    }
    @objc func quit() { cancel(); diagnosticTask?.cancel(); operation?.cancel(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { recorder?.stop(); timer?.invalidate(); hotkey.captureEscape(false) }
    @objc func sleeping() { hotkey.reset(); diagnosticTask?.cancel(); testNextInput = false; cancel(); target = nil }
    func refreshPermissions() {
        guard settings != nil else { return }
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "麥克風已允許"
        case .denied, .restricted: mic = "麥克風未允許，請至系統設定開啟"
        default: mic = "尚未允許麥克風"
        }
        settings.permissions.stringValue = "\(mic)\n\(AXIsProcessTrusted() ? "輔助使用已允許" : "輔助使用未允許（仍可手動複製）")\n\(shortcutRegistered ? "快捷鍵已註冊" : "快捷鍵被占用，請換一組")"
        settings.renderStatus()
    }
    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    func openAccessibility() {
        // The user grants access in System Settings. Never edit the TCC database.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func changeShortcut(_ value: Shortcut) -> String? {
        guard state.phase == .idle else { return "請等口述處理完畢後再設定。" }
        guard hotkey.register(value) else { return "無法使用此快捷鍵。請檢查輔助使用權限或改用其他組合；已保留原設定。" }
        shortcut=value;shortcutRegistered=true
        if let data=try? JSONEncoder().encode(value) {UserDefaults.standard.set(data,forKey:"customShortcut")}
        statusItem.button?.toolTip="keyboardless · \(value.title) · \(recordingMode.hint)"
        settings.shortcutTitle=value.title;refreshPermissions();return nil
    }
    func refresh() { refreshPermissions(); Task { await connect(startIfNeeded: true) } }
    func connect(startIfNeeded: Bool) async {
        defer { settings.renderStatus(); settings.reloadIfVisible() }
        do {
            let cfg = try await api.config(); backendReady = true; keyReady = cfg.configured
            settings.service.stringValue = cfg.configured ? "本機服務已連線 · 可以開始口述" : "請到設定填入自己的 OpenAI 金鑰。"
        } catch {
            backendReady = false
            if startIfNeeded, !(error.localizedDescription.contains("版本不相容")), serviceProcess?.isRunning != true {
                do { try startService() } catch { settings.service.stringValue = "無法啟動服務，請雙擊 start.command 檢查。"; return }
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let cfg = try? await api.config() {
                        backendReady = true; keyReady = cfg.configured
                        settings.service.stringValue = cfg.configured ? "本機服務已連線 · 可以開始口述" : "服務已啟動，請先設定模型金鑰。"; return
                    }
                }
            }
            settings.service.stringValue = error.localizedDescription
        }
    }
    func startService() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: runtime.nodePath)
        // Node's getcwd can block while resolving a privacy-protected Documents ancestor.
        // Use explicit project paths; the same filesystem permissions still apply to each read.
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.arguments = ["--import", root.appendingPathComponent("node_modules/tsx/dist/loader.mjs").path,
                             root.appendingPathComponent("src/server.ts").path, "--port", "3018"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment["KEYBOARDLESS_KEYCHAIN_HELPER"] = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Keychain").path
        process.environment = environment
        let log = root.appendingPathComponent(".local/mac-service.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        process.standardOutput = handle; process.standardError = handle
        try process.run(); try handle.close(); serviceProcess = process
    }
    func handleShortcut(_ signal: ShortcutSignal) {
        guard !hotkey.suspended else {return}
        switch recordingMode.command(signal,phase:state.phase,single:shortcut.single) {
        case .begin: begin()
        case .stop: stop()
        case .none: break
        }
    }
    func begin() {
        guard state.phase == .idle, !hotkey.suspended else { return }
        if testNextInput {
            testNextInput = false; _ = state.retry(); target = TextTarget.capture()
            panel.present("測試填入中…", detail: "不錄音、不呼叫模型；三秒後將檢查原游標。")
            diagnosticTask = Task {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { self.state.reset(); return }
                guard !Task.isCancelled else { self.state.reset(); return }
                self.deliver("keyboardless 測試，keep English。")
                self.state.reset()
            }
            return
        }
        guard backendReady && keyReady else { settings.show(page: .settings); refresh(); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            settings.show(page: .settings); refreshPermissions(); return
        }
        guard state.begin() else { return }
        target = TextTarget.capture(); lastRun = nil; uploadUncertain = false
        let url = pendingDir.appendingPathComponent(UUID().uuidString + ".wav")
        pendingAudio = url
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false
            ])
            recorder.delegate = self; recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else { throw PilotError.message("無法準備麥克風。") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard recorder.record() else { throw PilotError.message("無法開始錄音，請確認麥克風。") }
            self.recorder = recorder; hotkey.captureEscape(true)
            if UserDefaults.standard.bool(forKey: "recordingStartSound") {
                startSound?.currentTime = 0; startSound?.play()
            }
            panel.present("● 正在聆聽", detail: "\(recordingMode.stopHint) · Esc 取消 · 最長 90 秒", recording: true,
                          buttons: [("取消", { [weak self] in self?.cancel() })], recordingHint:recordingMode == .toggle ? "再按停止" : nil)
            statusItem.button?.title = " ●"
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder, self.state.phase == .recording else { return }
                    recorder.updateMeters(); self.panel.updateRecording(seconds: recorder.currentTime, level: pow(10, Double(recorder.averagePower(forChannel: 0)) / 25))
                    if recorder.currentTime >= 90 { self.stop() }
                }
            }
        } catch { cancel(); showError(error.localizedDescription) }
    }
    func stop() {
        guard state.phase == .recording, let recorder else { return }
        let duration = recorder.currentTime
        let shouldSend = state.release(duration: duration)
        startSound?.stop(); recorder.stop(); self.recorder = nil; timer?.invalidate(); timer = nil; hotkey.captureEscape(false)
        statusItem.button?.title = ""
        guard shouldSend else { discardPending(); panel.present("錄音太短", detail: recordingMode.hint + "，請錄下一句完整的話。", buttons: [("關閉", { [weak self] in self?.panel.orderOut(nil) })]); return }
        // Play only after the recorder stops so the cue cannot enter the upload.
        if recordingMode == .toggle && UserDefaults.standard.bool(forKey: "recordingStartSound") {
            startSound?.currentTime = 0; startSound?.play()
        }
        stoppedAt = Date(); process(retry: false)
    }
    @objc func cancel() {
        guard state.phase == .recording else { return }
        state.reset(); startSound?.stop(); recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil
        hotkey.captureEscape(false); target = nil; discardPending(); statusItem?.button?.title = ""; panel.orderOut(nil)
    }
    func discardPending() {
        if let pendingAudio { try? FileManager.default.removeItem(at: pendingAudio) }; pendingAudio = nil
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.cancel(); self.showError("錄音裝置發生錯誤，請檢查麥克風後再試。")
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.state.phase == .recording else { return }
            self.cancel(); self.showError("錄音已意外停止，請檢查麥克風後再試。")
        }
    }
    @objc func retryLast() {
        guard !uploadUncertain, state.retry() else { return }
        target = nil; stoppedAt = Date(); process(retry: true)
    }
    func retryHistory(_ run: PilotRun) {
        guard !uploadUncertain, run.status == "failed", state.retry() else { return }
        // A history retry is never delivered into whichever field is currently focused.
        target = nil; lastRun = run; stoppedAt = Date(); process(retry: true)
    }
    func process(retry: Bool) {
        let id = UUID(); operationID = id
        panel.processing("準備辨識…")
        operation = Task {
            defer { settings.reloadIfVisible() }
            do {
                let cfg = try await api.config()
                guard cfg.configured else { throw PilotError.message("尚未設定模型金鑰，請先設定再重試。") }
                var run: PilotRun
                if retry, let previous = lastRun {
                    let current = try await api.run(previous.id)
                    run = current.status == "failed" ? try await api.retry(current, token: cfg.token) : current
                } else if let pendingAudio {
                    run = try await api.upload(pendingAudio, token: cfg.token)
                    discardPending()
                } else { throw PilotError.message("找不到待處理音訊，請重新錄音。") }
                lastRun = run; UserDefaults.standard.set(run.id, forKey: "lastRunID")
                let deadline = Date().addingTimeInterval(300)
                while run.status == "transcribing" || run.status == "cleaning" {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw PilotError.message("處理仍未完成。可稍後按重試查詢原紀錄，不會重複上傳。") }
                    panel.processing(run.status == "transcribing" ? "辨識中…" : "整理中…")
                    try await Task.sleep(nanoseconds: 500_000_000)
                    run = try await api.run(run.id); lastRun = run
                }
                guard run.status == "done", let text = run.cleanText, !text.isEmpty else {
                    throw PilotError.message(run.error ?? "未取得整理結果，請重試。")
                }
                guard operationID == id, !Task.isCancelled else { return }
                state.reset(); deliver(text)
                await api.timing(run.id, token: cfg.token, milliseconds: Date().timeIntervalSince(stoppedAt) * 1000)
            } catch is CancellationError { state.reset() }
            catch {
                if case PilotError.uncertainUpload = error { uploadUncertain = true }
                state.reset(); target = nil; showError(error.localizedDescription)
            }
        }
    }
    func deliver(_ text: String) {
        lastText = text
        let delivery = target?.insert(text); target = nil
        TextTarget.diagnostic["delivery"] = delivery ?? "manual-copy"
        // Only capability/status metadata; never the dictated or focused text.
        if let data = try? JSONSerialization.data(withJSONObject: TextTarget.diagnostic, options: [.prettyPrinted, .sortedKeys]) {
            let path = root.appendingPathComponent(".local/mac-input-diagnostics.json")
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        if delivery != nil {
            panel.finish()
        } else {
            panel.present("文字已準備好", detail: "原游標位置無法確認，請複製後貼到需要的位置。",
                buttons: [("複製文字", { [weak self] in self?.copyLast() }), ("關閉", { [weak self] in self?.panel.orderOut(nil) })])
        }
    }

    func showError(_ message: String) {
        var buttons: [(String, () -> Void)] = [("查看歷史", { [weak self] in self?.openHistory() })]
        if !uploadUncertain && (lastRun != nil || pendingAudio != nil) { buttons.append(("重試", { [weak self] in self?.retryLast() })) }
        buttons.append(("關閉", { [weak self] in self?.panel.orderOut(nil) }))
        panel.present("這次沒有完成", detail: message, buttons: buttons)
    }
}
