import SwiftUI

@main
struct HelloApp: App {
    init() {
        print("bundle:", Bundle.main.bundleURL.lastPathComponent)
        print("sandboxed:", ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        print("greeting:", Bundle.main.url(forResource: "greeting", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "missing")
        if ProcessInfo.processInfo.arguments.contains("--quit") { exit(0) }
    }

    var body: some Scene {
        WindowGroup { Text("Hello") }
    }
}
