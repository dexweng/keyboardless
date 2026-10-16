import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem

struct Shortcut: Codable, Equatable {
    var version = 1
    let keyCode: UInt16
    let modifiers: UInt32
    var single: Bool = false
    static let sides: [UInt16: String] = [59:"左 Control",62:"右 Control",58:"左 Option",61:"右 Option",56:"左 Shift",60:"右 Shift",55:"左 Command",54:"右 Command"]
    static let masks: [UInt16: UInt32] = [59:UInt32(controlKey),62:UInt32(controlKey),58:UInt32(optionKey),61:UInt32(optionKey),56:UInt32(shiftKey),60:UInt32(shiftKey),55:UInt32(cmdKey),54:UInt32(cmdKey)]
    static let sideMasks: [UInt16: UInt64] = [59:UInt64(NX_DEVICELCTLKEYMASK),62:UInt64(NX_DEVICERCTLKEYMASK),58:UInt64(NX_DEVICELALTKEYMASK),61:UInt64(NX_DEVICERALTKEYMASK),56:UInt64(NX_DEVICELSHIFTKEYMASK),60:UInt64(NX_DEVICERSHIFTKEYMASK),55:UInt64(NX_DEVICELCMDKEYMASK),54:UInt64(NX_DEVICERCMDKEYMASK)]
    static func sideDown(_ keyCode: UInt16, flags: UInt64) -> Bool {
        flags & (sideMasks[keyCode] ?? 0) != 0
    }
    static let options = [Shortcut(keyCode:49,modifiers:UInt32(controlKey|optionKey)), Shortcut(keyCode:49,modifiers:UInt32(controlKey|shiftKey)), Shortcut(keyCode:49,modifiers:UInt32(cmdKey|optionKey))]
    static let keyNames: [UInt16:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",49:"Space",50:"`",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
    var valid: Bool { version == 1 && (single ? Self.sides[keyCode] != nil && modifiers == 0 : Self.keyNames[keyCode] != nil && modifiers != 0 && modifiers & ~UInt32(controlKey|optionKey|shiftKey|cmdKey) == 0) }
    var title: String {
        if single { return Self.sides[keyCode] ?? "不支援的按鍵" }
        var s=""; for (mask,symbol) in [(controlKey,"⌃"),(optionKey,"⌥"),(shiftKey,"⇧"),(cmdKey,"⌘")] where modifiers & UInt32(mask) != 0 { s += symbol }
        return s + " " + (Self.keyNames[keyCode] ?? "?")
    }
    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result:UInt32=0
        for (flag,mask) in [(NSEvent.ModifierFlags.control,controlKey),(.option,optionKey),(.shift,shiftKey),(.command,cmdKey)] where flags.contains(flag) { result |= UInt32(mask) }
        return result
    }
    static func load(_ defaults: UserDefaults = .standard) -> Shortcut {
        if let data=defaults.data(forKey:"customShortcut"), let value=try? JSONDecoder().decode(Self.self,from:data),value.valid { return value }
        let i=defaults.integer(forKey:"shortcut");return options.indices.contains(i) ? options[i] : options[0]
    }
}
// Side-specific state transitions are separate from event delivery for deterministic tests.
struct ModifierCapture {
    enum Action { case none, begin, end, cancel }
    var held=false
    var blocked=false
    mutating func event(keyCode: UInt16, flags: UInt64, otherKey: Bool) -> Action {
        let down = Shortcut.sideDown(keyCode, flags: flags)
        let otherSides = Shortcut.sideMasks.values.reduce(0, |) & ~(Shortcut.sideMasks[keyCode] ?? 0)
        return update(down: down, otherKey: otherKey || (down && flags & otherSides != 0))
    }
    mutating func update(down: Bool, otherKey: Bool) -> Action {
        if otherKey && (down || held) { blocked=true; if held {held=false;return .cancel};return .none }
        if !down { let wasHeld=held;held=false;blocked=false;return wasHeld ? .end : .none }
        if blocked || held {return .none};held=true;return .begin
    }
    mutating func reset() {held=false;blocked=false}
}

@MainActor final class ShortcutRecorder: NSStackView {
    private let current = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private var monitor: Any?
    private var candidate: Shortcut?
    private var modifierCandidate: UInt16?
    private var chosen: Shortcut
    private let save: (Shortcut) -> String?
    private let capture: (Bool) -> Bool
    private var saveButton: NSButton!
    private var recordButton: NSButton!
    init(value: Shortcut, save: @escaping (Shortcut)->String?, capture: @escaping (Bool)->Bool) {
        chosen=value;self.save=save;self.capture=capture
        super.init(frame:.zero);orientation = .vertical;alignment = .leading;spacing=12
        current.font = .monospacedSystemFont(ofSize:20,weight:.medium);current.stringValue=value.title
        current.setAccessibilityLabel("目前快捷鍵")
        note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor
        addArrangedSubview(current)
        let row=NSStackView();row.spacing=8
        recordButton=ActionButton("錄製快捷鍵") { [weak self] in self?.start() }
        saveButton=ActionButton("儲存") { [weak self] in self?.commit() };saveButton.isEnabled=false
        for b in [recordButton!,saveButton!,ActionButton("取消") { [weak self] in self?.stop() },ActionButton("回復預設") { [weak self] in self?.apply(Shortcut.options[0]) }] {row.addArrangedSubview(b)}
        addArrangedSubview(row);addArrangedSubview(note);note.widthAnchor.constraint(equalTo:widthAnchor).isActive=true
        help()
    }
    required init?(coder: NSCoder) {fatalError()}
    private func help(){ note.stringValue="支援修飾鍵＋一般鍵，或單獨左／右 Control、Option、Shift、Command。錄音方式可在下方切換。Fn／Globe、Caps Lock 不支援。" }
    func stop(){if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil;_ = capture(false);candidate=nil;modifierCandidate=nil;saveButton.isEnabled=false;recordButton.isEnabled=true;current.stringValue=chosen.title;help()}
    private func start(){
        guard capture(true) else {note.stringValue="請等目前口述處理完畢後再設定。";return}
        candidate=nil;modifierCandidate=nil;saveButton.isEnabled=false;recordButton.isEnabled=false;current.stringValue="請按下想使用的快捷鍵…";note.stringValue="放開後檢查組合，再按儲存。Esc 取消。"
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged]) { [weak self] e in
            MainActor.assumeIsolated { self?.accept(e) };return nil
        }
    }
    private func accept(_ e:NSEvent){
        if e.type == .keyDown && e.keyCode == 53 {stop();return}
        if e.type == .keyDown && !e.isARepeat {
            let value=Shortcut(keyCode:e.keyCode,modifiers:Shortcut.carbon(e.modifierFlags));modifierCandidate=nil
            if value.valid {candidate=value;current.stringValue=value.title;saveButton.isEnabled=true} else {candidate=nil;saveButton.isEnabled=false;current.stringValue="不支援此按鍵，請加入修飾鍵再試"}
        } else if e.type == .flagsChanged && candidate == nil {
            if Shortcut.sideDown(e.keyCode,flags:UInt64(e.modifierFlags.rawValue)) {modifierCandidate=e.keyCode}
            else if let code=modifierCandidate, Shortcut.carbon(e.modifierFlags)==0 {
                candidate=Shortcut(keyCode:code,modifiers:0,single:true);current.stringValue=candidate!.title;saveButton.isEnabled=true
            }
        }
    }
    private func commit(){guard let candidate else{return};apply(candidate)}
    private func apply(_ value:Shortcut){
        if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil;_ = capture(false)
        if let error=save(value) {stop();note.stringValue=error} else {chosen=value;stop();note.stringValue="已儲存 · \(value.title)"}
    }
}
