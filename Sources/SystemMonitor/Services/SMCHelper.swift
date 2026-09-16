import Foundation
import IOKit
import Darwin

/// Minimal client for the Apple SMC (System Management Controller).
/// Talks to the `AppleSMC` IOService using the standard SMC protocol
/// (same one used by open-source tools like smcFanControl / Stats).
/// On Apple Silicon this works for READING keys (fan RPM, temperatures, ...).
final class SMCHelper {
    private var conn: io_connect_t = 0
    private let connected: Bool

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { connected = false; return nil }
        defer { IOObjectRelease(service) }

        var c: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &c)
        if SMCHelper.debug {
            print("SMCdbg IOServiceOpen result=\(result) conn=\(c)")
            print("SMCdbg keySize=\(MemoryLayout<SMCKeyData>.size) align=\(MemoryLayout<SMCKeyData>.alignment)")
            for path in [\SMCKeyData.key, \SMCKeyData.vers, \SMCKeyData.pLimitData, \SMCKeyData.keyInfo, \SMCKeyData.result, \SMCKeyData.status, \SMCKeyData.data8, \SMCKeyData.data32, \SMCKeyData.bytes] {
                print("SMCdbg offset \(path) = \(MemoryLayout<SMCKeyData>.offset(of: path) ?? -1)")
            }
            print("SMCdbg versSize=\(MemoryLayout<SMCKeyDataVers>.size) pLimitSize=\(MemoryLayout<SMCKeyDataPLimit>.size) keyInfoSize=\(MemoryLayout<SMCKeyDataKeyInfo>.size) bytesSize=\(MemoryLayout<SMCBytes>.size)")
        }
        guard result == kIOReturnSuccess else { connected = false; return nil }
        conn = c
        connected = true
    }

    deinit {
        if connected {
            IOServiceClose(conn)
        }
    }

    // MARK: - SMC wire structures (must mirror the C structs exactly)

    typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct SMCKeyDataVers {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    private struct SMCKeyDataPLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyDataKeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers: SMCKeyDataVers = SMCKeyDataVers()
        var pLimitData: SMCKeyDataPLimit = SMCKeyDataPLimit()
        var keyInfo: SMCKeyDataKeyInfo = SMCKeyDataKeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = SMCHelper.zeroBytes
    }

    private static let zeroBytes: SMCBytes =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let kernelIndexSMC: UInt32 = 2

    // MARK: - Low-level I/O

    private func call(_ index: UInt32, input: inout SMCKeyData) -> kern_return_t {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            conn, index, &input,
            MemoryLayout<SMCKeyData>.stride,
            &output, &outputSize
        )
        input = output
        return result
    }

    /// Encode a 4-char SMC key ("F0Ac") into the wire format (big-endian FourCC).
    private static func keyValue(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func tupleToData(_ tuple: SMCBytes) -> Data {
        withUnsafeBytes(of: tuple) { Data($0) }
    }

    private static func dataToTuple(_ data: Data) -> SMCBytes {
        var tuple = SMCHelper.zeroBytes
        let n = min(data.count, 32)
        data.withUnsafeBytes { src in
            withUnsafeMutableBytes(of: &tuple) { dst in
                if let s = src.baseAddress, let d = dst.baseAddress {
                    memcpy(d, s, n)
                }
            }
        }
        return tuple
    }

    private static func typeName(_ raw: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Read the raw bytes + data type for a key.
    func readKey(_ key: String) -> (type: String, data: Data)? {
        // Key info (size + type)
        var info = SMCKeyData()
        info.key = Self.keyValue(key)
        info.data8 = Self.cmdReadKeyInfo
        let infoResult = call(Self.kernelIndexSMC, input: &info)
        if SMCHelper.debug { print("SMCdbg \(key): keyInfoResult=\(infoResult) dataSize=\(info.keyInfo.dataSize) typeRaw=\(String(format: "0x%08x", info.keyInfo.dataType))") }
        guard infoResult == kIOReturnSuccess else { return nil }

        let dataSize = Int(info.keyInfo.dataSize)
        guard dataSize > 0, dataSize <= 32 else { return nil }
        let type = Self.typeName(info.keyInfo.dataType)

        // Value
        var value = SMCKeyData()
        value.key = Self.keyValue(key)
        value.data8 = Self.cmdReadBytes
        value.keyInfo.dataSize = info.keyInfo.dataSize
        let valueResult = call(Self.kernelIndexSMC, input: &value)
        if SMCHelper.debug { print("SMCdbg \(key): valueResult=\(valueResult)") }
        guard valueResult == kIOReturnSuccess else { return nil }

        let all = Self.tupleToData(value.bytes)
        return (type, all.prefix(dataSize))
    }

    static var debug = false

    /// Write raw bytes to a key. Returns kIOReturnSuccess on success.
    /// Mirrors the protocol used by smcFanControl / Stats, including the
    /// SMC firmware-level result check.
    func writeKey(_ key: String, data: Data) -> kern_return_t {
        var input = SMCKeyData()
        input.key = Self.keyValue(key)
        input.data8 = Self.cmdWriteBytes
        input.keyInfo.dataSize = UInt32(data.count)
        input.bytes = Self.dataToTuple(data)

        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            conn, Self.kernelIndexSMC, &input,
            MemoryLayout<SMCKeyData>.stride,
            &output, &outputSize
        )
        // IOKit can return success while the SMC firmware still rejects the
        // write (output.result != 0).
        if result == kIOReturnSuccess && output.result != 0x00 {
            return kIOReturnError
        }
        return result
    }

    // MARK: - Value decoding

    private static func decode(_ data: Data, type: String) -> Double? {
        guard data.count >= 1 else { return nil }
        switch type {
        case "ui8 ":
            return Double(data[0])
        case "ui16":
            guard data.count >= 2 else { return nil }
            return Double(readUInt(data, size: 2))
        case "ui32":
            guard data.count >= 4 else { return nil }
            return Double(readUInt(data, size: 4))
        case "flt ":
            guard data.count >= 4 else { return nil }
            return Double(readFloat(data))
        case "fpe2":
            guard data.count >= 2 else { return nil }
            return Double((Int(data[0]) << 6) + (Int(data[1]) >> 2))
        case "sp78":
            guard data.count >= 2 else { return nil }
            return Double(Int(Int16(bitPattern: readUInt16(data)))) / 256.0
        case "sp1e":
            return fixedPoint(data, scale: 16384)
        case "sp3c":
            return fixedPoint(data, scale: 4096)
        case "sp4b":
            return fixedPoint(data, scale: 2048)
        case "sp5a":
            return fixedPoint(data, scale: 1024)
        case "sp69":
            return fixedPoint(data, scale: 512)
        case "sp87":
            return fixedPoint(data, scale: 128)
        case "sp96":
            return fixedPoint(data, scale: 64)
        case "spa5":
            return fixedPoint(data, scale: 32)
        case "spb4":
            return fixedPoint(data, scale: 16)
        case "spf0":
            return fixedPoint(data, scale: 1)
        default:
            return nil
        }
    }

    private static func fixedPoint(_ data: Data, scale: Double) -> Double? {
        guard data.count >= 2 else { return nil }
        return Double(readUInt(data, size: 2)) / scale
    }

    private static func readUInt16(_ data: Data) -> UInt16 {
        UInt16(data[0]) << 8 | UInt16(data[1])
    }

    private static func readUInt(_ data: Data, size: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in data.prefix(size) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    /// SMC floats come back little-endian in the byte array.
    private static func readFloat(_ data: Data) -> Float {
        let raw = data.prefix(4).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        return Float(bitPattern: raw)
    }

    // MARK: - Public API

    /// Returns (value, SMC data type string) for any key.
    func read(_ key: String) -> (value: Double, type: String)? {
        guard let (type, data) = readKey(key) else { return nil }
        guard let value = Self.decode(data, type: type) else { return nil }
        return (value, type)
    }

    func fanCount() -> Int {
        guard let (value, _) = read("FNum") else { return 0 }
        let count = Int(value.rounded())
        return count > 0 ? min(count, 8) : 0
    }

    func fanSpeeds() -> [Double] {
        let count = fanCount()
        var speeds: [Double] = []
        for i in 0..<count {
            if let (v, _) = read("F\(i)Ac"), v >= 0, v < 20_000 {
                speeds.append(v)
            }
        }
        return speeds
    }

    func cpuTemperature() -> Double? {
        // Return the hottest core (matches what monitoring tools display).
        var hottest: Double?
        for key in ["Tp09", "Tp0a", "Tp0b", "Tp0c", "Tp0d", "Tf09", "Tf0a", "Tf0b", "Tf0c"] {
            if let (v, _) = read(key), v > 0, v < 150 {
                hottest = max(hottest ?? v, v)
            }
        }
        return hottest
    }

    func gpuTemperature() -> Double? {
        // On Apple Silicon: Tg05 is the GPU temp.
        for key in ["Tg05", "Tg0d", "Tg0f"] {
            if let (v, _) = read(key), v > 0, v < 150 {
                return v
            }
        }
        return nil
    }
}
