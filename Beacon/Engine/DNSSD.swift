import Foundation
import dnssd

/// Error wrapping a `DNSServiceErrorType` returned by the dns_sd API.
struct DNSSDError: LocalizedError {
    let code: DNSServiceErrorType
    let context: String

    var errorDescription: String? {
        "\(context): \(DNSSDError.message(for: code)) (\(code))"
    }

    static func message(for code: DNSServiceErrorType) -> String {
        switch Int(code) {
        case kDNSServiceErr_NoError: return "No error"
        case kDNSServiceErr_Unknown: return "Unknown error"
        case kDNSServiceErr_NoSuchName: return "No such name"
        case kDNSServiceErr_NoMemory: return "Out of memory"
        case kDNSServiceErr_BadParam: return "Bad parameter"
        case kDNSServiceErr_BadReference: return "Bad reference"
        case kDNSServiceErr_BadState: return "Bad state"
        case kDNSServiceErr_BadFlags: return "Bad flags"
        case kDNSServiceErr_Unsupported: return "Unsupported"
        case kDNSServiceErr_NotInitialized: return "Not initialized"
        case kDNSServiceErr_AlreadyRegistered: return "Already registered"
        case kDNSServiceErr_NameConflict: return "Name conflict"
        case kDNSServiceErr_Invalid: return "Invalid"
        case kDNSServiceErr_Firewall: return "Firewall"
        case kDNSServiceErr_Incompatible: return "Incompatible daemon version"
        case kDNSServiceErr_BadInterfaceIndex: return "Bad interface index"
        case kDNSServiceErr_Refused: return "Refused"
        case kDNSServiceErr_NoSuchRecord: return "No such record"
        case kDNSServiceErr_NoAuth: return "No authentication"
        case kDNSServiceErr_NoSuchKey: return "No such key"
        case kDNSServiceErr_Timeout: return "Timed out"
        default: return "Error \(code)"
        }
    }
}

extension DNSServiceErrorType {
    /// `true` when this is `kDNSServiceErr_NoError`.
    var isOK: Bool { Int(self) == kDNSServiceErr_NoError }
}

/// Helpers for encoding/decoding the on-the-wire DNS-SD TXT record format
/// (a sequence of length-prefixed `key=value` strings).
enum TXT {
    /// Parse a raw TXT record into ordered key/value pairs for display.
    static func parse(_ data: Data) -> [(key: String, value: String)] {
        guard !data.isEmpty else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [(String, String)] in
            guard let base = raw.baseAddress else { return [] }
            let len = UInt16(min(data.count, Int(UInt16.max)))
            let count = TXTRecordGetCount(len, base)
            var pairs: [(String, String)] = []
            var keyBuf = [CChar](repeating: 0, count: 256)
            for i in 0..<count {
                var valueLen: UInt8 = 0
                var valuePtr: UnsafeRawPointer?
                let err = TXTRecordGetItemAtIndex(len, base, i, UInt16(keyBuf.count), &keyBuf, &valueLen, &valuePtr)
                guard err.isOK else { continue }
                let key = String(cString: keyBuf)
                var value = ""
                if let valuePtr, valueLen > 0 {
                    let bytes = UnsafeRawBufferPointer(start: valuePtr, count: Int(valueLen))
                    value = String(decoding: bytes, as: UTF8.self)
                }
                pairs.append((key, value))
            }
            return pairs
        }
    }

    /// Encode key/value pairs into the on-the-wire TXT record format.
    /// Used for registering fresh services; mirrored services round-trip the
    /// raw bytes captured during resolve instead.
    static func encode(_ pairs: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in pairs {
            let entry = Array("\(key)=\(value)".utf8)
            let clipped = entry.prefix(255)
            data.append(UInt8(clipped.count))
            data.append(contentsOf: clipped)
        }
        return data
    }
}

/// Convenience helpers on a Bonjour service type string.
enum ServiceType {
    /// Strip a trailing dot from a regtype/domain returned by the daemon,
    /// e.g. "_hap._tcp." -> "_hap._tcp", "local." -> "local".
    static func trimmingTrailingDot(_ s: String) -> String {
        s.hasSuffix(".") ? String(s.dropLast()) : s
    }
}
