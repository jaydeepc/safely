import CoreBluetooth
import Foundation

/// BLE connection to the Safely Key, used by the iOS app (role .phone) and the native host (role .browser).
///
/// Connects once and then stays attached: a pending `connect` never times out, so the link comes
/// back on its own whenever the key is in range again — on iOS even while the app is suspended.
public final class RelayLink: NSObject {
    public enum Role: String {
        case phone, browser
    }

    public enum Bluetooth: String {
        case unknown, off, unauthorized, unsupported, on
    }

    public struct State: Equatable {
        public var bluetooth: Bluetooth = .unknown
        public var keyConnected = false
        public var peerPresent = false
        public var rssi: Int?
        public init() {}
    }

    public var onState: ((State) -> Void)?
    public var onMessage: ((Data) -> Void)?
    public var onLog: ((String) -> Void)?
    public private(set) var state = State() {
        didSet { if state != oldValue { onState?(state) } }
    }

    private let role: Role
    private let queue: DispatchQueue
    private let restoreIdentifier: String?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?   // we write here
    private var txChar: CBCharacteristic?   // we are notified here
    private var statusChar: CBCharacteristic?

    private let reassembler = Reassembler()
    private var outbox: [Data] = []
    private var writing = false
    private var nextMsgId: UInt8 = 0
    private var rssiTimer: Timer?

    private let serviceUUID = CBUUID(string: SafelyBLE.service)
    private var writeUUID: CBUUID { CBUUID(string: role == .phone ? SafelyBLE.phoneRx : SafelyBLE.browserRx) }
    private var notifyUUID: CBUUID { CBUUID(string: role == .phone ? SafelyBLE.phoneTx : SafelyBLE.browserTx) }
    private let statusUUID = CBUUID(string: SafelyBLE.status)
    private var peerBit: UInt8 { role == .phone ? SafelyBLE.statusBrowserPresent : SafelyBLE.statusPhonePresent }
    private var lastPeripheralKey: String { "safely.lastKey.\(role.rawValue)" }

    public init(role: Role, restoreIdentifier: String? = nil, queue: DispatchQueue = .main) {
        self.role = role
        self.queue = queue
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    public func start() {
        guard central == nil else { return }
        var options: [String: Any] = [:]
        #if os(iOS)
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        #endif
        central = CBCentralManager(delegate: self, queue: queue, options: options)
    }

    /// Queues a whole envelope. Returns false when the key is not connected.
    @discardableResult
    public func send(_ message: Data) -> Bool {
        guard state.keyConnected, rxChar != nil else { return false }
        let frames = Chunker.split(message, msgId: nextMsgId)
        guard !frames.isEmpty else { return false }
        nextMsgId &+= 1
        outbox.append(contentsOf: frames)
        pump()
        return true
    }

    // MARK: - Connection

    private func attach() {
        guard central.state == .poweredOn else { return }
        if let restored = peripheral {  // handed back by iOS state restoration
            adopt(restored)
            return
        }

        if let known = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            adopt(known)
            return
        }
        if let saved = UserDefaults.standard.string(forKey: lastPeripheralKey), let uuid = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            adopt(known)
            // keep scanning too: the key gets a new identifier if it was re-flashed or replaced
        }
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        log("scanning for \(SafelyBLE.deviceName)")
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        if p.state == .connected {
            p.discoverServices([serviceUUID])
        } else {
            central.connect(p, options: nil)
        }
    }

    private func linkLost() {
        rxChar = nil
        txChar = nil
        statusChar = nil
        outbox.removeAll()
        writing = false
        reassembler.reset()
        rssiTimer?.invalidate()
        rssiTimer = nil
        state.keyConnected = false
        state.peerPresent = false
        state.rssi = nil
    }

    private func pump() {
        guard !writing, let p = peripheral, let rx = rxChar, !outbox.isEmpty else { return }
        writing = true
        p.writeValue(outbox.removeFirst(), for: rx, type: .withResponse)
    }

    private func log(_ message: String) { onLog?(message) }
}

extension RelayLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("bluetooth state \(central.state.rawValue), authorization \(CBCentralManager.authorization.rawValue)")
        switch central.state {
        case .poweredOn:
            state.bluetooth = .on
            attach()
        case .poweredOff:
            state.bluetooth = .off
            peripheral = nil
            linkLost()
        case .unauthorized:
            state.bluetooth = .unauthorized
        case .unsupported:
            state.bluetooth = .unsupported
        default:
            state.bluetooth = .unknown
        }
    }

    #if os(iOS)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
        }
    }
    #endif

    public func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let current = peripheral {
            if current.identifier == found.identifier || current.state == .connected { return }
            central.cancelPeripheralConnection(current)  // stale identifier from before a re-flash
        }
        log("found key \(found.identifier.uuidString) rssi=\(RSSI)")
        peripheral = found
        found.delegate = self
        central.connect(found, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier else { return }
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: lastPeripheralKey)
        log("connected, discovering services")
        p.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        log("connect failed: \(error?.localizedDescription ?? "?")")
        peripheral = nil
        attach()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        log("key out of range — waiting for it to come back")
        linkLost()
        central.connect(p, options: nil)  // never times out; fires when the key is near again
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
}

extension RelayLink: CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            log("service missing: \(error?.localizedDescription ?? "not a Shlok Key")")
            central.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([writeUUID, notifyUUID, statusUUID], for: service)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case writeUUID: rxChar = c
            case notifyUUID:
                txChar = c
                p.setNotifyValue(true, for: c)
            case statusUUID:
                statusChar = c
                p.setNotifyValue(true, for: c)
                p.readValue(for: c)
            default: break
            }
        }
        guard rxChar != nil, txChar != nil else {
            log("characteristics missing")
            central.cancelPeripheralConnection(p)
            return
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == notifyUUID, c.isNotifying else { return }
        state.keyConnected = true
        log("link ready (mtu payload \(p.maximumWriteValueLength(for: .withResponse)))")
        if let statusChar { p.readValue(for: statusChar) }
        p.readRSSI()
        rssiTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak p] _ in p?.readRSSI() }
        RunLoop.main.add(timer, forMode: .common)
        rssiTimer = timer
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let value = c.value else { return }
        if c.uuid == statusUUID {
            state.peerPresent = ((value.first ?? 0) & peerBit) != 0
        } else if c.uuid == notifyUUID, let message = reassembler.feed(value) {
            onMessage?(message)
        }
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        writing = false
        if let error {
            log("write failed: \(error.localizedDescription)")
            outbox.removeAll()
            return
        }
        pump()
    }

    public func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { state.rssi = RSSI.intValue }
    }
}
