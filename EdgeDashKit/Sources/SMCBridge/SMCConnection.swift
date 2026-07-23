// Fan readings via the AppleSMC user client. Key/struct layout follows the
// long-established community reverse engineering (SMCKit, exelban/stats —
// MIT attribution in NOTICE). Feature-detected: no AppleSMC service or
// failing calls simply yield no data.

import Foundation
import IOKit

/// MUST be exactly 80 bytes to match the kernel's C struct. Swift packs a
/// nested 9-byte struct tighter than C does (size vs stride), which shifted
/// every following field by 3 bytes and made AppleSMC reject ALL calls with
/// kIOReturnBadArgument — hence the explicit padding fields.
struct SMCParamStruct {
    var key: UInt32 = 0                                                  // 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)     // 4
    private var pad0: UInt16 = 0                                         // 10
    var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0) // 12
    var keyInfoDataSize: UInt32 = 0                                      // 28
    var keyInfoDataType: UInt32 = 0                                      // 32
    var keyInfoDataAttributes: UInt8 = 0                                 // 36
    private var pad1: (UInt8, UInt8, UInt8) = (0, 0, 0)                  // 37
    var result: UInt8 = 0                                                // 40
    var status: UInt8 = 0                                                // 41
    var data8: UInt8 = 0                                                 // 42
    private var pad2: UInt8 = 0                                          // 43
    var data32: UInt32 = 0                                               // 44
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // 48
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)                // = 80
}

private let kSMCHandleYPCEvent: UInt32 = 2
private let kSMCReadKey: UInt8 = 5
private let kSMCGetKeyInfo: UInt8 = 9

/// Minimal read-only AppleSMC connection.
final class SMCConnection {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return nil }
        connection = connect
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Raw bytes + declared type for an SMC key like "F0Ac", or nil.
    func read(key: String) -> (bytes: [UInt8], type: UInt32)? {
        guard let keyCode = Self.fourCC(key) else { return nil }

        var info = SMCParamStruct()
        info.key = keyCode
        info.data8 = kSMCGetKeyInfo
        guard let infoResult = call(info), infoResult.result == 0 else { return nil }

        var read = SMCParamStruct()
        read.key = keyCode
        read.keyInfoDataSize = infoResult.keyInfoDataSize
        read.data8 = kSMCReadKey
        guard let readResult = call(read), readResult.result == 0 else { return nil }

        let size = Int(min(infoResult.keyInfoDataSize, 32))
        let bytes = withUnsafeBytes(of: readResult.bytes) { Array($0.prefix(size)) }
        return (bytes, infoResult.keyInfoDataType)
    }

    private func call(_ input: SMCParamStruct) -> SMCParamStruct? {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        return result == KERN_SUCCESS ? output : nil
    }

    /// "F0Ac" → big-endian FourCC. Pure; unit-tested.
    static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.isASCII }) else { return nil }
        return scalars.reduce(0) { ($0 << 8) | UInt32($1.value) }
    }

    /// Decodes SMC numeric payloads. "flt " is the Apple Silicon fan format.
    static func decodeFloat(bytes: [UInt8], type: UInt32) -> Double? {
        switch type {
        case fourCC("flt ")!:
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case fourCC("ui8 ")!:
            return bytes.first.map(Double.init)
        case fourCC("ui16")!:
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case fourCC("fpe2")!:
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }
}
