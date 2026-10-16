import AppKit

@MainActor private enum HubUI {
    static let accent = NSColor(calibratedRed: 0.45, green: 0.58, blue: 1, alpha: 1)
    static func label(_ text: String, size: CGFloat = 14, muted: Bool = false, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.textColor = muted ? .secondaryLabelColor : .labelColor
        return view
    }
    static func stack(_ views: [NSView] = [], horizontal: Bool = false, spacing: CGFloat = 16) -> NSStackView {
        let view = NSStackView(views: views); view.orientation = horizontal ? .horizontal : .vertical
        view.alignment = horizontal ? .centerY : .leading; view.spacing = spacing
        return view
    }
    static func card(_ views: [NSView]) -> NSView {
        let card = NSView(); card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1).cgColor
        card.layer?.cornerRadius = 22
        let stack = stack(views); stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24)
        ])
        return card
    }
    static func full(_ view: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    static func editor(_ label: String, editable: Bool, height: CGFloat) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        text.isEditable = editable; text.isSelectable = true; text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .systemFont(ofSize: 15); text.textColor = .labelColor; text.backgroundColor = scroll.backgroundColor
        text.textContainerInset = NSSize(width: 14, height: 14); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel(label); scroll.documentView = text
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (scroll, text)
    }
}

@MainActor final class SettingsWindow: NSWindow, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {
    enum Page: Int, CaseIterable { case home, history, glossary, settings, usage
        var title: String { ["首頁", "歷史紀錄", "詞庫", "設定", "用量與費用"][rawValue] }
        var symbol: String { ["house", "clock.arrow.circlepath", "text.book.closed", "slider.horizontal.3", "chart.bar"][rawValue] }
    }
    let service = HubUI.label("正在連接本機服務…", muted: true)
    let permissions = HubUI.label("", muted: true)
    var shortcutTitle = ""
    private var recordingMode: RecordingMode = .hold
    private var modeHandler: PopupHandler?
    private let modeHint = HubUI.label("", size:12, muted:true)
    private var shortcutRecorder: ShortcutRecorder!
    private var insights: DictationInsights?
    private var usageReports: [UsageReport] = []
    private let homeWords = HubUI.label("—", size:32, weight:.semibold)
    private let homeSpeed = HubUI.label("—", size:32, weight:.semibold)
    private let homeSaved = HubUI.label("未設定", size:24, weight:.semibold)
    private let homeActivity = HubUI.label("",size:13,muted:true)
    private let insightsStatus = HubUI.label("正在載入統計…",size:12,muted:true)
    private let heatmap = ActivityChart()
    private let trend = ActivityChart()
    private let trendRange = NSSegmentedControl(labels:["7 天","30 天"],trackingMode:.selectOne,target:nil,action:nil)
    private let typingSpeed = NSTextField()
    private let speedStatus = HubUI.label("",size:12,muted:true)
    private let usageRange = NSSegmentedControl(labels:["今日","本月","全部"],trackingMode:.selectOne,target:nil,action:nil)
    private let usageTotal = HubUI.label("—",size:32,weight:.semibold)
    private let usageTokens = HubUI.label("—",size:32,weight:.semibold)
    private let usageMinutes = HubUI.label("—",size:32,weight:.semibold)
    private let usageNote = HubUI.label("正在載入…",size:13,muted:true)
    private let usageBreakdown = HubUI.label("",size:14)
    private let costTrend = ActivityChart()
    private let usageRows = HubUI.stack(spacing:12)
    private var usageLimit = 30
    private var usageMore: NSButton!

    var configurationLoaded: ((PilotConfig) -> Void)?
    private let api: PilotAPI
    private let refreshAction: () -> Void
    private let retryAction: (PilotRun) -> Void
    private let canRetry: () -> Bool
    private let bodyStack = HubUI.stack()
    private let scroll = NSScrollView()
    private let heading = HubUI.label("", size: 38, weight: .bold)
    private let pageSubtitle = HubUI.label("", muted: true)
    private let homeStatus = HubUI.label("", muted: true)
    private let apiKeyField = NSSecureTextField()
    private let cleanupPicker = NSPopUpButton()
    private let apiStatus = HubUI.label("", size:12, muted:true)
    private let keyStatus = HubUI.label("", size:12, muted:true)
    private var apiSaving = false
    private var apiLoaded = false
    private let cleanupIDs = ["gpt-5.4-nano-2026-03-17", "gpt-5.4-mini-2026-03-17"]
    private let models = HubUI.label("尚未取得模型資訊", muted: true)
    private let shortcutHint = HubUI.label("", size: 18, weight: .medium)
    private let loadStatus = HubUI.label("正在載入…", muted: true)
    private let homeCount = HubUI.label("—", size: 32, weight: .semibold)
    private let homeDuration = HubUI.label("—", size: 32, weight: .semibold)
    private let recent = HubUI.stack(spacing: 12)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let resultLabel = HubUI.label("", size: 12, muted: true)
    private let detailTitle = HubUI.label("選擇一筆紀錄", size: 16, weight: .medium)
    private let versions = NSSegmentedControl(labels: ["整理文字", "原始轉錄"], trackingMode: .selectOne, target: nil, action: nil)
    private var detailText: NSTextView!
    private var glossaryText: NSTextView!
    private let glossaryStatus = HubUI.label("正在載入詞庫…", muted: true)
    private var copyButton: NSButton!
    private var retryButton: NSButton!
    private var moreButton: NSButton!
    private var saveButton: NSButton!
    private var nav: [NSButton] = []
    private var pages: [Page: NSView] = [:]
    private var page: Page = .home
    private var handler: PopupHandler!
    private var soundHandler: SoundToggleHandler!
    private var runs: [PilotRun] = []
    private var visibleRuns: [PilotRun] = []
    private var historyRows: [HistoryRow] = []
    private var historyLimit = 50
    private var selectionID: String?
    private var loaded = false
    private var revision = Revision()
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var glossaryLoaded = false
    private var savedGlossary = ""
    private var saving = false
    private var glossaryDirty: Bool { glossaryText.string != savedGlossary }
    private enum HistoryRow { case day(String), run(PilotRun) }

