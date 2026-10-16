import AppKit
import Carbon
import ApplicationServices

@MainActor final class HotKey {
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    var cancelled: (() -> Void)?
    var interrupted: (() -> Void)?
    private var key: EventHotKeyRef?
    private var escape: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var suspended = false { didSet { if suspended { reset() } } }
    private var active = false
    private var chosen: Shortcut?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var modifierState = ModifierCapture()
    private let signature: OSType = 0x44585643
    init() {
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == owner.signature else { return OSStatus(eventNotHandledErr) }
                if id.id == 2 { if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.interrupted?() }; return noErr }
                guard !owner.suspended else { return noErr }
                if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                    if !owner.active { owner.active=true;owner.pressed?() }
                } else if owner.active { owner.active=false;owner.released?() }
                return noErr
            }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) -> Bool {
        guard shortcut.valid else { return false }
        if chosen == shortcut, !shortcut.single || tap.map({CGEvent.tapIsEnabled(tap:$0)}) == true { return true }
        var replacement: EventHotKeyRef?
        var newTap: CFMachPort?
        if shortcut.single {
            guard AXIsProcessTrusted() else {return false}
            let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue)
            newTap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.listenOnly,eventsOfInterest:mask,callback:{ _,type,event,context in
                if let context { MainActor.assumeIsolated {
                    Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().event(type,event)
                } };return Unmanaged.passUnretained(event)
            },userInfo:Unmanaged.passUnretained(self).toOpaque())
            guard newTap != nil else {return false}
        } else {
            guard RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers,
                EventHotKeyID(signature:signature,id:1),GetApplicationEventTarget(),0,&replacement) == noErr else {return false}
        }
        reset()
        if let key {UnregisterEventHotKey(key)};key=replacement
        if let tap {CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)}
        if let source {CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)}
        tap=newTap;source=nil;chosen=shortcut
        if let newTap { source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,newTap,0);CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes);CGEvent.tapEnable(tap:newTap,enable:true) }
        watchdog?.invalidate()
        watchdog=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in Task { @MainActor in
            guard let self,let chosen=self.chosen else{return}
            if let tap=self.tap,!CGEvent.tapIsEnabled(tap:tap) {self.reset();CGEvent.tapEnable(tap:tap,enable:true)}
            if self.active && !CGEventSource.keyState(.combinedSessionState,key:chosen.keyCode) {self.reset()}
            if self.modifierState.held {
                let flags = Shortcut.carbon(NSEvent.ModifierFlags(rawValue:UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)))
                if flags & (Shortcut.masks[chosen.keyCode] ?? 0) == 0 {self.reset()}
            }
        }}
        return true
    }
    func reset(){active=false;modifierState.reset();interrupted?()}
    private func event(_ type:CGEventType,_ event:CGEvent){
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {reset();return}
        guard !suspended,let chosen,chosen.single else{return}
        // Use the flags delivered with this event. Polling global keyState here can
        // observe the state before the event and miss standalone modifier presses.
        switch modifierState.event(keyCode:chosen.keyCode,flags:event.flags.rawValue,otherKey:type == .keyDown) {
        case .begin: pressed?()
        case .end: released?()
        case .cancel: cancelled?()
        case .none: break
        }
    }
    func captureEscape(_ enabled: Bool) {
        if let escape { UnregisterEventHotKey(escape); self.escape = nil }
        if enabled {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: signature, id: 2),
                                GetApplicationEventTarget(), 0, &escape)
        }
    }
}

@MainActor final class TextTarget {
    static var diagnostic: [String: String] = [:]
    let pid: pid_t
    let element: AXUIElement
    let selection: CFRange
    private init(pid: pid_t, element: AXUIElement, selection: CFRange) {
        self.pid = pid; self.element = element; self.selection = selection
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        diagnostic[key + "Error"] = String(result.rawValue)
        guard result == .success else { return nil }
        return value
    }
    private static func focused(pid: pid_t) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func range(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange(); guard AXValueGetValue(ax, .cfRange, &range) else { return nil }; return range
    }
    private static func secure(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }
    static func capture() -> TextTarget? {
        diagnostic = ["trusted": String(AXIsProcessTrusted())]
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        diagnostic["app"] = app.bundleIdentifier ?? "unknown"
        diagnostic["pid"] = String(app.processIdentifier)
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focused(pid: app.processIdentifier) else { return nil }
        diagnostic["role"] = attribute(element, kAXRoleAttribute) as? String
        guard !secure(element), let selection = range(element) else { return nil }
        diagnostic["captured"] = "true"
        return TextTarget(pid: app.processIdentifier, element: element, selection: selection)
    }
    func isCurrent() -> Bool {
        let current = Self.focused(pid: pid)
        let selectionNow = current.flatMap(Self.range)
        Self.diagnostic["sameApp"] = String(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
        Self.diagnostic["sameElement"] = String(current.map { CFEqual($0, element) } ?? false)
        Self.diagnostic["sameSelection"] = String(selectionNow.map { $0.location == selection.location && $0.length == selection.length } ?? false)
        return FocusEvidence(trusted: AXIsProcessTrusted(),
                             sameApp: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                             sameElement: current.map { CFEqual($0, element) } ?? false,
                             sameSelection: selectionNow.map { $0.location == selection.location && $0.length == selection.length } ?? false,
                             secure: current.map(Self.secure) ?? true).mayInsert
    }
    // Returns a precise status; a posted paste event is not proof the receiving app accepted it.
    func insert(_ text: String) -> String? {
        // Chromium can acknowledge AXSelectedText writes without changing the editor.
        // Use one standard paste, never an AX write followed by an uncertain retry.
        guard isCurrent(), let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return nil }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                item.data(forType: type).map { (type, $0) }
            }
        }
        board.clearContents(); board.setString(text, forType: .string)
        let count = board.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        Self.diagnostic["method"] = "clipboardPaste"
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard board.changeCount == count else { return }
            board.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        return "已送出貼上；若未出現，可複製最近結果"
    }
}
