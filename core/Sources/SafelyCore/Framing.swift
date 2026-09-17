import Foundation

/// Splits a message into BLE sized frames: [msgId][index][total] + payload.
public enum Chunker {
    public static let maxMessageSize = 255 * (SafelyBLE.frameSize - SafelyBLE.frameHeaderSize)

    public static func split(_ message: Data, msgId: UInt8, frameSize: Int = SafelyBLE.frameSize) -> [Data] {
        let payloadSize = frameSize - SafelyBLE.frameHeaderSize
        let total = max(1, (message.count + payloadSize - 1) / payloadSize)
        guard total <= 255 else { return [] }
        var frames: [Data] = []
        frames.reserveCapacity(total)
        for index in 0..<total {
            let start = message.startIndex + index * payloadSize
            let end = min(start + payloadSize, message.endIndex)
            var frame = Data([msgId, UInt8(index), UInt8(total)])
            frame.append(message[start..<end])
            frames.append(frame)
        }
        return frames
    }
}

/// Rebuilds messages from frames. Frames of one message arrive in order, but frames of
/// different senders may interleave, so partial messages are tracked per msgId.
public final class Reassembler {
    private struct Partial {
        var total: Int
        var parts: [Int: Data]
        var touched: Date
    }

    private var partials: [UInt8: Partial] = [:]
    private let staleAfter: TimeInterval = 30

    public init() {}

    public func feed(_ frame: Data) -> Data? {
        guard frame.count >= SafelyBLE.frameHeaderSize else { return nil }
        let bytes = [UInt8](frame.prefix(SafelyBLE.frameHeaderSize))
        let msgId = bytes[0], index = Int(bytes[1]), total = Int(bytes[2])
        guard total > 0, index < total else { return nil }
        let payload = frame.dropFirst(SafelyBLE.frameHeaderSize)

        let now = Date()
        partials = partials.filter { now.timeIntervalSince($0.value.touched) < staleAfter }

        var partial = partials[msgId] ?? Partial(total: total, parts: [:], touched: now)
        if index == 0 || partial.total != total {
            partial = Partial(total: total, parts: [:], touched: now)
        }
        partial.parts[index] = Data(payload)
        partial.touched = now

        if partial.parts.count == total {
            partials[msgId] = nil
            var message = Data()
            for i in 0..<total { message.append(partial.parts[i]!) }
            return message
        }
        partials[msgId] = partial
        return nil
    }

    public func reset() { partials.removeAll() }
}
