import Foundation
import ImageIO
import Vision

struct ReceiptOCRProposal: Equatable, Sendable {
    var merchant: String
    var totalText: String
    var currencyCode: String
    var occurredAt: Date?
    var taxText: String

    static let empty = ReceiptOCRProposal(
        merchant: "",
        totalText: "",
        currencyCode: "",
        occurredAt: nil,
        taxText: ""
    )
}

enum ReceiptOCRError: Error, Equatable, Sendable {
    case invalidImage
    case recognitionFailed
}

enum ReceiptOCRExtractor {
    private static let amountPattern = try? NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{2})|\d+[.,]\d{2})(?!\d)"#
    )
    private static let datePattern = try? NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2}[./-]\d{1,2}[./-]\d{2,4})(?!\d)"#
    )

    static func proposal(lines: [String]) -> ReceiptOCRProposal {
        let normalized = lines
            .map(String.joinWords)
            .filter { !$0.isEmpty }
        return ReceiptOCRProposal(
            merchant: merchant(in: normalized),
            totalText: total(in: normalized),
            currencyCode: currency(in: normalized),
            occurredAt: date(in: normalized),
            taxText: tax(in: normalized)
        )
    }

    private static func merchant(in lines: [String]) -> String {
        let excluded = [
            "receipt", "invoice", "fatur", "total", "totali", "shuma", "subtotal",
            "nëntotal", "tax", "vat", "tvsh", "date", "data",
        ]
        return lines.first { line in
            let lower = line.lowercased()
            let letterCount = line.unicodeScalars.filter(CharacterSet.letters.contains).count
            return line.count <= 120 && letterCount >= 2 &&
                !excluded.contains(where: lower.contains) &&
                !lower.contains("www.") && !lower.contains("http")
        } ?? ""
    }

    private static func total(in lines: [String]) -> String {
        let preferred = lines.filter { line in
            let lower = line.lowercased()
            return ["grand total", "amount due", "totali", "shuma", "total"]
                .contains(where: lower.contains) &&
                !lower.contains("subtotal") && !lower.contains("nëntotal")
        }
        for line in preferred.reversed() {
            if let amount = amounts(in: line).last { return amount }
        }
        for line in lines.reversed() where currency(in: [line]) != "" {
            if let amount = amounts(in: line).last { return amount }
        }
        return ""
    }

    private static func tax(in lines: [String]) -> String {
        for line in lines {
            let lower = line.lowercased()
            if ["tax", "vat", "tvsh"].contains(where: lower.contains),
               let amount = amounts(in: line).last {
                return amount
            }
        }
        return ""
    }

    private static func currency(in lines: [String]) -> String {
        let value = lines.joined(separator: " ").uppercased()
        if value.contains("EUR") || value.contains("€") { return "EUR" }
        if value.contains("USD") || value.contains("$") { return "USD" }
        if value.contains(" ALL") || value.contains("LEK") { return "ALL" }
        return ""
    }

    private static func date(in lines: [String]) -> Date? {
        let formats = ["dd/MM/yyyy", "dd.MM.yyyy", "dd-MM-yyyy", "MM/dd/yyyy", "dd/MM/yy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let datePattern,
                  let match = datePattern.firstMatch(in: line, range: range),
                  let candidateRange = Range(match.range(at: 1), in: line)
            else { continue }
            let candidate = String(line[candidateRange])
            for format in formats {
                formatter.dateFormat = format
                if let parsed = formatter.date(from: candidate) { return parsed }
            }
        }
        return nil
    }

    private static func amounts(in line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        guard let amountPattern else { return [] }
        return amountPattern.matches(in: line, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: line) else { return nil }
            return normalizeAmount(String(line[valueRange]))
        }
    }

    private static func normalizeAmount(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard let lastComma = compact.lastIndex(of: ","),
              let lastDot = compact.lastIndex(of: ".")
        else {
            if let comma = compact.lastIndex(of: ","), compact.distance(from: comma, to: compact.endIndex) == 3 {
                return compact.replacingOccurrences(of: ",", with: ".")
            }
            return compact
        }
        if lastComma > lastDot {
            return compact
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        }
        return compact.replacingOccurrences(of: ",", with: "")
    }
}

actor ReceiptOCRService {
    func recognize(imageData: Data) throws -> ReceiptOCRProposal {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ReceiptOCRError.invalidImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ReceiptOCRError.recognitionFailed
        }
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        return ReceiptOCRExtractor.proposal(lines: lines)
    }
}

private extension String {
    static func joinWords(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
