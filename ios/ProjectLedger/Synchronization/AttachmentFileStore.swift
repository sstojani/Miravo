import CryptoKit
import Foundation

enum AttachmentLocalFileError: Error, Equatable, Sendable {
    case invalidRelativePath
    case unavailable
    case notRegularFile
    case sizeMismatch
    case checksumMismatch
    case fileTooLarge
}

struct VerifiedAttachmentFile: Equatable, Sendable {
    let url: URL
    let byteCount: Int64
    let checksumSHA256: String
}

struct StoredReceiptPaths: Equatable, Sendable {
    let contentRelativePath: String
    let thumbnailRelativePath: String
}

struct StoredDownloadedAttachment: Equatable, Sendable {
    let relativePath: String
    let verifiedFile: VerifiedAttachmentFile
}

struct AttachmentFileStore: Sendable {
    static let readChunkBytes = 64 * 1_024

    let rootURL: URL
    let maximumByteCount: Int64

    init(
        rootURL: URL = AttachmentFileStore.defaultRootURL,
        maximumByteCount: Int64 = AttachmentTransferQueuePolicy.defaultMaximumByteCount
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.maximumByteCount = maximumByteCount
    }

    static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appending(path: "Miravo", directoryHint: .isDirectory)
            .appending(path: "Receipts", directoryHint: .isDirectory)
    }

    func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: rootURL.path
        )
    }

    func verify(
        relativePath: String,
        expectedByteCount: Int64,
        expectedChecksumSHA256: String
    ) throws -> VerifiedAttachmentFile {
        guard maximumByteCount > 0,
              expectedByteCount > 0,
              expectedByteCount <= maximumByteCount
        else {
            throw AttachmentLocalFileError.fileTooLarge
        }
        try prepareRoot()
        let fileURL = try resolvedURL(relativePath: relativePath)
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isSymbolicLink != true else {
            throw AttachmentLocalFileError.notRegularFile
        }
        guard values.isRegularFile == true else {
            throw AttachmentLocalFileError.notRegularFile
        }
        guard let size = values.fileSize,
              Int64(size) == expectedByteCount
        else {
            throw AttachmentLocalFileError.sizeMismatch
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw AttachmentLocalFileError.unavailable
        }
        defer { try? handle.close() }
        var digest = SHA256()
        var total: Int64 = 0
        do {
            while let data = try handle.read(upToCount: Self.readChunkBytes), !data.isEmpty {
                total += Int64(data.count)
                guard total <= maximumByteCount else {
                    throw AttachmentLocalFileError.fileTooLarge
                }
                digest.update(data: data)
            }
        } catch let error as AttachmentLocalFileError {
            throw error
        } catch {
            throw AttachmentLocalFileError.unavailable
        }
        guard total == expectedByteCount else {
            throw AttachmentLocalFileError.sizeMismatch
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == expectedChecksumSHA256 else {
            throw AttachmentLocalFileError.checksumMismatch
        }
        return VerifiedAttachmentFile(
            url: fileURL,
            byteCount: total,
            checksumSHA256: checksum
        )
    }

    func store(_ receipt: PreparedReceipt, attachmentID: UUID) throws -> StoredReceiptPaths {
        guard !receipt.content.isEmpty,
              Int64(receipt.content.count) <= maximumByteCount,
              !receipt.thumbnail.isEmpty,
              receipt.thumbnail.count <= 1_048_576
        else {
            throw AttachmentLocalFileError.fileTooLarge
        }
        try prepareRoot()
        let identifier = attachmentID.uuidString.lowercased()
        let contentRelativePath = "pending/\(identifier).\(receipt.fileExtension)"
        let thumbnailRelativePath = "thumbnails/\(identifier).jpg"
        let contentURL = try resolvedURL(relativePath: contentRelativePath)
        let thumbnailURL = try resolvedURL(relativePath: thumbnailRelativePath)
        do {
            try createProtectedDirectory(contentURL.deletingLastPathComponent())
            try createProtectedDirectory(thumbnailURL.deletingLastPathComponent())
            try receipt.content.write(to: contentURL, options: [.atomic])
            try protectFile(contentURL)
            try receipt.thumbnail.write(to: thumbnailURL, options: [.atomic])
            try protectFile(thumbnailURL)
        } catch {
            try? FileManager.default.removeItem(at: contentURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw AttachmentLocalFileError.unavailable
        }
        return StoredReceiptPaths(
            contentRelativePath: contentRelativePath,
            thumbnailRelativePath: thumbnailRelativePath
        )
    }

    func remove(_ paths: StoredReceiptPaths) {
        for relativePath in [paths.contentRelativePath, paths.thumbnailRelativePath] {
            guard let url = try? resolvedURL(relativePath: relativePath) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func remove(relativePath: String) {
        guard let url = try? resolvedURL(relativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func loadThumbnail(relativePath: String) throws -> Data {
        try prepareRoot()
        let thumbnailURL = try resolvedURL(relativePath: relativePath)
        let values = try thumbnailURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AttachmentLocalFileError.notRegularFile
        }
        guard let fileSize = values.fileSize, fileSize > 0, fileSize <= 1_048_576 else {
            throw AttachmentLocalFileError.fileTooLarge
        }
        do {
            return try Data(contentsOf: thumbnailURL, options: [.mappedIfSafe])
        } catch {
            throw AttachmentLocalFileError.unavailable
        }
    }

    func storeDownloaded(
        _ data: Data,
        attachmentID: UUID,
        contentType: AttachmentContentType,
        expectedByteCount: Int64,
        expectedChecksumSHA256: String
    ) throws -> StoredDownloadedAttachment {
        guard !data.isEmpty,
              Int64(data.count) == expectedByteCount,
              expectedByteCount <= maximumByteCount
        else {
            throw AttachmentLocalFileError.sizeMismatch
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedChecksumSHA256 else {
            throw AttachmentLocalFileError.checksumMismatch
        }
        try prepareRoot()
        let relativePath = "downloaded/\(attachmentID.uuidString.lowercased()).\(fileExtension(contentType))"
        let destination = try resolvedURL(relativePath: relativePath)
        do {
            try createProtectedDirectory(destination.deletingLastPathComponent())
            try data.write(to: destination, options: [.atomic])
            try protectFile(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw AttachmentLocalFileError.unavailable
        }
        let verified = try verify(
            relativePath: relativePath,
            expectedByteCount: expectedByteCount,
            expectedChecksumSHA256: expectedChecksumSHA256
        )
        return StoredDownloadedAttachment(
            relativePath: relativePath,
            verifiedFile: verified
        )
    }

    func verifiedPreview(
        relativePath: String,
        expectedByteCount: Int64,
        expectedChecksumSHA256: String
    ) throws -> URL {
        try verify(
            relativePath: relativePath,
            expectedByteCount: expectedByteCount,
            expectedChecksumSHA256: expectedChecksumSHA256
        ).url
    }

    private func resolvedURL(relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw AttachmentLocalFileError.invalidRelativePath
        }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var candidate = resolvedRoot
        for component in parts {
            candidate = candidate.appending(path: String(component)).standardizedFileURL
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw AttachmentLocalFileError.notRegularFile
            }
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw AttachmentLocalFileError.invalidRelativePath
        }
        return resolvedCandidate
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func protectFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func fileExtension(_ contentType: AttachmentContentType) -> String {
        switch contentType {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .heif: "heif"
        case .webp: "webp"
        case .pdf: "pdf"
        }
    }
}
