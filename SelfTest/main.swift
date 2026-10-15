import Foundation
import Network

// A tiny command-line harness to exercise the dns_sd engine independently of the
// GUI. It compiles the real engine and model layer, so these commands are also the
// regression tests for the parts of Beacon that have no unit tests.
//
//   beacon-selftest browse   <type>                 # list instances for 4s
//   beacon-selftest resolve  <name> <type>          # resolve + print host/port/TXT
//   beacon-selftest register <name> <type> <port>   # advertise a fresh service
//   beacon-selftest mirror   <name> <type>          # resolve then re-broadcast the same name
//   beacon-selftest interfaces                      # which interface we publish on
//   beacon-selftest rename-probe <name> <type> [interfaceIndex] [rounds]
//                                                   # stop/register cycles; reports renaming
//   beacon-selftest engine [seconds]                # run the real engine on the real config

func usage() -> Never {
    print("""
    usage:
      beacon-selftest browse   <type>
      beacon-selftest resolve  <name> <type>
      beacon-selftest register <name> <type> <port>
      beacon-selftest mirror   <name> <type>
      beacon-selftest interfaces
      beacon-selftest rebind <name> <type> <firstIndex> <secondIndex>
    beacon-selftest rename-probe <name> <type> [interfaceIndex] [rounds]
      beacon-selftest engine [seconds]

    interfaceIndex 0 (the default) publishes on every interface the daemon is on,
    which is what Beacon 1.0 did; `interfaces` prints the LAN-facing index.

    `rebind` moves a live registration from one interface to another and holds it
    open so you can confirm the old interface is released:
      dns-sd -B <type>
    """)
    exit(64)
}

// `Store` calls `remove(atOffsets:)` and `move(fromOffsets:toOffset:)`, which come
// from SwiftUI (for `onDelete`/`onMove`). The app links SwiftUI; this CLI does not,
// so mirror just those two helpers for the model layer it compiles. Behaviour
// matches SwiftUI's, including `toOffset` referring to the pre-removal array.
extension Array where Element == WhitelistEntry {
    mutating func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where indices.contains(index) { remove(at: index) }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[$0] }
        var remaining = self
        for index in source.sorted(by: >) where remaining.indices.contains(index) { remaining.remove(at: index) }
        let insertAt = Swift.min(Swift.max(destination - source.filter { $0 < destination }.count, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        self = remaining
    }
}

/// Collects the first path the monitor reports, so the CLI can use the same
/// interface-selection rule as the app.
final class PathBox {
    private let lock = NSLock()
    private var value: NWPath?

    /// Returns true when this was the first path seen.
    @discardableResult
    func first(_ path: NWPath) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return false }
        value = path
        return true
    }

    var path: NWPath? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func currentPath(timeout: TimeInterval = 2) -> NWPath? {
    let box = PathBox()
    let monitor = NWPathMonitor()
    let ready = DispatchSemaphore(value: 0)
    monitor.pathUpdateHandler = { path in
        if box.first(path) { ready.signal() }
    }
    monitor.start(queue: DispatchQueue(label: "beacon.selftest.path"))
    _ = ready.wait(timeout: .now() + timeout)
    monitor.cancel()
    return box.path
}

func describe(_ path: NWPath) {
    print("path status: \(path.status)")
    for interface in path.availableInterfaces {
        let candidate = LanInterfaces.isLanCandidate(interface) ? "LAN candidate" : "skipped"
        print("  • \(interface.name)  index \(interface.index)  type \(interface.type)  [\(candidate)]")
    }
    if let primary = LanInterfaces.primary(from: path) {
        print("publishing on: \(primary.description)")
    } else {
        print("publishing on: all interfaces (no LAN-facing interface with an address)")
    }
}

func describe(_ state: ServiceRegistrar.State) -> String {
    switch state {
    case .idle: return "idle"
    case .registering: return "registering"
    case .registered(let name): return "registered as \(name)"
    case .failed(let message): return "failed: \(message)"
    }
}

func describe(_ state: ServiceRunState) -> String {
    switch state {
    case .stopped: return "stopped"
    case .resolving: return "resolving"
    case .broadcasting(let type, let host, let port): return "broadcasting as \(type) → \(host):\(port)"
    case .retrying(let message, let attempt): return "retrying (attempt \(attempt)): \(message)"
    case .failed(let message): return "failed: \(message)"
    }
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so callback output isn't lost on exit

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }
let command = args[1]

func holdOpen(seconds: TimeInterval, then message: String = "done") {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print(message)
        exit(0)
    }
}

switch command {
case "browse":
    guard args.count == 3 else { usage() }
    let type = args[2]
    let browser = ServiceBrowser()
    browser.start(types: [type])
    print("Browsing \(type) for 4s…")
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        for s in browser.services { print("  • \(s.name)  [\(s.serviceType) @ \(s.resolveDomain)]") }
        print("Total: \(browser.services.count)")
        exit(0)
    }

