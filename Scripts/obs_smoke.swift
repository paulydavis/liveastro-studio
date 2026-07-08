// obs_smoke.swift — headless real-connection smoke test for the OBS layer.
//
// Connects to a LIVE OBS instance on localhost:4455, exercising the real
// URLSession WebSocket socket + obs-websocket 5.x auth handshake against the
// running server (which unit tests deliberately never touch). It prints the
// controller state, the scene list, and the server's obsVersion, then starts
// and stops the stream so you can watch OBS's stream indicator flip on and off.
//
// ── Build + run (manual; requires OBS running with the WebSocket server on) ──
//
//   swift build -c release \
//   && xcrun swiftc Scripts/obs_smoke.swift \
//        -I .build/release/Modules \
//        .build/release/LiveAstroCore.build/*.o \
//        -framework Network \
//        -o /tmp/obs_smoke \
//   && /tmp/obs_smoke "<OBS_WEBSOCKET_PASSWORD>"
//
// Pass an empty string ("") for the password if OBS auth is disabled.
//
// Expected against a stock OBS 32.x: connects, lists the scene "Scene",
// reports the OBS version (e.g. 32.1.2), and the stream indicator in OBS turns
// on for ~3 s then off.
//
// NOTE: this program connects to real OBS and starts a real stream — do NOT run
// it during a live broadcast/presentation.

import Foundation
import LiveAstroCore

// MARK: - Arguments

// argv[1] is the OBS WebSocket password ("" if auth is disabled).
let password = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

let host = "localhost"
let port = 4455

// MARK: - Smoke run

// Everything OBS-facing is @MainActor-isolated (OBSController/OBSClient), so run
// the whole flow on the main actor and block the main thread until it finishes.
@MainActor
func run() async -> Int32 {
    let controller = OBSController()
    controller.onLog = { print("  [obs] \($0)") }

    print("Connecting to ws://\(host):\(port) …")
    let ok = await controller.connect(host: host, port: port,
                                      password: password.isEmpty ? nil : password)
    guard ok else {
        print("FAIL: could not connect (state=\(controller.state)). " +
              "Is OBS running with Tools → WebSocket Server enabled, and the password correct?")
        return 1
    }

    print("Connected. state = \(controller.state)")

    // Seed + print the scene list.
    await controller.refreshScenes()
    print("Scenes (\(controller.sceneNames.count)): \(controller.sceneNames)")
    if let current = controller.currentScene {
        print("Current program scene: \(current)")
    }

    // Fetch the server version directly via a GetVersion request. The controller
    // doesn't surface obsVersion, so use a short-lived client on its own socket.
    let versionClient = OBSClient(socket: URLSessionOBSSocket())
    do {
        guard let versionURL = URL(string: "ws://\(host):\(port)") else {
            print("obsVersion: unavailable (bad URL)")
            return 1
        }
        try await versionClient.connect(url: versionURL,
                                        password: password.isEmpty ? nil : password)
        let versionData = try await versionClient.request("GetVersion", data: nil)
        let obsVersion = versionData["obsVersion"] as? String ?? "?"
        let wsVersion = versionData["obsWebSocketVersion"] as? String ?? "?"
        print("obsVersion: \(obsVersion)  (obs-websocket \(wsVersion))")
        await versionClient.disconnect()
    } catch {
        print("obsVersion: unavailable (\(error))")
    }

    // Stream on → wait 3 s → stream off.
    print("Starting stream…")
    await controller.startStream()
    print("state = \(controller.state) — streaming for 3 s")
    try? await Task.sleep(nanoseconds: 3_000_000_000)

    print("Stopping stream…")
    await controller.stopStream()
    print("state = \(controller.state)")

    controller.disconnect()
    print("Done.")
    return 0
}

let exitCode = await run()
exit(exitCode)
