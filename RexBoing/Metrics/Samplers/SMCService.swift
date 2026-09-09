import Foundation
import IOKit

/// Minimal AppleSMC client: the primary source for temperatures — its key
/// namespace is canonical where the HID sensor names are not — and the only
/// source for fan speeds. `HIDSensorReader` is the fallback when this user
/// client is unavailable.
///
/// Fanless Macs (MacBook Air, Mac mini M-series in some configs) simply report
/// zero fans, which the UI hides.
final class SMCService {
    // The struct layout below is the AppleSMC user-client ABI. Field order and
    // padding must match exactly or `IOConnectCallStructMethod` returns garbage.
    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // Swift lays out a struct by advancing past each field's *size*, while C
        // advances past its *stride*. Without this explicit tail padding the
        // enclosing `KeyData` comes out at 76 bytes instead of the 80 the
        // AppleSMC user client expects, and every call fails with
        // kIOReturnBadArgument.
        private var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private enum Selector: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    private let connection: io_connect_t
    private var keyInfoCache: [UInt32: KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return nil
        }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: - Temperature

    /// Walks the SMC's key index once and returns every key that both starts
    /// with `T` and currently reads back a plausible temperature. The values
    /// come back with the keys: validating a candidate already had to read it,
    /// and throwing those readings away only to re-read all ~190 keys made the
    /// first telemetry sample needlessly slower. Costs roughly half a second,
    /// so callers should do this exactly once and re-read the resulting keys
    /// thereafter.
    func discoverTemperatures() -> [(key: String, celsius: Double)] {
        guard let raw = read(key: "#KEY")?.1 else { return [] }
        let count = Int(UInt32(raw.0) << 24 | UInt32(raw.1) << 16
            | UInt32(raw.2) << 8 | UInt32(raw.3))
        guard count > 0, count < 8_192 else { return [] }

        var readings: [(String, Double)] = []
        var seen = Set<String>()
        for index in 0..<count {
            var input = KeyData()
            input.data8 = Selector.readIndex.rawValue
            input.data32 = UInt32(index)
            guard let output = call(input) else { continue }
            let name = fourCharString(output.key)
            guard name.hasPrefix("T"), seen.insert(name).inserted else { continue }
            // `temperature` already bounds readings to a plausible −50…150 °C.
            // Rejecting exactly zero keeps unpopulated keys — which idle at
            // 0.0 — out of the set, without permanently dropping a sensor that
            // was legitimately sub-zero at the moment of this one-time pass.
            guard let value = temperature(key: name), value != 0 else { continue }
            readings.append((name, value))
        }
        return readings
    }

    func temperature(key: String) -> Double? {
        guard let value = readFloat(key: key), value > -50, value < 150 else { return nil }
        return value
    }

    // MARK: - Power

    /// Power rails read in watts (`PSTR`, `PDTR`, …). Bounded like the
    /// temperatures: a rail reading negative or in kilowatts is a decode
    /// failure, not a measurement.
    func watts(key: String) -> Double? {
        guard let value = readFloat(key: key), value >= 0, value < 1_000 else { return nil }
        return value
    }

    // MARK: - Fans

    func fans() -> [Fan] {
        guard let count = readUInt8(key: "FNum"), count > 0, count < 16 else { return [] }
        return (0..<Int(count)).compactMap { index in
            guard let rpm = readFloat(key: "F\(index)Ac") else { return nil }
            return Fan(
                index: index,
                rpm: rpm,
                minRPM: readFloat(key: "F\(index)Mn") ?? 0,
                maxRPM: readFloat(key: "F\(index)Mx") ?? max(rpm, 1))
        }
    }

    // MARK: - Typed reads

    private func readUInt8(key: String) -> UInt8? {
        guard let (info, bytes) = read(key: key), info.dataSize >= 1 else { return nil }
        return bytes.0
    }

