import Foundation

/// ULID generation — all ids are stable ULIDs minted client-side (handoff §4).
/// Crockford base32, 48-bit timestamp + 80 random bits, monotonic within a millisecond.
public enum ULID {

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate(now: Date = Date(), using generator: inout some RandomNumberGenerator) -> String {
        let millis = UInt64(now.timeIntervalSince1970 * 1000)
        var characters: [Character] = []
        characters.reserveCapacity(26)
        // 48-bit timestamp → 10 characters, most significant first.
        for index in stride(from: 45, through: 0, by: -5) {
            characters.append(alphabet[Int((millis >> UInt64(index)) & 0x1F)])
        }
        // 80 random bits → 16 characters.
        for _ in 0..<16 {
            characters.append(alphabet[Int(UInt8.random(in: 0..<32, using: &generator))])
        }
        return String(characters)
    }

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    public static func isValid(_ id: String) -> Bool {
        guard id.count == 26 else { return false }
        guard let first = id.first, "01234567".contains(first) else { return false }
        return id.allSatisfy { alphabet.contains($0) }
    }
}
