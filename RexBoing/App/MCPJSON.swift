import Foundation

/// A JSON document as a value: what the MCP layer passes between stdio, the
/// app's message port, tool arguments, schemas and results.
///
/// `[String: Any]` from `JSONSerialization` cannot cross threads under strict
/// concurrency checking, and it loses the difference between `1` and `true`
/// (both bridge to `NSNumber`). An enum keeps both, and the literal
/// conformances keep the tool schemas readable.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Integers, and doubles with no fractional part: a client is free to send
    /// `5.0` for an integer argument.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < 1e15: return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Readings

extension JSONValue {
    /// A reading rounded to `decimals` places, or `nil` (the key is left out)
    /// when there is none. JSON has no NaN or infinity, and a non-finite value
    /// is a reading that does not exist, not a large one.
    static func number(_ value: Double?, _ decimals: Int) -> JSONValue? {
        guard let value, value.isFinite else { return nil }
        let scale = pow(10, Double(decimals))
        let rounded = (value * scale).rounded() / scale
        // Whole numbers as integers: the same text on the wire, and no "-0".
        if rounded.rounded() == rounded, abs(rounded) < 1e15 { return .int(Int(rounded)) }
        return .double(rounded)
    }

    /// A 0...1 fraction as a percentage, which is the only way fractions leave
    /// this layer: a bare fraction under a name like `cpu` is a guess for the
    /// reader.
    static func percent(_ fraction: Double?, _ decimals: Int = 1) -> JSONValue? {
        number(fraction.map { $0 * 100 }, decimals)
    }

    /// Byte counts are integral; clamped rather than converted, so one absurd
    /// counter upstream reads as a saturated figure instead of trapping.
    static func bytes(_ value: UInt64) -> JSONValue {
        .int(Int(clamping: value))
    }

    static func time(_ date: Date) -> JSONValue {
        .string(MCPTime.iso(date))
    }
}

/// Builds an object whose absent readings are simply not there: assigning
/// `nil` leaves the key out, which is how "this Mac has no source for it"
/// is said everywhere in the MCP payloads.
struct JSONObject {
    private(set) var storage: [String: JSONValue] = [:]

    init() {}

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    var isEmpty: Bool { storage.isEmpty }
    var value: JSONValue { .object(storage) }
}

// MARK: - Serialization

extension JSONValue {
    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ParseError(description: "Not valid JSON.")
        }
        return JSONValue(foundation: object)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    private init(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // CFBoolean is the only NSNumber whose type is the boolean's;
            // `as? Bool` would also accept 0 and 1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(foundation:)))
        default:
            self = .string(String(describing: object))
        }
    }

    /// Compact, single-line UTF-8. Both stdio and the message port frame one
    /// message per line, so the writer must never emit a raw newline, and it
    /// does not: newlines inside strings are escaped. Keys are sorted, so the
    /// same answer always serialises the same way, which keeps the tool list
    /// stable for clients that cache it.
    func serialized(pretty: Bool = false) -> Data {
        Data(serializedString(pretty: pretty).utf8)
    }

    func serializedString(pretty: Bool = false) -> String {
        var output = ""
        write(into: &output, pretty: pretty, indent: 0)
        return output
    }

    private func write(into output: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .double(let value):
            if !value.isFinite {
                output += "null"
            } else if value.rounded() == value, abs(value) < 1e15 {
                output += String(Int(value))
            } else {
                output += String(value)
            }
        case .string(let value):
            Self.writeString(value, into: &output)
        case .array(let values):
            guard !values.isEmpty else {
                output += "[]"
                return
            }
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
                value.write(into: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: indent) }
            output += "]"
        case .object(let object):
            guard !object.isEmpty else {
                output += "{}"
                return
            }
            output += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
                Self.writeString(key, into: &output)
                output += pretty ? ": " : ":"
                object[key]!.write(into: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: indent) }
            output += "}"
        }
    }

    private static func writeString(_ value: String, into output: inout String) {
        output += "\""
        // Most strings need no escaping at all, and are appended whole.
        // U+2028 and U+2029 are escaped too: valid JSON, but line breaks to
        // a JavaScript reader, and one of those is often on the other end.
        let needsEscaping = value.utf8.contains { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C || $0 == 0xE2 }
        guard needsEscaping else {
            output += value
            output += "\""
            return
        }
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - Times and durations

/// How the MCP tools write and read moments and windows.
///
/// Out: ISO 8601 with the Mac's own UTC offset, to the second, so a reading
/// can be read off as wall-clock time without converting from UTC. In:
/// windows as seconds or short durations (`90s`, `15m`, `6h`, `1h30m`), and
/// moments as ISO 8601 or as how long ago (`15m`).
enum MCPTime {
    // `ISO8601DateFormatter` is documented thread-safe; it is only not
    // `Sendable`-annotated. The time zone follows the system's as it changes.
    nonisolated(unsafe) private static let writer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let readers: [ISO8601DateFormatter] = {
        let options: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            // No offset: the Mac's own time, which is what a person means by
            // "14:05" on this machine.
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate],
        ]
        return options.map { options in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .autoupdatingCurrent
            formatter.formatOptions = options
            return formatter
        }
    }()

    static func iso(_ date: Date) -> String {
        writer.string(from: date)
    }

    static func parseISO(_ text: String) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        // "2026-11-19 14:05" is how people write it; the formatter wants a T.
        if text.count > 10, text[text.index(text.startIndex, offsetBy: 10)] == " " {
            text.replaceSubrange(
                text.index(text.startIndex, offsetBy: 10)...text.index(text.startIndex, offsetBy: 10),
                with: "T")
        }
        // Seconds are optional in what people type.
        if text.count == 16, text.contains("T") { text += ":00" }
        for reader in readers {
            if let date = reader.date(from: text) { return date }
        }
        return nil
    }

    private static let unitSeconds: [String: Double] = [
        "ms": 0.001,
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
        "d": 86_400, "day": 86_400, "days": 86_400,
    ]

    /// Seconds from a number of seconds or a duration string: `90`, `"90s"`,
    /// `"15m"`, `"6h"`, `"1h30m"`, `"2 hours"`. Nil for anything else,
    /// including negative, zero and non-finite values.
    static func duration(_ value: JSONValue) -> TimeInterval? {
        if let seconds = value.doubleValue {
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        guard var text = value.stringValue?.lowercased().trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        if text.hasSuffix(" ago") { text.removeLast(4) }
        if let seconds = Double(text) { return seconds.isFinite && seconds > 0 ? seconds : nil }

        var total = 0.0
        var index = text.startIndex
        var parts = 0
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let numberStart = index
            while index < text.endIndex, text[index].isNumber || text[index] == "." {
                index = text.index(after: index)
            }
            guard let amount = Double(text[numberStart..<index]) else { return nil }
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            let unitStart = index
            while index < text.endIndex, text[index].isLetter { index = text.index(after: index) }
            guard let scale = unitSeconds[String(text[unitStart..<index])] else { return nil }
            total += amount * scale
            parts += 1
        }
        return parts > 0 && total.isFinite && total > 0 ? total : nil
    }

    /// A moment: `"now"`, ISO 8601, or a duration meaning that long ago.
    static func moment(_ value: JSONValue, now: Date) -> Date? {
        if let text = value.stringValue {
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "now" { return now }
            if let date = parseISO(text) { return date }
        }
        return duration(value).map { now.addingTimeInterval(-$0) }
    }
}
