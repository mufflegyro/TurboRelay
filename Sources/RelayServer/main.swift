import Foundation
import TurboRelayCore

// Headless TurboRelay server: the same core the menu bar app runs, for loopback conformance
// and testing (tests/e2e.py). TURBORELAY_HOME picks the config/staging home.

let home = RelayHome.ensureDirectories()
let config = RelayConfig.load(home: home)
let service = RelayService(home: home, config: config)
service.onChange = {
    FileHandle.standardError.write(Data("[turbo-relay] \(service.statusSummary())\n".utf8))
}
do {
    try service.start()
} catch {
    FileHandle.standardError.write(Data("[turbo-relay] could not start: \(error)\n".utf8))
    exit(1)
}
print("[turbo-relay] serving on port \(config.port); pairing token \(config.token)")
dispatchMain()