    /// SMC values arrive as `flt` (little-endian IEEE 754) on Apple silicon and
    /// as fixed-point (`sp78`, `fpe2`, `fp79`, …) on older Intel hardware.
    private func readFloat(key: String) -> Double? {
        guard let (info, bytes) = read(key: key) else { return nil }
        let type = fourCharString(info.dataType)

        switch type {
        case "flt ":
            guard info.dataSize >= 4 else { return nil }
            let raw = UInt32(bytes.0) | UInt32(bytes.1) << 8
                | UInt32(bytes.2) << 16 | UInt32(bytes.3) << 24
            let value = Double(Float(bitPattern: raw))
            return value.isFinite ? value : nil
        case "ui8 ":
            return Double(bytes.0)
        case "ui16":
            guard info.dataSize >= 2 else { return nil }
            return Double(UInt16(bytes.0) << 8 | UInt16(bytes.1))
        case "ui32":
            guard info.dataSize >= 4 else { return nil }
            return Double(UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16
                | UInt32(bytes.2) << 8 | UInt32(bytes.3))
        default:
            // Fixed point: `fpXY` unsigned, `spXY` signed — X integer and Y
            // fraction bits as hex digits over a big-endian 16-bit payload.
            // Temperatures are `sp78`, fan speeds usually `fpe2`. Decoded
            // from the type code rather than enumerated case by case: the
            // hand-kept list matched a type that does not exist ("fp78" —
            // 7+8 fills only 15 of 16 bits) while missing real ones
            // ("fp79"), and the divisor is 2^fraction-width, so deriving
            // both from the name is the version that cannot drift.
            guard info.dataSize >= 2,
                  let scale = Self.fixedPointScale(of: type) else { return nil }
            let raw = UInt16(bytes.0) << 8 | UInt16(bytes.1)
            return scale.signed
                ? Double(Int16(bitPattern: raw)) / scale.divisor
                : Double(raw) / scale.divisor
        }
    }

    /// The divisor and signedness a fixed-point type code implies, or `nil`
    /// where the code is not SMC fixed point at all. The digit sum must fill
    /// the payload exactly — 16 bits, or 15 plus the sign — or the code is
    /// something else that happens to share a prefix.
    private static func fixedPointScale(
        of type: String
    ) -> (signed: Bool, divisor: Double)? {
        let chars = Array(type)
        guard chars.count == 4 else { return nil }
        let signed: Bool
        switch (chars[0], chars[1]) {
        case ("f", "p"): signed = false
        case ("s", "p"): signed = true
        default: return nil
        }
        guard let integerBits = chars[2].hexDigitValue,
              let fractionBits = chars[3].hexDigitValue,
              integerBits + fractionBits == (signed ? 15 : 16)
        else { return nil }
        return (signed, Double(1 << fractionBits))
    }

    // MARK: - Transport

    private func read(key: String) -> (KeyInfo, SMCBytes)? {
        let code = fourCharCode(key)
        guard let info = keyInfo(for: code), info.dataSize > 0 else { return nil }

        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.readBytes.rawValue

        guard let output = call(input) else { return nil }
        return (info, output.bytes)
    }

    private func keyInfo(for code: UInt32) -> KeyInfo? {
        if let cached = keyInfoCache[code] { return cached }

        var input = KeyData()
        input.key = code
        input.data8 = Selector.readKeyInfo.rawValue

        guard let output = call(input) else { return nil }
        keyInfoCache[code] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: KeyData) -> KeyData? {
        var input = input
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride

        let result = IOConnectCallStructMethod(
            connection,
            2, // kSMCHandleYPCEvent
            &input,
            MemoryLayout<KeyData>.stride,
            &output,
            &outputSize)

        guard result == kIOReturnSuccess,
              outputSize == MemoryLayout<KeyData>.stride,
              output.result == 0
        else { return nil }
        return output
    }

    private func fourCharCode(_ string: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            code = (code << 8) | UInt32(byte)
        }
        return code
    }

    private func fourCharString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}
