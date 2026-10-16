import AppKit
import Carbon
@main struct ShortcutChecks {
    @MainActor static func main() throws {
        let defaults=UserDefaults(suiteName:"keyboardless-shortcut-tests")!
        defer {defaults.removePersistentDomain(forName:"keyboardless-shortcut-tests")}
        for i in 0..<3 {defaults.set(i,forKey:"shortcut");assert(Shortcut.load(defaults)==Shortcut.options[i])}
        let custom=Shortcut(keyCode:2,modifiers:UInt32(controlKey|optionKey))
        defaults.set(try JSONEncoder().encode(custom),forKey:"customShortcut");assert(Shortcut.load(defaults)==custom)
        assert(!Shortcut(keyCode:2,modifiers:0).valid);assert(!Shortcut(keyCode:53,modifiers:UInt32(controlKey)).valid)
        for code in Shortcut.sides.keys {assert(Shortcut(keyCode:code,modifiers:0,single:true).valid)}
        assert(!Shortcut(keyCode:63,modifiers:0,single:true).valid)
        var state=ModifierCapture()
        assert(state.update(down:false,otherKey:true) == .none)
        assert(state.update(down:true,otherKey:false) == .begin)
        assert(state.update(down:true,otherKey:false) == .none)
        assert(state.update(down:false,otherKey:false) == .end)
        assert(state.update(down:false,otherKey:false) == .none)
        assert(state.update(down:true,otherKey:false) == .begin)
        assert(state.update(down:true,otherKey:true) == .cancel)
        assert(state.update(down:true,otherKey:false) == .none)
        assert(state.update(down:false,otherKey:false) == .none)
        assert(state.update(down:true,otherKey:false) == .begin)
        state.reset();assert(!state.held)
        // Delivered side flags are authoritative even if a global query still says up.
        for code: UInt16 in [59,62,58,61,56,60,55,54] {
            let flag=Shortcut.sideMasks[code]!
            var events=ModifierCapture()
            assert(events.event(keyCode:code,flags:flag,otherKey:false) == .begin)
            assert(events.event(keyCode:code,flags:flag,otherKey:false) == .none)
            assert(events.event(keyCode:code,flags:0,otherKey:false) == .end)
            assert(events.event(keyCode:code,flags:0,otherKey:false) == .none)
            let opposite=Shortcut.sideMasks.first {$0.key != code && Shortcut.masks[$0.key] == Shortcut.masks[code]}!.value
            assert(events.event(keyCode:code,flags:opposite,otherKey:false) == .none)
            assert(events.event(keyCode:code,flags:flag|opposite,otherKey:false) == .none)
            assert(events.event(keyCode:code,flags:0,otherKey:false) == .none)
            assert(events.event(keyCode:code,flags:flag,otherKey:false) == .begin)
            assert(events.event(keyCode:code,flags:flag,otherKey:true) == .cancel)
            assert(events.event(keyCode:code,flags:0,otherKey:false) == .none)
        }
        assert(RecordingMode.load(defaults) == .hold)
        defaults.set("toggle",forKey:"recordingMode");assert(RecordingMode.load(defaults) == .toggle)
        defaults.set("invalid",forKey:"recordingMode");assert(RecordingMode.load(defaults) == .hold)
        for single in [false,true] {
            assert(RecordingMode.hold.command(.pressed,phase:.idle,single:single) == .begin)
            assert(RecordingMode.hold.command(.pressed,phase:.recording,single:single) == .none)
            assert(RecordingMode.hold.command(.released,phase:.recording,single:single) == .stop)
            let trigger:ShortcutSignal=single ? .released : .pressed
            let ignored:ShortcutSignal=single ? .pressed : .released
            assert(RecordingMode.toggle.command(trigger,phase:.idle,single:single) == .begin)
            assert(RecordingMode.toggle.command(ignored,phase:.recording,single:single) == .none)
            assert(RecordingMode.toggle.command(trigger,phase:.recording,single:single) == .stop)
            for mode in RecordingMode.allCases {
                for signal:ShortcutSignal in [.pressed,.released] {assert(mode.command(signal,phase:.processing,single:single) == .none)}
            }
        }
        assert(InsightFormat.savedMinutes(words:100,seconds:60,speed:40)==1.5)
        assert(InsightFormat.savedMinutes(words:1,seconds:60,speed:40)==0)
        assert(InsightFormat.savedMinutes(words:1,seconds:60,speed:0)==nil)
        assert(InsightFormat.savedMinutes(words:1,seconds:60,speed:.infinity)==nil)
        assert(InsightFormat.usd(0.00001)=="< $0.0001")
        let hotkey=HotKey();let original=Shortcut(keyCode:111,modifiers:UInt32(controlKey|optionKey|shiftKey))
        assert(hotkey.register(original))
        var occupied:EventHotKeyRef?
        assert(RegisterEventHotKey(109,UInt32(controlKey|optionKey|shiftKey),EventHotKeyID(signature:0x54455354,id:8),GetApplicationEventTarget(),0,&occupied)==noErr)
        defer{if let occupied {UnregisterEventHotKey(occupied)}}
        assert(!hotkey.register(Shortcut(keyCode:109,modifiers:UInt32(controlKey|optionKey|shiftKey))))
        assert(hotkey.register(original))
        print("PASS: shortcut migration, event side flags, hold/toggle modes, processing guard, typing estimates and occupied shortcut rollback")
    }
}
