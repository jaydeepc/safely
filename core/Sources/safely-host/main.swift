// safely-host — Chrome native messaging host.
//
// Chrome extensions cannot hold a Bluetooth connection in the background, so this small helper
// does it for them. It is a dumb pipe: it moves opaque envelopes between the extension (stdin/stdout,
// native messaging framing) and the Safely Key (BLE). It holds no keys and cannot read any message.
//
//   extension → host : {"type":"tx","data":"<base64 envelope>"} | {"type":"status?"}
//   host → extension : {"type":"status","bluetooth":"on","key":true,"phone":true,"rssi":-52}
//                      {"type":"rx","data":"<base64 envelope>"}
//
// `safely-host --probe` runs it standalone for 15 s and prints the link state, for troubleshooting.

import Foundation
import SafelyCore

let probeMode = CommandLine.arguments.contains("--probe")

let logURL: URL = {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Safely")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("host.log")
}()

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

let stdoutLock = NSLock()

func post(_ object: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
    if probeMode {
        log("→ \(String(data: body, encoding: .utf8) ?? "")")
        return
    }
    var length = UInt32(body.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    stdoutLock.lock()
    FileHandle.standardOutput.write(header + body)
    stdoutLock.unlock()
}

let link = RelayLink(role: .browser)

func postStatus() {
    var status: [String: Any] = [
        "type": "status",
        "bluetooth": link.state.bluetooth.rawValue,
        "key": link.state.keyConnected,
        "phone": link.state.peerPresent,
    ]
    if let rssi = link.state.rssi { status["rssi"] = rssi }
    post(status)
}

link.onLog = { log("[ble] \($0)") }
link.onState = { _ in postStatus() }
link.onMessage = { envelope in
    post(["type": "rx", "data": envelope.base64EncodedString()])
}
link.start()

func readExactly(_ count: Int) -> Data? {
    var buffer = Data()
    while buffer.count < count {
        let chunk = FileHandle.standardInput.readData(ofLength: count - buffer.count)
        if chunk.isEmpty { return nil }
        buffer.append(chunk)
    }
    return buffer
}

if probeMode {
    log("probe: watching the link for 15 s")
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
} else {
    log("host started by \(CommandLine.arguments.dropFirst().first ?? "?")")
    Thread.detachNewThread {
        while true {
            guard let header = readExactly(4) else { break }
            let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length > 0, length < 4 * 1024 * 1024, let body = readExactly(length) else { break }
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            DispatchQueue.main.async {
                switch type {
                case "tx":
                    if let data = (json["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                        if !link.send(data) { postStatus() }
                    }
                case "status?":
                    postStatus()
                default:
                    break
                }
            }
        }
        log("extension closed the pipe, exiting")
        exit(0)
    }
}

RunLoop.main.run()