    init(shortcut: Shortcut, recordingMode: RecordingMode, api: PilotAPI, onMode: @escaping (RecordingMode) -> String?, onShortcut: @escaping (Shortcut) -> String?, captureShortcut: @escaping (Bool) -> Bool,
         soundEnabled: Bool, onSound: @escaping (Bool) -> Void,
         microphone: @escaping () -> Void, accessibility: @escaping () -> Void,
         refresh: @escaping () -> Void, history: @escaping () -> Void,
         pending: @escaping () -> Void, testInput: @escaping () -> Void, quit: @escaping () -> Void,
         retry: @escaping (PilotRun) -> Void, canRetry: @escaping () -> Bool) {
        self.api = api; refreshAction = refresh; retryAction = retry; self.canRetry = canRetry
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "keyboardless"; titleVisibility = .hidden; titlebarAppearsTransparent = true
        isReleasedWhenClosed = false; minSize = NSSize(width: 900, height: 620)
        appearance = NSAppearance(named: .darkAqua); backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        delegate = self; setFrameAutosaveName("DexVoiceHub"); center()
        let root = NSView(); contentView = root
        let side = NSView(); side.wantsLayer = true; side.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        side.layer?.cornerRadius = 22
        let brand = HubUI.label("keyboardless", size: 23, weight: .bold)
        let brandDetail = HubUI.label("VOICE TO WORDS", size: 10, muted: true)
        let sideStack = HubUI.stack([brand, brandDetail], spacing: 10)
        sideStack.setCustomSpacing(32, after: brandDetail)
        for item in Page.allCases {
            let button = ActionButton(item.title) { [weak self] in self?.navigate(item) }
            button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.alignment = .left
            button.navigationStyle = true; button.setButtonType(.toggle); button.font = .systemFont(ofSize: 15, weight: .medium)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            HubUI.full(button, in: sideStack); nav.append(button)
        }
        let foot = HubUI.label("個人工作空間\n紀錄保存在這台 Mac", size: 11, muted: true)
        for view in [side, sideStack, foot, scroll] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(side); side.addSubview(sideStack); side.addSubview(foot); root.addSubview(scroll)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), side.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8), side.widthAnchor.constraint(equalToConstant: 210),
            sideStack.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 18), sideStack.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -18),
            sideStack.topAnchor.constraint(equalTo: side.topAnchor, constant: 48),
            foot.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 20), foot.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -18),
            foot.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -24),
            scroll.leadingAnchor.constraint(equalTo: side.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 30), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        bodyStack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(bodyStack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -32),
            bodyStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32)
        ])
        shortcutTitle=shortcut.title;self.recordingMode=recordingMode
        shortcutRecorder=ShortcutRecorder(value:shortcut,save:onShortcut,capture:captureShortcut)
        buildHome(); buildHistory(); buildGlossary(); buildUsage()
        let settingsPage = HubUI.stack()
        let modePicker=NSPopUpButton();modePicker.addItems(withTitles:RecordingMode.allCases.map(\.title))
        modePicker.selectItem(at:RecordingMode.allCases.firstIndex(of:recordingMode) ?? 0)
        modePicker.setAccessibilityLabel("錄音方式")
        let modeStatus=HubUI.label("切換模式：按一下開始，再按一下停止並辨識。單獨修飾鍵放開時確認按一下；Esc 可取消。",size:12,muted:true)
        modeHandler=PopupHandler { [weak self,weak modePicker] index in
            guard let self,RecordingMode.allCases.indices.contains(index) else {return}
            let value=RecordingMode.allCases[index]
            if let error=onMode(value) {
                modePicker?.selectItem(at:RecordingMode.allCases.firstIndex(of:self.recordingMode) ?? 0)
                modeStatus.stringValue=error
            } else {
                self.recordingMode=value;modeStatus.stringValue="已儲存 · \(value.hint) · Esc 可取消"
                self.renderStatus()
            }
        }
        modePicker.target=modeHandler;modePicker.action=#selector(PopupHandler.changed(_:))
        HubUI.full(HubUI.card([HubUI.label("全域快捷鍵", size:16,weight:.semibold),shortcutRecorder,
            HubUI.label("錄音方式",size:14,weight:.semibold),modePicker,modeStatus,
            HubUI.label("若 Typeless 也在執行，請使用不同快捷鍵，避免同時收音。",size:12,muted:true)]),in:settingsPage)
        typingSpeed.placeholderString="例如 40";typingSpeed.setAccessibilityLabel("打字速度，每分鐘字數")
        let storedSpeed=UserDefaults.standard.double(forKey:"typingSpeed")
        typingSpeed.stringValue=storedSpeed>0 ? String(format:"%.0f",storedSpeed) : ""
        HubUI.full(HubUI.card([HubUI.label("估算節省時間",size:16,weight:.semibold),
            HubUI.label("輸入你平常每分鐘打字字數；留白則不顯示省時估算。",size:13,muted:true),typingSpeed,
            ActionButton("儲存打字速度") {[weak self] in self?.saveTypingSpeed()},speedStatus]),in:settingsPage)
        HubUI.full(HubUI.card([HubUI.label("權限與連線", size: 16, weight: .semibold), permissions, service,
            HubUI.stack([ActionButton("允許麥克風", action: microphone), ActionButton("輔助使用設定", action: accessibility),
                         ActionButton("重新檢查") { [weak self] in self?.refreshAction(); self?.reload() }], horizontal: true, spacing: 8)]), in: settingsPage)
        apiKeyField.placeholderString="貼入自己的 OpenAI API Key；留白保留原值"
        apiKeyField.setAccessibilityLabel("OpenAI API 金鑰")
        cleanupPicker.addItems(withTitles:["GPT-5.4 nano（省費用）","GPT-5.4 mini（原設定）"])
        cleanupPicker.setAccessibilityLabel("文字整理模型")
        HubUI.full(HubUI.card([HubUI.label("語音與整理", size: 16, weight: .semibold), models,
            HubUI.label("OpenAI API 金鑰",size:14,weight:.semibold), apiKeyField, keyStatus,
            HubUI.label("文字整理模型 · 語音辨識維持原設定",size:14,weight:.semibold),cleanupPicker,
            HubUI.stack([ActionButton("儲存 API 設定") {[weak self] in self?.saveAPI()},
                         ActionButton("測試已儲存設定") {[weak self] in self?.checkAPI()}],horizontal:true),
            HubUI.stack([ActionButton("將現有金鑰移至 Keychain") {[weak self] in self?.saveAPI(migrate:true)},
                         ActionButton("移除金鑰") {[weak self] in self?.removeAPIKey()}],horizontal:true),apiStatus,
            HubUI.label("金鑰保存在這台 Mac 的 Keychain。連線測試只查模型存取權，不傳送錄音，也不產生文字。",size:12,muted:true),
            HubUI.label("音訊會送至已設定的 OpenAI 服務。英文保留英文，中英夾雜維持原樣。紀錄與詞庫保存在本機。", size: 13, muted: true)]), in: settingsPage)
        HubUI.full(HubUI.card([HubUI.label("進階", size: 16, weight: .semibold),
            HubUI.stack([ActionButton("開啟語音實驗室", action: history), ActionButton("待送出錄音", action: pending)], horizontal: true),
            HubUI.stack([ActionButton("測試填入（不錄音）", action: testInput), ActionButton("退出 keyboardless", action: quit)], horizontal: true),
            HubUI.label("填入測試：八秒內點入文字欄位，再等三秒。此測試不錄音、不呼叫模型。", size: 12, muted: true)]), in: settingsPage)
        let sound = NSSwitch(); sound.state = soundEnabled ? .on : .off
        sound.setAccessibilityLabel("錄音提示音")
        soundHandler = SoundToggleHandler(onSound); sound.target = soundHandler; sound.action = #selector(SoundToggleHandler.changed(_:))
        let soundRow = HubUI.stack([HubUI.label("錄音提示音", size: 16, weight: .semibold), sound], horizontal: true)
        let soundCard = HubUI.card([soundRow, HubUI.label("開始收音時播放提示音；按一下切換模式在停止收音、準備辨識時也會播放。", size: 13, muted: true)])
        settingsPage.insertArrangedSubview(soundCard, at: 1); soundCard.widthAnchor.constraint(equalTo: settingsPage.widthAnchor).isActive = true
        pages[.settings] = settingsPage; navigate(.home)
    }

    private func removeAPIKey() {
        guard canRetry(), !apiSaving else {apiStatus.stringValue="請等目前操作完成。";return}
        let alert=NSAlert();alert.messageText="移除 OpenAI 金鑰？";alert.informativeText="移除後需重新輸入自己的金鑰才能口述；歷史紀錄會保留。"
        alert.addButton(withTitle:"移除");alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn {saveAPI(remove:true)}
    }
    private func saveAPI(remove: Bool = false, migrate: Bool = false) {
        guard canRetry(), !apiSaving else {apiStatus.stringValue="請等目前操作完成。";return}
        let selected=cleanupPicker.indexOfSelectedItem
        guard cleanupIDs.indices.contains(selected) else {return}
        let key=remove || migrate ? "" : apiKeyField.stringValue
        apiKeyField.stringValue=""; apiSaving=true;apiStatus.stringValue="正在儲存…"
        Task { [weak self] in
            guard let self else {return};defer {apiSaving=false}
            do {
                let cfg=try await api.config()
                try await api.savePreferences(cleanup:cleanupIDs[selected],key:key,remove:remove,migrate:migrate,token:cfg.token)
                apiStatus.stringValue=remove ? "金鑰已移除" : "已儲存，下次口述生效"
                apiLoaded=false;reload()
            } catch {apiStatus.stringValue=error.localizedDescription}
        }
    }
    private func checkAPI() {
        guard canRetry(), !apiSaving else {apiStatus.stringValue="請等目前操作完成。";return}
        apiSaving=true;apiStatus.stringValue="正在測試已儲存的金鑰與模型…"
        Task { [weak self] in
            guard let self else {return};defer {apiSaving=false}
            do {let cfg=try await api.config();try await api.checkPreferences(token:cfg.token)
                apiStatus.stringValue="連線成功，帳戶可存取所選模型；實際口述仍依帳戶額度。"
            } catch {apiStatus.stringValue=error.localizedDescription}
        }
    }

    private func buildHome() {
        let page=HubUI.stack(spacing:24)
        let cards=HubUI.stack([HubUI.card([homeWords,HubUI.label("口述字數",muted:true)]),HubUI.card([homeSpeed,HubUI.label("平均每分鐘字數",muted:true)]),HubUI.card([homeSaved,HubUI.label("估算節省時間",muted:true),ActionButton("設定基準") {[weak self] in self?.navigate(.settings)}])],horizontal:true,spacing:12)
        cards.distribution = .fillEqually;cards.alignment = .top
        for card in cards.arrangedSubviews.dropFirst() {card.heightAnchor.constraint(equalTo:cards.arrangedSubviews[0].heightAnchor).isActive=true}
        HubUI.full(cards,in:page)
        heatmap.heatmap=true;heatmap.heightAnchor.constraint(equalToConstant:160).isActive=true
        let activity=HubUI.card([HubUI.label("讓想法成為日常",size:18,weight:.semibold),homeActivity,heatmap,insightsStatus])
        HubUI.full(activity,in:page)
        trendRange.selectedSegment=0;trendRange.target=self;trendRange.action=#selector(changeTrend)
        trend.heightAnchor.constraint(equalToConstant:150).isActive=true
        HubUI.full(HubUI.card([HubUI.stack([HubUI.label("口述趨勢",size:18,weight:.semibold),trendRange],horizontal:true),trend]),in:page)
        homeStatus.font = .systemFont(ofSize:12)
        let key=HubUI.card([HubUI.label("口述快捷鍵",size:13,muted:true),shortcutHint,modeHint])
        let status=HubUI.card([HubUI.label("目前狀態",size:16,weight:.medium),homeStatus])
        let row=HubUI.stack([status,key],horizontal:true,spacing:12);row.distribution = .fillEqually;HubUI.full(row,in:page)
        page.addArrangedSubview(HubUI.stack([HubUI.label("最近紀錄",size:19,weight:.semibold),ActionButton("查看全部") {[weak self] in self?.navigate(.history)}],horizontal:true))
        HubUI.full(recent,in:page);pages[.home]=page
    }
    private func buildUsage() {
        let page=HubUI.stack(spacing:20)
        usageRange.selectedSegment=2;usageRange.target=self;usageRange.action=#selector(changeUsageRange);page.addArrangedSubview(usageRange)
        let cards=HubUI.stack([HubUI.card([usageTotal,HubUI.label("已知估算費用 · USD",muted:true)]),HubUI.card([usageTokens,HubUI.label("已知 token",muted:true)]),HubUI.card([usageMinutes,HubUI.label("辨識分鐘",muted:true)])],horizontal:true,spacing:12)
        cards.distribution = .fillEqually;HubUI.full(cards,in:page);HubUI.full(usageNote,in:page)
        HubUI.full(HubUI.card([usageBreakdown,ActionButton("查看官方價格") {NSWorkspace.shared.open(URL(string:"https://developers.openai.com/api/docs/pricing")!)}]),in:page)
        costTrend.unit="USD";costTrend.heightAnchor.constraint(equalToConstant:160).isActive=true
        HubUI.full(HubUI.card([HubUI.label("每日費用 · 最近最多 30 天",size:18,weight:.semibold),costTrend]),in:page)
        page.addArrangedSubview(HubUI.label("每次呼叫明細",size:19,weight:.semibold));HubUI.full(usageRows,in:page)
        usageMore=ActionButton("載入更多明細") {[weak self] in self?.usageLimit += 30;self?.updateUsage()};page.addArrangedSubview(usageMore)
        pages[.usage]=page
    }
    @objc private func changeTrend(){renderInsights()}
    @objc private func changeUsageRange(){usageLimit=30;updateUsage()}
    private func saveTypingSpeed(){
        let text=typingSpeed.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.isEmpty {UserDefaults.standard.removeObject(forKey:"typingSpeed");speedStatus.stringValue="已關閉省時估算";renderInsights();return}
        guard let value=Double(text),InsightFormat.savedMinutes(words:0,seconds:0,speed:value) != nil else {speedStatus.stringValue="請輸入大於 0、不超過 1000 的字數。";return}
        UserDefaults.standard.set(value,forKey:"typingSpeed");speedStatus.stringValue="已儲存 · 估算不包含後續校正時間";renderInsights()
    }
    private func renderInsights(){
        guard let insights else{return}
        homeWords.stringValue=insights.words.formatted();homeSpeed.stringValue=insights.speed.map{String(format:"%.0f",$0)} ?? "—"
        homeActivity.stringValue="\(insights.count) 次口述   ·   \(Int(insights.seconds)/60) 分 \(Int(insights.seconds)%60) 秒   ·   \(insights.activeDays) 天活躍\n目前連續 \(insights.currentStreak) 天   ·   最長連續 \(insights.longestStreak) 天"
        let speed=UserDefaults.standard.double(forKey:"typingSpeed")
        if let saved=InsightFormat.savedMinutes(words:insights.words,seconds:insights.seconds,speed:speed) {homeSaved.stringValue=String(format:"%.1f 分",saved)} else {homeSaved.stringValue="未設定"}
        homeSaved.toolTip=speed>0 ? "估算：字數 ÷ 每分鐘 \(speed) 字 − 口述時間，最低為零；不含校正耗時。" : "請設定你的打字速度，才能估算。"
        insightsStatus.stringValue=insights.counting+"\n日期採台灣時間。熱圖顯示最近 52 週。"
        heatmap.points=insights.days.map{.init(date:$0.date,value:Double($0.words),detail:"\($0.words) 字 · \($0.count) 次")}
        trend.points=insights.days.suffix(trendRange.selectedSegment==0 ? 7 : 30).map{.init(date:$0.date,value:Double($0.words),detail:"\($0.words) 字")}
    }
    private func updateUsage(){
        guard let report=usageReports.first(where:{$0.period == ["today","month","all"][usageRange.selectedSegment]}) else{return}
        let entries=report.entries
        let unknown=report.unknown
        usageTotal.stringValue=InsightFormat.usd(report.usd)
        usageTokens.stringValue=report.tokens.formatted()
        usageMinutes.stringValue=String(format:"%.2f",report.seconds/60)
        usageNote.stringValue="僅此 App 的已保存呼叫（含測試及重試）；非 OpenAI 帳單。辨識按時間計費，token 主要來自整理。\n涵蓋自 \(report.firstDate ?? "尚無紀錄") · \(unknown == 0 ? "目前區間沒有未知費用" : "另有 \(unknown) 筆用量或費用未知，以上為已知小計")。刪除錄音會保留不含文字的費用紀錄。"
        let input=report.input, output=report.output, cached=report.cached
        let transcribe=report.stages.transcribe.usd, cleanup=report.stages.cleanup.usd
        usageBreakdown.stringValue="辨識 \(InsightFormat.usd(transcribe))  ＋  整理 \(InsightFormat.usd(cleanup))\n輸入 \(input.formatted()) · 其中快取 \(cached.formatted()) · 輸出 \(output.formatted()) tokens\n費用依各筆價格版本估算，不含稅與匯差；快取／推理子集不重複加總。"
        costTrend.points=report.days.suffix(30).map{.init(date:$0.date,value:$0.usd,detail:InsightFormat.usd($0.usd)+($0.unknown>0 ? " · 另有未知費用" : ""))}
        for v in usageRows.arrangedSubviews{usageRows.removeArrangedSubview(v);v.removeFromSuperview()}
        if entries.isEmpty {HubUI.full(HubUI.label("這個區間還沒有 API 用量。",muted:true),in:usageRows)}
        for e in entries.prefix(usageLimit){
            let usage=e.usage.seconds.map{String(format:"%.1f 秒",$0)} ?? e.usage.total.map{"\($0) tokens"} ?? "用量未知"
            HubUI.full(HubUI.card([HubUI.label("\(usageDate(e.startedAt)) · \(e.stage=="transcribe" ? "辨識" : "整理") · \(e.cost.usd.map{InsightFormat.usd($0)} ?? "費用未知")",size:15,weight:.medium),HubUI.label("\(e.model) · \(usage)\n\(e.cost.basis)\n價格核對 \(e.cost.checked) · \(e.origin=="legacy" ? "由既有紀錄回推" : "本次呼叫紀錄")",size:12,muted:true)]),in:usageRows)
        }
        usageMore.isHidden=entries.count<=usageLimit
    }
    private func usageDate(_ text:String)->String {
        let iso=ISO8601DateFormatter();iso.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard let date=iso.date(from:text) ?? ISO8601DateFormatter().date(from:text) else{return String(text.prefix(10))}
        let formatter=DateFormatter();formatter.timeZone=TimeZone(identifier:"Asia/Taipei");formatter.dateFormat="yyyy-MM-dd";return formatter.string(from:date)
    }
    private func buildHistory() {
        let page = HubUI.stack(spacing: 12)
        search.placeholderString = "搜尋原始轉錄或整理文字"; search.delegate = self
        search.setAccessibilityLabel("搜尋歷史紀錄"); HubUI.full(search, in: page)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("record")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.selectionHighlightStyle = .regular
        table.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1); table.intercellSpacing = NSSize(width: 0, height: 6)
        table.setAccessibilityLabel("歷史紀錄列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .noBorder
        list.heightAnchor.constraint(equalToConstant: 220).isActive = true; HubUI.full(list, in: page)
        moreButton = ActionButton("載入更多") { [weak self] in self?.historyLimit += 50; self?.updateHistory() }
        page.addArrangedSubview(HubUI.stack([resultLabel, moreButton], horizontal: true))
        versions.selectedSegment = 0; versions.target = self; versions.action = #selector(versionChanged)
        versions.setAccessibilityLabel("文字版本")
        let editor = HubUI.editor("紀錄文字", editable: false, height: 180); detailText = editor.1
        copyButton = ActionButton("複製文字") { [weak self] in
            guard let self, let run = self.selectedRun, let text = self.displayText(run) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            self.detailTitle.stringValue = "已複製\(self.versions.selectedSegment == 0 ? "整理文字" : "原始轉錄")"
        }
        retryButton = ActionButton("重試這筆") { [weak self] in
            guard let self, let run = self.selectedRun, run.status == "failed", self.canRetry() else { return }
            self.retryAction(run); self.renderStatus()
        }
        let content = HubUI.stack([detailTitle, HubUI.stack([versions, copyButton, retryButton], horizontal: true)])
        HubUI.full(editor.0, in: content); HubUI.full(HubUI.card([content]), in: page)
        pages[.history] = page
    }
    private func buildGlossary() {
        let page = HubUI.stack()
        page.addArrangedSubview(HubUI.label("人名、品牌名、工作術語，讓辨識更懂你的用字。", size: 17, weight: .medium))
        page.addArrangedSubview(HubUI.label("每行一個詞條，最多 300 個；每個最多 100 字。儲存後用於下一次口述。", size: 13, muted: true))
        let editor = HubUI.editor("詞庫，每行一個詞條", editable: true, height: 320)
        glossaryText = editor.1; glossaryText.delegate = self; glossaryText.isEditable = false
        HubUI.full(editor.0, in: page)
        saveButton = ActionButton("儲存詞庫") { [weak self] in self?.saveGlossary() }
        saveButton.bezelColor = HubUI.accent; saveButton.isEnabled = false
        page.addArrangedSubview(HubUI.stack([saveButton, glossaryStatus], horizontal: true))
        pages[.glossary] = page
    }
    func show(page requested: Page? = nil) {
        if let requested { navigate(requested) }
        makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        reload(); renderStatus(); startStatusTimer()
    }
    func navigate(_ destination: Page) {
        shortcutRecorder?.stop()
        page = destination
        for view in bodyStack.arrangedSubviews { bodyStack.removeArrangedSubview(view); view.removeFromSuperview() }
        heading.stringValue = destination == .home ? "說話，不必打字" : destination.title
        pageSubtitle.stringValue = ["把注意力留給想法，其餘交給語音。", "每一次口述，都在這裡。", "保留你慣用的拼字與專有名詞。", "調整成最順手的使用方式。", "每一次口述的用量與支出，都看得見。"][destination.rawValue]
        bodyStack.addArrangedSubview(heading); bodyStack.addArrangedSubview(pageSubtitle)
        let bar = HubUI.stack([loadStatus, ActionButton("重新整理") { [weak self] in self?.refreshAction(); self?.reload() }], horizontal: true)
        HubUI.full(bar, in: bodyStack)
        if let view = pages[destination] { HubUI.full(view, in: bodyStack) }
        for (index, button) in nav.enumerated() { button.state = index == destination.rawValue ? .on : .off; button.contentTintColor = .labelColor; button.needsDisplay = true }
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        renderStatus()
    }
    func renderStatus() {
        homeStatus.stringValue = service.stringValue + "\n" + permissions.stringValue.replacingOccurrences(of: "\n", with: " · ")
        shortcutHint.stringValue = shortcutTitle
        modeHint.stringValue = recordingMode.hint
        retryButton?.isEnabled = selectedRun?.status == "failed" && canRetry()
    }
    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.renderStatus() }
        }
    }
    func windowWillClose(_ notification: Notification) {
        shortcutRecorder?.stop()
        loadTask?.cancel(); _ = revision.next(); statusTimer?.invalidate(); statusTimer = nil
    }
    func reloadIfVisible() { if isVisible { reload() } }
    func reload() {
        loadTask?.cancel(); let request = revision.next(); loadStatus.stringValue = "正在載入…"
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cfg = try await api.config()
                guard !Task.isCancelled, revision.accepts(request) else { return }
                configurationLoaded?(cfg)
                let records = try await api.runs()
                guard !Task.isCancelled, revision.accepts(request) else { return }
                runs = HubRules.matching(records, query: ""); loaded = true
                if let names = cfg.models { models.stringValue = "辨識 · \(names.transcribe)\n整理 · \(names.cleanup)" }
                keyStatus.stringValue="金鑰來源：" + (cfg.keySource ?? "舊版本服務，請重開 App") + (cfg.keychainError == true ? " · Keychain 尚無法存取" : "")
                if !apiLoaded, let names=cfg.models,let index=cleanupIDs.firstIndex(of:names.cleanup) {cleanupPicker.selectItem(at:index);apiLoaded=true}
                if !saving, !glossaryLoaded || !glossaryDirty {
                    if let words = cfg.settings?.glossary {
                        savedGlossary = words.joined(separator: "\n"); glossaryText.string = savedGlossary
                        glossaryLoaded = true; glossaryText.isEditable = true; glossaryStatus.stringValue = "已儲存 · \(words.count) 個詞條"
                    } else { glossaryStatus.stringValue = "服務未提供詞庫，請檢查版本後重新整理。" }
                }
                saveButton.isEnabled = glossaryLoaded && !saving && glossaryDirty
                loadStatus.stringValue = "已更新 · 紀錄保存在這台 Mac"
                updateHome(); updateHistory(); renderStatus()
                do {
                    let stats=try await api.insights()
                    var reports: [UsageReport] = []
                    for period in ["today","month","all"] {reports.append(try await api.usage(period:period))}
                    guard !Task.isCancelled,revision.accepts(request) else{return}
                    insights=stats;usageReports=reports;renderInsights();updateUsage()
                } catch {
                    guard !Task.isCancelled,revision.accepts(request) else{return}
                    insightsStatus.stringValue=error.localizedDescription;usageNote.stringValue=error.localizedDescription
                }
            } catch {
                guard !Task.isCancelled, revision.accepts(request) else { return }
                loadStatus.stringValue = (loaded ? "顯示上次資料 · " : "") + error.localizedDescription
                if !glossaryLoaded { glossaryStatus.stringValue = "詞庫尚未載入，請重新整理。" }
                if !loaded { updateHome(); updateHistory() }
            }
        }
    }
    private func updateHome() {
        let summary = HubSummary(runs)
        homeCount.stringValue = loaded ? String(summary.count) : "—"
        homeDuration.stringValue = loaded ? "\(Int(summary.seconds) / 60) 分 \(Int(summary.seconds) % 60) 秒" : "—"
        for view in recent.arrangedSubviews { recent.removeArrangedSubview(view); view.removeFromSuperview() }
        if runs.isEmpty {
            HubUI.full(HubUI.card([HubUI.label(loaded ? "還沒有口述紀錄" : "紀錄尚未載入", size: 17, weight: .medium),
                HubUI.label(loaded ? "點進文字欄位，用快捷鍵說出第一句話。" : "確認本機服務連線後，按重新整理。", muted: true)]), in: recent)
        }
        for run in runs.prefix(5) {
            let text = (run.cleanText ?? run.rawText ?? run.error ?? "正在處理…").replacingOccurrences(of: "\n", with: " ")
            let button = ActionButton(String(text.prefix(80))) { [weak self] in
                self?.selectionID = run.id; self?.search.stringValue = ""; self?.historyLimit = 50
                self?.updateHistory(); self?.navigate(.history)
            }
            button.alignment = .left; button.lineBreakMode = .byTruncatingTail; button.bezelStyle = .recessed
            HubUI.full(HubUI.card([HubUI.label("\(dateText(run)) · \(statusText(run))", size: 11, muted: true), button]), in: recent)
        }
    }
    private func dateText(_ run: PilotRun, dayOnly: Bool = false) -> String {
        guard let raw = run.createdAt else { return "日期未知" }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return "日期未知" }
        let format = DateFormatter(); format.locale = Locale(identifier: "zh_TW"); format.timeZone = TimeZone(identifier: "Asia/Taipei")
        format.dateFormat = dayOnly ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"; return format.string(from: date)
    }
    private func statusText(_ run: PilotRun) -> String {
        ["done": "已完成", "failed": "未完成", "transcribing": "辨識中", "cleaning": "整理中"][run.status] ?? run.status
    }
    private var selectedRun: PilotRun? { runs.first { $0.id == selectionID } }
    private func displayText(_ run: PilotRun) -> String? { versions.selectedSegment == 0 ? run.cleanText : run.rawText }
    private func updateHistory() {
        let filtered = HubRules.matching(runs, query: search.stringValue)
        visibleRuns = Array(filtered.prefix(historyLimit)); historyRows = []; var day = ""
        for run in visibleRuns {
            let date = dateText(run, dayOnly: true)
            if date != day { historyRows.append(.day(date)); day = date }
            historyRows.append(.run(run))
        }
        table.reloadData()
        if let index = historyRows.firstIndex(where: { if case .run(let run) = $0 { return run.id == selectionID }; return false }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { selectionID = nil; table.deselectAll(nil) }
        resultLabel.stringValue = !loaded ? "尚未載入" : filtered.isEmpty ? "沒有符合的紀錄" : "顯示 \(visibleRuns.count)／\(filtered.count) 筆"
        moreButton.isHidden = visibleRuns.count >= filtered.count; updateDetail()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { historyRows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .day = historyRows[row] { return 28 }; return 58 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .day = historyRows[row] { return false }; return true }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("history-row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id; let label = HubUI.label(""); label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        switch historyRows[row] {
        case .day(let date): cell.textField?.stringValue = date; cell.textField?.textColor = HubUI.accent; cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
        case .run(let run):
            let excerpt = (run.cleanText ?? run.rawText ?? run.error ?? "等待結果…").replacingOccurrences(of: "\n", with: " ")
            cell.textField?.stringValue = "\(dateText(run)) · \(statusText(run))\n\(excerpt.prefix(140))"
            cell.textField?.textColor = .labelColor; cell.textField?.font = .systemFont(ofSize: 13)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if historyRows.indices.contains(row), case .run(let run) = historyRows[row] { selectionID = run.id; versions.selectedSegment = 0 }
        updateDetail()
    }
    @objc private func versionChanged() { updateDetail() }
    private func updateDetail() {
        guard let run = selectedRun else {
            detailTitle.stringValue = "選擇一筆紀錄"; detailText.string = ""; copyButton.isEnabled = false; retryButton.isEnabled = false; return
        }
        detailTitle.stringValue = "\(dateText(run)) · \(statusText(run))"
        let text = displayText(run)
        detailText.string = text ?? run.error ?? "這個版本尚無文字。"
        copyButton.isEnabled = text != nil; retryButton.isEnabled = run.status == "failed" && canRetry()
    }
    func controlTextDidChange(_ obj: Notification) { historyLimit = 50; updateHistory() }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === glossaryText else { return }
        glossaryStatus.stringValue = glossaryDirty ? "尚未儲存" : "已儲存"
        saveButton.isEnabled = glossaryLoaded && !saving && glossaryDirty
    }
    private func saveGlossary() {
        guard glossaryLoaded, !saving else { return }
        let words: [String]
        do { words = try HubRules.glossary(glossaryText.string) }
        catch { glossaryStatus.stringValue = error.localizedDescription; return }
        let draft = glossaryText.string
        saving = true; saveButton.isEnabled = false; glossaryStatus.stringValue = "儲存中…"
        // Invalidate old reads before a write, so an older config cannot overwrite the saved list.
        loadTask?.cancel(); _ = revision.next()
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { saving = false; saveButton.isEnabled = glossaryDirty }
            do {
                let cfg = try await api.config()
                let result = try await api.saveGlossary(words, token: cfg.token)
                savedGlossary = result.glossary.joined(separator: "\n")
                if glossaryText.string == draft { glossaryText.string = savedGlossary }
                glossaryStatus.stringValue = glossaryDirty ? "已儲存送出版本；目前還有新修改" : "已儲存 · \(result.glossary.count) 個詞條"
                loadStatus.stringValue = "詞庫已更新"
            } catch { glossaryStatus.stringValue = "儲存未確認，草稿保留。\(error.localizedDescription)" }
        }
    }
}
@MainActor private final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor private final class SoundToggleHandler: NSObject {
    let callback: (Bool) -> Void
    init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    @objc func changed(_ sender: NSSwitch) { callback(sender.state == .on) }
}
