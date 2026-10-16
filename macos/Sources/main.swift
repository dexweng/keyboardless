import AppKit
try MainActor.assumeIsolated {
    let application = NSApplication.shared
    let configURL = Bundle.main.url(forResource: "runtime", withExtension: "json")!
    let runtime = try JSONDecoder().decode(RuntimeConfig.self, from: Data(contentsOf: configURL))
    let delegate = AppDelegate(runtime: runtime)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
