import Foundation

/// GATT layout of the Safely Key. Must match firmware/safely_key/safely_key.ino.
public enum SafelyBLE {
    public static let deviceName = "Shlok Key"
    public static let service = "5AFE0001-7A3C-4B1E-9D2F-C0DE5AFE1A00"
    public static let phoneRx = "5AFE0002-7A3C-4B1E-9D2F-C0DE5AFE1A00"
    public static let phoneTx = "5AFE0003-7A3C-4B1E-9D2F-C0DE5AFE1A00"
    public static let browserRx = "5AFE0004-7A3C-4B1E-9D2F-C0DE5AFE1A00"
    public static let browserTx = "5AFE0005-7A3C-4B1E-9D2F-C0DE5AFE1A00"
    public static let status = "5AFE0006-7A3C-4B1E-9D2F-C0DE5AFE1A00"

    public static let statusPhonePresent: UInt8 = 0x01
    public static let statusBrowserPresent: UInt8 = 0x02

    /// Frame = 3 byte header + payload. 160 fits the 185 byte MTU iOS negotiates.
    public static let frameSize = 160
    public static let frameHeaderSize = 3
}

public enum EnvelopeType: UInt8 {
    /// Unencrypted JSON. Only pairing messages travel this way.
    case plain = 0x01
    /// AES-256-GCM sealed JSON: [type][keyId 8][nonce 12][ciphertext][tag 16]
    case sealed = 0x02
}
