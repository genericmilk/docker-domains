import Foundation

/// Small authoritative DNS responder for the reserved .test suffix (RFC 6761).
/// It does not recurse or forward traffic. AAAA/HTTPS queries return NODATA.
public enum DNSMessage {
    public static func response(to data: Data) -> Data? {
        let bytes = Array(data)
        guard bytes.count >= 12, bytes[2] & 0xf8 == 0,
              bytes[4] == 0, bytes[5] == 1 else { return nil }
        var index = 12
        var labels: [String] = []
        while index < bytes.count {
            let length = Int(bytes[index]); index += 1
            if length == 0 { break }
            guard length <= 63, index + length < bytes.count,
                  let label = String(bytes: bytes[index..<index + length], encoding: .ascii) else { return nil }
            labels.append(label.lowercased()); index += length
        }
        guard index + 4 <= bytes.count, index - 12 <= 254 else { return nil }
        let type = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        let dnsClass = UInt16(bytes[index + 2]) << 8 | UInt16(bytes[index + 3])
        let allowed = labels.count >= 2 && labels.last == "test" && dnsClass == 1
        let answer = allowed && type == 1
        var result: [UInt8] = [bytes[0], bytes[1], 0x84 | (bytes[2] & 1), allowed ? 0 : 5,
                               0, 1, 0, answer ? 1 : 0, 0, 0, 0, 0]
        result.append(contentsOf: bytes[12..<index + 4])
        if answer {
            // Name pointer, A, IN, TTL 5 seconds, IPv4 loopback.
            result.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 5, 0, 4, 127, 0, 0, 1])
        }
        return Data(result)
    }
}
