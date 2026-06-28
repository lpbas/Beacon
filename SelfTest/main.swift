import Foundation

// A tiny command-line harness to exercise the dns_sd engine independently of the
// GUI. Compares directly against `dns-sd` so we can confirm parity before wiring UI.
//
//   beacon-selftest browse   <type>                 # list instances for 4s
//   beacon-selftest resolve  <name> <type>          # resolve + print host/port/TXT
//   beacon-selftest register <name> <type> <port>   # advertise a fresh service
//   beacon-selftest mirror   <name> <type>          # resolve then re-broadcast "(Beacon)"

func usage() -> Never {
    print("""
    usage:
      beacon-selftest browse   <type>
      beacon-selftest resolve  <name> <type>
      beacon-selftest register <name> <type> <port>
      beacon-selftest mirror   <name> <type>
    """)
    exit(64)
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

case "register":
    guard args.count == 5, let port = UInt16(args[4]) else { usage() }
    let name = args[2], type = args[3]
    let registrar = ServiceRegistrar()
    let txt = TXT.encode([("beacon", "selftest"), ("path", "/")])
    registrar.register(name: name, type: type, port: port.bigEndian, txt: txt) { state in
        print("register → \(state)")
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
            let mirrorName = "\(name) (Beacon)"
            registrar.register(name: mirrorName, type: type, port: r.port, txt: r.txtData) { state in
                print("register → \(state)")
            }
            print("Re-broadcasting as \"\(mirrorName)\". Verify: dns-sd -B \(type)")
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    holdOpen(seconds: 30)

default:
    usage()
}

dispatchMain()
