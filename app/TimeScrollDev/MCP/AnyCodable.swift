import Foundation
// Minimal AnyEncodable / AnyDecodable wrappers for simple JSON bridging
public struct AnyEncodable: Encodable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Int64: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as [Any]:
            var unkeyed = encoder.unkeyedContainer()
            for item in v { try unkeyed.encode(AnyEncodable(item)) }
        case let v as [String: Any]:
            try container.encode(DictionaryEncoder.encode(v))
        default:
            try container.encodeNil()
        }
    }
}

public struct AnyDecodable: Decodable {
    public let value: Any
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode(Int.self) { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(Bool.self) { value = v; return }
        if let v = try? container.decode([AnyDecodable].self) { value = v.map { $0.value }; return }
        if let v = try? container.decode([String: AnyDecodable].self) {
            value = v.mapValues { $0.value }; return
        }
        value = NSNull()
    }
}

private enum DictionaryEncoder {
    static func encode(_ dict: [String: Any]) throws -> [String: AnyEncodable] {
        var out: [String: AnyEncodable] = [:]
        for (k, v) in dict { out[k] = AnyEncodable(v) }
        return out
    }
}