case "resolve":
    guard args.count == 4 else { usage() }
    let name = args[2], type = args[3]
    Task {
        do {
            let r = try await ServiceResolver.resolve(name: name, type: type)
            print("Resolved \"\(name)\"")
            print("  host: \(r.hostTarget)")
            print("  port: \(r.displayPort)")
            for (k, v) in r.txtPairs { print("  TXT  \(k)=\(v)") }
            exit(0)
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

case "interfaces":
    guard let path = currentPath() else {
        print("No network path reported")
        exit(1)
    }
    describe(path)
    exit(0)

case "register":
    guard args.count == 5, let port = UInt16(args[4]) else { usage() }
    let name = args[2], type = args[3]
    let registrar = ServiceRegistrar()
    let txt = TXT.encode([("beacon", "selftest"), ("path", "/")])
    registrar.register(name: name, type: type, port: port.bigEndian, txt: txt) { state in
        print("register → \(describe(state))")
    }
    print("Advertising \"\(name)\" (\(type)) on port \(port). Verify: dns-sd -B \(type)")
    holdOpen(seconds: 30)

case "mirror":
    guard args.count == 4 else { usage() }
    let name = args[2], type = args[3]
    let registrar = ServiceRegistrar()
    Task {
        do {
            let r = try await ServiceResolver.resolve(name: name, type: type)
            print("Resolved \"\(name)\" → \(r.hostTarget):\(r.displayPort), \(r.txtPairs.count) TXT entries")
            let index = currentPath().flatMap { LanInterfaces.primary(from: $0)?.index } ?? 0
            print("Re-broadcasting the same instance name on interface \(index) (0 = all interfaces)")
            registrar.register(name: name, type: type, port: r.port, txt: r.txtData, interfaceIndex: index) { state in
                print("register → \(describe(state))")
            }
            print("Verify with: dns-sd -B \(type)   (the instance name must not gain a \"(2)\")")
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    holdOpen(seconds: 30)

case "rebind":
    guard args.count == 6 else { usage() }
    let name = args[2], type = args[3]
    guard let first = UInt32(args[4]), let second = UInt32(args[5]) else { usage() }
    let rebindRegistrar = ServiceRegistrar()
    print("Registering \"\(name)\" on interface \(first), moving to \(second) after 6s.")
    print("Watch it with: dns-sd -B \(type)  (after the move, only interface \(second) should list it)")
    rebindRegistrar.register(name: name, type: type,
                             port: UInt16(8080).bigEndian,
                             txt: TXT.encode([("beacon", "selftest")]),
                             interfaceIndex: first) { state in
        print("register → \(describe(state))")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        print("moving to interface \(second)")
        rebindRegistrar.updateInterface(second)
    }
    holdOpen(seconds: 30)

case "rename-probe":
    guard args.count >= 4 else { usage() }
    let name = args[2], type = args[3]
    let interfaceIndex = args.count >= 5 ? (UInt32(args[4]) ?? 0) : 0
    let rounds = args.count >= 6 ? (Int(args[5]) ?? 3) : 3
    let registrar = ServiceRegistrar()
    var names: [String] = []

    func round(_ index: Int) {
        if index > rounds {
            let renamed = names.filter { $0 != name }
            print("requested: \"\(name)\"")
            print("registered: \(names.map { "\"\($0)\"" }.joined(separator: ", "))")
            if renamed.isEmpty {
                print("RESULT: no renaming across \(rounds) stop/register cycles")
                exit(0)
            } else {
                print("RESULT: daemon renamed the registration \(renamed.count) time(s) — the name is already taken on interface \(interfaceIndex)")
                exit(1)
            }
        }
        var settled = false
        registrar.register(name: name, type: type, port: UInt16(8080).bigEndian,
                           txt: TXT.encode([("beacon", "selftest")]),
                           interfaceIndex: interfaceIndex) { state in
            switch state {
            case .registered(let finalName):
                guard !settled else { return }
                settled = true
                names.append(finalName)
                print("round \(index): registered as \"\(finalName)\"")
                // Stop and immediately register again: the teardown must release the
                // instance name before the next registration probes for it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    registrar.stop()
                    round(index + 1)
                }
            case .failed(let message):
                guard !settled else { return }
                settled = true
                print("round \(index): FAILED \(message)")
                exit(2)
            case .registering, .idle:
                break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard !settled else { return }
            settled = true
            print("round \(index): no reply within 5s")
            exit(3)
        }
    }
    round(1)

case "engine":
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 20) : 20
    Task { @MainActor in
        let store = Store()
        let engine = BroadcastEngine(store: store)
        print("config: \(store.entries.count) whitelist entr(ies), auto-refresh \(store.settings.autoRefreshMinutes) min, start delay \(store.settings.startDelaySeconds)s")
        engine.startAll()
        var lastSeen: [UUID: String] = [:]
        var lastInterface: UInt32 = .max
        let started = Date()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if lastInterface != engine.broadcastInterfaceIndex {
                lastInterface = engine.broadcastInterfaceIndex
                print("  publishing on interface \(lastInterface)\(lastInterface == 0 ? " (all interfaces)" : "")")
            }
            for entry in store.entries {
                let text = describe(engine.runState(for: entry.id))
                guard lastSeen[entry.id] != text else { continue }
                lastSeen[entry.id] = text
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "  %6.2fs  %@ → %@", elapsed, entry.instanceName, text))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("stopping (withdrawing registrations)")
        engine.stopAll()
        try? await Task.sleep(for: .milliseconds(800))
        exit(0)
    }

default:
    usage()
}

dispatchMain()
