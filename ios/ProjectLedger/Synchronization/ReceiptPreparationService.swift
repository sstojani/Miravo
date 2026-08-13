import Foundation
import ImageIO
import PDFKit
import UIKit

enum ReceiptPreparationError: Error, Equatable, Sendable {
    case emptyFile
    case inputTooLarge
    case unsupportedType
    case invalidImage
    case imageDimensionsTooLarge
    case invalidPDF
    case encryptedPDF
    case tooManyPDFPages
    case outputTooLarge
}

struct PreparedReceipt: Equatable, Sendable {
    let content: Data
    let thumbnail: Data
    let ocrImage: Data
    let originalFilename: String
    let contentType: String
    let fileExtension: String
    let originalRetained: Bool
}

actor ReceiptPreparationService {
    static let maximumInputBytes = 25 * 1_024 * 1_024
    static let maximumOutputBytes = 12 * 1_024 * 1_024
    static let maximumImagePixels: Int64 = 40_000_000
    static let maximumPDFPages = 100

    func prepare(
        data: Data,
        suggestedFilename: String,
        declaredContentType: String? = nil
    ) throws -> PreparedReceipt {
        guard !data.isEmpty else { throw ReceiptPreparationError.emptyFile }
        guard data.count <= Self.maximumInputBytes else {
            throw ReceiptPreparationError.inputTooLarge
        }
        if data.starts(with: Data("%PDF-".utf8)) || declaredContentType == "application/pdf" {
            return try preparePDF(data: data, suggestedFilename: suggestedFilename)
        }
        return try prepareImage(data: data, suggestedFilename: suggestedFilename)
    }

    private func prepareImage(data: Data, suggestedFilename: String) throws -> PreparedReceipt {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0
        else {
            throw ReceiptPreparationError.invalidImage
        }
        let (pixelCount, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !overflow, pixelCount <= Self.maximumImagePixels else {
            throw ReceiptPreparationError.imageDimensionsTooLarge
        }
        let dimensions = [2_400, 1_800, 1_400, 1_000]
        let qualities: [CGFloat] = [0.82, 0.70, 0.58]
        for maximumDimension in dimensions {
            guard let image = downsample(source: source, maximumDimension: maximumDimension) else {
                continue
            }
            for quality in qualities {
                guard let content = UIImage(cgImage: image).jpegData(compressionQuality: quality)
                else { continue }
                if content.count <= Self.maximumOutputBytes {
                    guard let thumbnail = thumbnailData(image: image) else {
                        throw ReceiptPreparationError.invalidImage
                    }
                    return PreparedReceipt(
                        content: content,
                        thumbnail: thumbnail,
                        ocrImage: content,
                        originalFilename: sanitizedFilename(suggestedFilename, extension: "jpg"),
                        contentType: AttachmentContentType.jpeg.rawValue,
                        fileExtension: "jpg",
                        originalRetained: false
                    )
                }
            }
        }
        throw ReceiptPreparationError.outputTooLarge
    }

    private func preparePDF(data: Data, suggestedFilename: String) throws -> PreparedReceipt {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ReceiptPreparationError.invalidPDF
        }
        guard !document.isEncrypted else { throw ReceiptPreparationError.encryptedPDF }
        guard document.pageCount <= Self.maximumPDFPages else {
            throw ReceiptPreparationError.tooManyPDFPages
        }
        document.documentAttributes = [:]
        guard let sanitized = document.dataRepresentation(),
              sanitized.count <= Self.maximumOutputBytes,
              let firstPage = document.page(at: 0)
        else {
            throw ReceiptPreparationError.outputTooLarge
        }
        let ocrImage = firstPage.thumbnail(
            of: CGSize(width: 1_600, height: 2_000),
            for: .cropBox
        )
        guard let ocrData = ocrImage.jpegData(compressionQuality: 0.82),
              let cgImage = ocrImage.cgImage,
              let thumbnail = thumbnailData(image: cgImage)
        else {
            throw ReceiptPreparationError.invalidPDF
        }
        return PreparedReceipt(
            content: sanitized,
            thumbnail: thumbnail,
            ocrImage: ocrData,
            originalFilename: sanitizedFilename(suggestedFilename, extension: "pdf"),
            contentType: AttachmentContentType.pdf.rawValue,
            fileExtension: "pdf",
            originalRetained: false
        )
    }

    private func downsample(source: CGImageSource, maximumDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ] as CFDictionary)
    }

    private func thumbnailData(image: CGImage) -> Data? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(320 / max(width, height), 1)
        let size = CGSize(width: max(width * scale, 1), height: max(height * scale, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.68)
    }

    private func sanitizedFilename(_ value: String, extension fileExtension: String) -> String {
        let rawBase = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        let filtered = rawBase.unicodeScalars.filter {
            $0.value >= 32 && $0.value != 47 && $0.value != 92 && $0.value != 127
        }
        let base = String(String.UnicodeScalarView(filtered))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let safeBase = base.isEmpty ? "receipt" : String(base.prefix(170))
        return "\(safeBase).\(fileExtension)"
    }
}
