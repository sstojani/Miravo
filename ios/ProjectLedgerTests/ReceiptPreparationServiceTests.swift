import CryptoKit
import Foundation
import Testing
import UIKit
@testable import ProjectLedger

@MainActor
struct ReceiptPreparationServiceTests {
    @Test func normalizesImageAndStoresProtectedQueueFilesWithVerifiedDigest() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 800)).image {
            context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 800))
            UIColor.black.setFill()
            context.fill(CGRect(x: 100, y: 100, width: 1_000, height: 120))
        }
        let png = try #require(source.pngData())
        let prepared = try await ReceiptPreparationService().prepare(
            data: png,
            suggestedFilename: "../My Receipt.png",
            declaredContentType: "image/png"
        )

        #expect(prepared.contentType == "image/jpeg")
        #expect(prepared.fileExtension == "jpg")
        #expect(prepared.originalFilename == "My Receipt.jpg")
        #expect(prepared.originalRetained == false)
        #expect(prepared.content.starts(with: [0xFF, 0xD8]))
        #expect(prepared.content.count <= ReceiptPreparationService.maximumOutputBytes)
        #expect(!prepared.thumbnail.isEmpty)

        let root = FileManager.default.temporaryDirectory
            .appending(path: "miravo-receipt-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let paths = try store.store(prepared, attachmentID: UUID())
        let checksum = SHA256.hash(data: prepared.content)
            .map { String(format: "%02x", $0) }
            .joined()
        let verified = try store.verify(
            relativePath: paths.contentRelativePath,
            expectedByteCount: Int64(prepared.content.count),
            expectedChecksumSHA256: checksum
        )

        #expect(verified.checksumSHA256 == checksum)
        let macroSafeExpectation1: Bool = try evaluateExpectation {
            try store.loadThumbnail(relativePath: paths.thumbnailRelativePath) == prepared.thumbnail
        }
        #expect(macroSafeExpectation1)
        let downloaded = try store.storeDownloaded(
            prepared.content,
            attachmentID: UUID(),
            contentType: .jpeg,
            expectedByteCount: Int64(prepared.content.count),
            expectedChecksumSHA256: checksum
        )
        #expect(downloaded.verifiedFile.checksumSHA256 == checksum)
        #expect(downloaded.relativePath.hasPrefix("downloaded/"))
        store.remove(paths)
        store.remove(relativePath: downloaded.relativePath)
        #expect(!FileManager.default.fileExists(atPath: verified.url.path))
    }

    @Test func sanitizesPDFAndCreatesReviewImageWithoutRetainingOriginal() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let source = renderer.pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(bounds)
            UIColor.black.setFill()
            context.fill(CGRect(x: 48, y: 48, width: 300, height: 40))
        }

        let prepared = try await ReceiptPreparationService().prepare(
            data: source,
            suggestedFilename: "invoice.pdf",
            declaredContentType: "application/pdf"
        )

        #expect(prepared.contentType == "application/pdf")
        #expect(prepared.originalFilename == "invoice.pdf")
        #expect(prepared.originalRetained == false)
        #expect(prepared.content.starts(with: Data("%PDF-".utf8)))
        #expect(!prepared.thumbnail.isEmpty)
        #expect(!prepared.ocrImage.isEmpty)
    }

    @Test func rejectsEmptyOversizedAndInvalidInput() async {
        await #expect(throws: ReceiptPreparationError.emptyFile) {
            try await ReceiptPreparationService().prepare(
                data: Data(),
                suggestedFilename: "empty.jpg"
            )
        }
        let tooLarge = Data(
            repeating: 0,
            count: ReceiptPreparationService.maximumInputBytes + 1
        )
        await #expect(throws: ReceiptPreparationError.inputTooLarge) {
            try await ReceiptPreparationService().prepare(
                data: tooLarge,
                suggestedFilename: "large.jpg"
            )
        }
        await #expect(throws: ReceiptPreparationError.invalidImage) {
            try await ReceiptPreparationService().prepare(
                data: Data("not-an-image".utf8),
                suggestedFilename: "invalid.jpg"
            )
        }
    }

    @Test func fileStoreRejectsTraversalAndChecksumMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "miravo-receipt-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)

        #expect(throws: AttachmentLocalFileError.invalidRelativePath) {
            try store.loadThumbnail(relativePath: "../outside.jpg")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "receipt.jpg")
        try Data("safe".utf8).write(to: file)
        #expect(throws: AttachmentLocalFileError.checksumMismatch) {
            try store.verify(
                relativePath: "receipt.jpg",
                expectedByteCount: 4,
                expectedChecksumSHA256: String(repeating: "0", count: 64)
            )
        }
    }
}
