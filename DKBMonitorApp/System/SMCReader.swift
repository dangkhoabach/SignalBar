import Foundation
import IOKit

/// Reads raw SMC keys (CPU/SoC temperature, fan RPM) directly via IOKit —
/// there is no public Apple framework for this; this is the same technique
/// smcFanControl/SMCKit/the Rust `smc` crate use, moved over from the Phase 0
/// PoC (`native/PoC/SMC/SMCReader.swift`) unchanged.
///
/// Known gotcha already hit once in the Rust version: on Apple Silicon the
/// `F{n}ID` key (fan identity) that SMCKit-style libraries read first to
/// build a "Fan" struct doesn't exist — only the bare `F{n}Ac` (actual speed)
/// key survived the M-series SMC redesign. This reader skips the ID lookup
/// entirely and reads `F{n}Ac` / temperature keys directly.
enum SMCError: Error {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    /// `SMCParamStruct` no longer matches the layout the kernel expects, so
    /// any reading taken through it would be garbage rather than a failure.
    case unexpectedStructLayout(Int)
}

final class SMCReader {
    private var connection: io_connect_t = 0

    private static let kernelIndexSMC: UInt32 = 2
    private enum Selector: UInt8 {
        case kSMCReadKeyInfo = 9
        case kSMCReadBytes = 5
    }

    struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    func open() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw SMCError.openFailed(result) }
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// The owner is long-lived, so this rarely runs — but an `io_connect_t`
    /// that outlives its reader is a kernel resource nothing can reclaim,
    /// and relying on every future owner to remember `close()` is the kind
    /// of contract that gets broken quietly.
    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    /// FourCC key (e.g. "TC0P", "F0Ac") -> UInt32, big-endian byte order (SMC convention).
    private static func fourCC(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    /// Size the kernel's `AppleSMC` method expects for its parameter struct.
    ///
    /// Swift makes no promise about how it lays out a struct's fields, and
    /// this one has to match a C layout byte for byte. If a compiler ever
    /// packs it differently, `IOConnectCallStructMethod` still succeeds and
    /// just reads the wrong offsets — the app would report plausible-looking
    /// nonsense temperatures rather than fail. Checking the size turns that
    /// into a loud, immediate failure instead.
    static let expectedParamStructSize = 80

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard MemoryLayout<SMCParamStruct>.stride == Self.expectedParamStructSize else {
            throw SMCError.unexpectedStructLayout(MemoryLayout<SMCParamStruct>.stride)
        }
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(Self.kernelIndexSMC),
            &input,
            inputSize,
            &output,
            &outputSize
        )
        guard result == KERN_SUCCESS else { throw SMCError.callFailed(result) }
        return output
    }

    /// Reads a raw SMC key's bytes + declared 4-byte type code (e.g. "flt ", "ui8 ").
    func readRaw(key: String) throws -> (bytes: [UInt8], type: String, size: Int) {
        var infoInput = SMCParamStruct()
        infoInput.key = Self.fourCC(key)
        infoInput.data8 = Selector.kSMCReadKeyInfo.rawValue
        let infoOutput = try call(&infoInput)
        guard infoOutput.keyInfo.dataSize > 0 else { throw SMCError.keyNotFound(key) }

        var readInput = SMCParamStruct()
        readInput.key = Self.fourCC(key)
        readInput.keyInfo.dataSize = infoOutput.keyInfo.dataSize
        readInput.data8 = Selector.kSMCReadBytes.rawValue
        let readOutput = try call(&readInput)

        let size = Int(infoOutput.keyInfo.dataSize)
        let bytesTuple = readOutput.bytes
        let allBytes: [UInt8] = [
            bytesTuple.0, bytesTuple.1, bytesTuple.2, bytesTuple.3, bytesTuple.4, bytesTuple.5, bytesTuple.6, bytesTuple.7,
            bytesTuple.8, bytesTuple.9, bytesTuple.10, bytesTuple.11, bytesTuple.12, bytesTuple.13, bytesTuple.14, bytesTuple.15,
            bytesTuple.16, bytesTuple.17, bytesTuple.18, bytesTuple.19, bytesTuple.20, bytesTuple.21, bytesTuple.22, bytesTuple.23,
            bytesTuple.24, bytesTuple.25, bytesTuple.26, bytesTuple.27, bytesTuple.28, bytesTuple.29, bytesTuple.30, bytesTuple.31,
        ]

        var typeBytes = withUnsafeBytes(of: infoOutput.keyInfo.dataType.bigEndian) { Array($0) }
        typeBytes = typeBytes.map { $0 == 0 ? 0x20 : $0 } // NUL -> space, cosmetic only
        let type = String(bytes: typeBytes, encoding: .ascii) ?? "????"

        return (Array(allBytes.prefix(size)), type, size)
    }

    /// Decodes a key already known to hold a temperature/fan-speed reading.
    /// Apple SMC historically used fixed-point "sp78" (temperature, pre-M1)
    /// or plain "flt " (IEEE 754 float) depending on chip generation and key.
    func readFloatValue(key: String) throws -> Double {
        let (bytes, type, size) = try readRaw(key: key)
        switch type {
        case "flt ":
            guard size >= 4 else { throw SMCError.keyNotFound(key) }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard size >= 2 else { throw SMCError.keyNotFound(key) }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "ui8 ":
            guard size >= 1 else { throw SMCError.keyNotFound(key) }
            return Double(bytes[0])
        default:
            throw SMCError.keyNotFound("\(key) (unhandled type '\(type)', \(size) bytes)")
        }
    }

    /// Candidate CPU/SoC die temperature keys, roughly newest-chip-first.
    static let candidateTempKeys = ["Tp09", "Tp0T", "Tc0a", "Tc0b", "TC0P", "TC0D", "TCXC", "TCXc"]

    /// Candidate GPU die temperature keys. Apple Silicon generations name
    /// them differently: `Tg05`/`Tg0D`/`Tg0L` read on an M3 Pro; `Tg0T`/`Tg0e`
    /// (M2) and `Tg0f`/`Tg0j` (M1) are from other generations and unverified
    /// here; `Tg0P` is the Intel proximity sensor.
    static let candidateGPUTempKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0e", "Tg0f", "Tg0j", "Tg0P"]

    /// Whole-system power draw in watts, as the SMC reports it (5.6 W idle on
    /// an M3 Pro).
    static let systemPowerKey = "PSTR"

    /// The first key in `keys` that reads a value inside `range`, for probing
    /// which of several per-generation key names this Mac actually has. Run
    /// once and cached by the caller — each miss is a full SMC round trip.
    func firstReadableKey(in keys: [String], within range: ClosedRange<Double>) -> String? {
        keys.first { key in
            guard let value = try? readFloatValue(key: key) else { return false }
            return range.contains(value)
        }
    }

    /// Fan actual-speed keys. Per the note above, read `F{n}Ac` directly —
    /// do NOT probe `F{n}ID` first like classic SMCKit-derived code does.
    static func fanActualKey(index: Int) -> String { "F\(index)Ac" }

    /// How many fans this Mac reports (`FNum` on Intel; may not exist on all
    /// Apple Silicon models that have no fan at all, e.g. fanless MacBook Air).
    func fanCount() -> Int {
        (try? Int(readFloatValue(key: "FNum"))) ?? 0
    }
}
