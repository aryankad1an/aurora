import Foundation
import MachO

/// The entitlements the app was signed with, read from its own code signature.
///
/// iOS has no public call for this, and some frameworks don't fail politely
/// without theirs: Foundation Models stops the app with an assertion when a
/// request goes to Private Cloud Compute from an app without Apple's managed
/// entitlement. Reading the signature lets the app check before it asks.
enum Entitlements {
    /// The keys in the signature's entitlements, or empty when they can't be read.
    static let keys: Set<String> = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let plist = entitlementsPlist(in: data),
              let dictionary = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        else { return [] }
        return Set(dictionary.keys)
    }()

    /// Whether Apple has granted the app use of Private Cloud Compute. The key is
    /// matched loosely, since Apple names it when the request is approved.
    static var allowsPrivateCloudCompute: Bool {
        keys.contains { key in
            let folded = key.lowercased().replacingOccurrences(of: "-", with: "")
            return folded.contains("privatecloudcompute")
        }
    }

    /// The entitlements XML inside a thin 64-bit Mach-O's code signature.
    static func entitlementsPlist(in data: Data) -> Data? {
        func little(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
        }
        func big(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
        }
        guard little(0) == MH_MAGIC_64, let commands = little(16) else { return nil }

        // Find LC_CODE_SIGNATURE among the load commands.
        var cursor = MemoryLayout<mach_header_64>.size
        var signature: (offset: Int, size: Int)?
        for _ in 0..<commands {
            guard let command = little(cursor), let size = little(cursor + 4), size > 0 else { return nil }
            if command == UInt32(LC_CODE_SIGNATURE), let offset = little(cursor + 8), let length = little(cursor + 12) {
                signature = (Int(offset), Int(length))
                break
            }
            cursor += Int(size)
        }
        guard let signature, signature.offset + signature.size <= data.count else { return nil }

        // The signature is a superblob of blobs, all big-endian; slot 5 holds the
        // entitlements as an XML property list.
        let superblob = signature.offset
        guard big(superblob) == 0xFADE_0CC0, let count = big(superblob + 8) else { return nil }
        for index in 0..<Int(count) {
            let entry = superblob + 12 + index * 8
            guard let slot = big(entry), let offset = big(entry + 4) else { return nil }
            guard slot == 5 else { continue }
            let blob = superblob + Int(offset)
            guard big(blob) == 0xFADE_7171, let length = big(blob + 4), length >= 8,
                  blob + Int(length) <= data.count else { return nil }
            return data.subdata(in: (blob + 8)..<(blob + Int(length)))
        }
        return nil
    }
}
