import Foundation
import OrderedCollections
import Yams

enum YAMLValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([YAMLValue])
    case dictionary(OrderedDictionary<String, YAMLValue>)
    case null
}

extension YAMLValue {
    nonisolated subscript(_ key: String) -> YAMLValue? {
        guard case .dictionary(let dict) = self else { return nil }
        return dict[key]
    }

    nonisolated var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    nonisolated var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    nonisolated var doubleValue: Double? {
        guard case .double(let value) = self else { return nil }
        return value
    }

    nonisolated var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    nonisolated var arrayValue: [YAMLValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    nonisolated var dictionaryValue: OrderedDictionary<String, YAMLValue>? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }
}

extension YAMLValue {
    nonisolated init(yamlString: String) throws {
        let node = try Yams.compose(yaml: yamlString)
        self = node.map(YAMLValue.from) ?? .null
    }

    nonisolated static func from(node: Yams.Node) -> YAMLValue {
        switch node {
        case .scalar(let scalar):
            if scalar.style != .plain {
                return .string(scalar.string)
            }

            switch node.tag.rawValue {
            case Tag.Name.null.rawValue:
                return .null
            case Tag.Name.bool.rawValue:
                return .bool((scalar.string as NSString).boolValue)
            case Tag.Name.int.rawValue:
                return Int(scalar.string).map(YAMLValue.int) ?? .string(scalar.string)
            case Tag.Name.float.rawValue:
                return Double(scalar.string).map(YAMLValue.double) ?? .string(scalar.string)
            default:
                return .string(scalar.string)
            }
        case .mapping(let mapping):
            var dict = OrderedDictionary<String, YAMLValue>()
            for (key, value) in mapping {
                dict[key.string ?? ""] = from(node: value)
            }
            return .dictionary(dict)
        case .sequence(let sequence):
            return .array(sequence.map(from))
        case .alias:
            return .null
        }
    }

    nonisolated func toYAMLString() throws -> String {
        try Yams.serialize(node: toNode())
    }

    private nonisolated func toNode() -> Yams.Node {
        switch self {
        case .string(let value):
            return Yams.Node(value, Tag(.str))
        case .int(let value):
            return Yams.Node(String(value), Tag(.int))
        case .double(let value):
            return Yams.Node(String(value), Tag(.float))
        case .bool(let value):
            return Yams.Node(value ? "true" : "false", Tag(.bool))
        case .array(let values):
            return Yams.Node(values.map { $0.toNode() })
        case .dictionary(let dict):
            let pairs = dict.map { key, value in
                (Yams.Node(key, Tag(.str)), value.toNode())
            }
            return Yams.Node(pairs)
        case .null:
            return Yams.Node("null", Tag(.null))
        }
    }
}
