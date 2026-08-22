import Foundation

func evaluateExpectation(
    _ operation: () throws -> Bool
) rethrows -> Bool {
    try operation()
}

private struct MutationPayloadCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

func mutationPayloadDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .custom { codingPath in
        let rawKey = codingPath.last?.stringValue ?? ""
        let components = rawKey.split(
            separator: "_",
            omittingEmptySubsequences: true
        )

        let converted = components.enumerated().map { index, component -> String in
            let value = String(component)

            if index == 0 {
                return value
            }

            switch value.lowercased() {
            case "id":
                return "ID"
            case "ids":
                return "IDs"
            case "url":
                return "URL"
            default:
                return value.prefix(1).uppercased() + value.dropFirst()
            }
        }
        .joined()

        return MutationPayloadCodingKey(stringValue: converted)!
    }

    return decoder
}
