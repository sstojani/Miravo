import CryptoKit
import PDFKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ReceiptReviewSelection: Equatable, Sendable {
    let merchant: String?
    let occurredAt: Date?
    let money: Money?

    var hasTransactionChanges: Bool {
        merchant != nil || occurredAt != nil || money != nil
    }
}

private enum ReceiptReviewError: Error {
    case invalidAmount
    case currencyMismatch
}

struct ReceiptCaptureView: View {
    let scopeKey: String
    let transaction: LedgerTransaction
    let canApplyDate: Bool
    let canApplyAmount: Bool
    let onApplyReview: @MainActor (ReceiptReviewSelection) throws -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var preparedReceipt: PreparedReceipt?
    @State private var ocrSucceeded = false
    @State private var merchant = ""
    @State private var total = ""
    @State private var currencyCode = ""
    @State private var occurredAt = Date.now
    @State private var tax = ""
    @State private var applyMerchant = false
    @State private var applyDate = false
    @State private var applyAmount = false
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var receiptWasSaved = false
    @State private var safeError: String?

    private let fileStore = AttachmentFileStore()

    var body: some View {
        NavigationStack {
            Form {
                if let preparedReceipt {
                    reviewSections(preparedReceipt)
                } else {
                    sourceSections
                }
            }
            .navigationTitle(
                preparedReceipt == nil
                    ? String(localized: "Add receipt")
                    : String(localized: "Review receipt")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isProcessing || isSaving)
                }
                if preparedReceipt != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Attach") {
                            Task { await attachReceipt() }
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .interactiveDismissDisabled(isProcessing || isSaving)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image, .pdf]
            ) { result in
                switch result {
                case let .success(url):
                    Task { await importFile(url) }
                case .failure:
                    safeError = String(localized: "The selected receipt could not be opened.")
                }
            }
            .sheet(isPresented: $showingCamera) {
                ReceiptCameraPicker(
                    onCapture: { data in
                        showingCamera = false
                        Task {
                            await prepare(
                                data: data,
                                filename: "receipt-camera.jpg",
                                contentType: AttachmentContentType.jpeg.rawValue
                            )
                        }
                    },
                    onCancel: { showingCamera = false }
                )
                .ignoresSafeArea()
            }
            .alert(
                receiptWasSaved
                    ? String(localized: "Receipt saved")
                    : String(localized: "Could not add receipt"),
                isPresented: Binding(
                    get: { safeError != nil },
                    set: { if !$0 { safeError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    if receiptWasSaved { dismiss() }
                }
            } message: {
                Text(safeError ?? "")
            }
        }
    }

    @ViewBuilder
    private var sourceSections: some View {
        Section {
            Text("The receipt is prepared and stored on this iPhone before any upload begins.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Choose a source") {
            Button("Take photo", systemImage: "camera") {
                showingCamera = true
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera) || isProcessing)

            PhotosPicker(
                selection: $selectedPhoto,
                matching: .images,
                preferredItemEncoding: .current
            ) {
                Label("Choose photo", systemImage: "photo.on.rectangle")
            }
            .disabled(isProcessing)

            Button("Choose image or PDF", systemImage: "doc") {
                showingFileImporter = true
            }
            .disabled(isProcessing)
        }

        if isProcessing {
            Section {
                HStack {
                    ProgressView()
                    Text("Preparing receipt on this iPhone…")
                }
                .accessibilityElement(children: .combine)
            }
        }

        Section("Privacy") {
            Label(
                "Images are normalized to remove unnecessary metadata. OCR runs on this iPhone.",
                systemImage: "hand.raised"
            )
            .font(.footnote)
            Text("Receipt text is never written to logs. Only the fields you confirm can update this transaction.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func reviewSections(_ receipt: PreparedReceipt) -> some View {
        Section("Receipt preview") {
            if let image = UIImage(data: receipt.thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Receipt preview")
            }
            LabeledContent("File", value: receipt.originalFilename)
            LabeledContent(
                "Prepared size",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(receipt.content.count),
                    countStyle: .file
                )
            )
            Label(
                ocrSucceeded
                    ? String(localized: "On-device text suggestions are ready for review.")
                    : String(localized: "No reliable text suggestions were found. You can still attach the receipt."),
                systemImage: ocrSucceeded ? "checkmark.circle" : "text.magnifyingglass"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Review suggestions") {
            TextField("Merchant", text: $merchant)
                .textInputAutocapitalization(.words)
            TextField("Total", text: $total)
                .keyboardType(.decimalPad)
            TextField("Currency", text: $currencyCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            DatePicker("Date", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
            TextField("Tax", text: $tax)
                .keyboardType(.decimalPad)
            Text("Tax is shown only during this review and is not stored as a transaction field.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Apply to transaction") {
            Toggle("Update merchant", isOn: $applyMerchant)
            Toggle("Update date", isOn: $applyDate)
                .disabled(!canApplyDate)
            Toggle("Update amount", isOn: $applyAmount)
                .disabled(!canApplyAmount)
            if !canApplyDate || !canApplyAmount {
                Text("Converted or split expenses keep their existing financial fields. You can edit them separately with full context.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Button("Choose another receipt", systemImage: "arrow.counterclockwise") {
                resetPreparedReceipt()
            }
            .disabled(isSaving)
        }

        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("Saving receipt locally…")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem) async {
        isProcessing = true
        defer {
            isProcessing = false
            selectedPhoto = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReceiptPreparationError.emptyFile
            }
            let contentType = item.supportedContentTypes.first
            let fileExtension = contentType?.preferredFilenameExtension ?? "jpg"
            await prepare(
                data: data,
                filename: "receipt-photo.\(fileExtension)",
                contentType: contentType?.preferredMIMEType,
                managesProcessingState: false
            )
        } catch {
            safeError = preparationMessage(error)
        }
    }

    @MainActor
    private func importFile(_ url: URL) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                let hasSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
                let values = try url.resourceValues(forKeys: [
                    .contentTypeKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                ])
                guard values.isRegularFile != false else {
                    throw ReceiptPreparationError.unsupportedType
                }
                if let size = values.fileSize,
                   size > ReceiptPreparationService.maximumInputBytes {
                    throw ReceiptPreparationError.inputTooLarge
                }
                return (
                    try Data(contentsOf: url, options: [.mappedIfSafe]),
                    url.lastPathComponent,
                    values.contentType?.preferredMIMEType
                )
            }.value
            await prepare(
                data: imported.0,
                filename: imported.1,
                contentType: imported.2,
                managesProcessingState: false
            )
        } catch {
            safeError = preparationMessage(error)
        }
    }

    @MainActor
    private func prepare(
        data: Data,
        filename: String,
        contentType: String?,
        managesProcessingState: Bool = true
    ) async {
        if managesProcessingState { isProcessing = true }
        defer {
            if managesProcessingState { isProcessing = false }
        }
        do {
            let preparationService = ReceiptPreparationService()
            let receipt = try await preparationService.prepare(
                data: data,
                suggestedFilename: filename,
                declaredContentType: contentType
            )
            let proposal: ReceiptOCRProposal
            do {
                let ocrService = ReceiptOCRService()
                proposal = try await ocrService.recognize(imageData: receipt.ocrImage)
                ocrSucceeded = proposal != .empty
            } catch {
                proposal = .empty
                ocrSucceeded = false
            }
            preparedReceipt = receipt
            merchant = proposal.merchant
            total = proposal.totalText
            currencyCode = proposal.currencyCode.isEmpty
                ? transaction.currencyCode
                : proposal.currencyCode
            occurredAt = proposal.occurredAt ?? transaction.occurredAt
            tax = proposal.taxText
            applyMerchant = !proposal.merchant.isEmpty
            applyDate = proposal.occurredAt != nil && canApplyDate
            applyAmount = !proposal.totalText.isEmpty &&
                proposal.currencyCode.uppercased() == transaction.currencyCode &&
                canApplyAmount
        } catch {
            safeError = preparationMessage(error)
        }
    }

    @MainActor
    private func attachReceipt() async {
        guard let receipt = preparedReceipt else { return }
        isSaving = true
        receiptWasSaved = false
        var storedPaths: StoredReceiptPaths?
        do {
            let review = try reviewSelection()
            let attachmentID = UUID()
            let paths = try fileStore.store(receipt, attachmentID: attachmentID)
            storedPaths = paths
            let checksum = SHA256.hash(data: receipt.content)
                .map { String(format: "%02x", $0) }
                .joined()
            let queue = AttachmentTransferQueue(modelContainer: modelContext.container)
            try await queue.enqueue(
                AttachmentTransferRequest(
                    attachmentID: attachmentID,
                    scopeKey: scopeKey,
                    transactionID: transaction.id,
                    localRelativePath: paths.contentRelativePath,
                    originalFilename: receipt.originalFilename,
                    contentType: receipt.contentType,
                    byteCount: Int64(receipt.content.count),
                    checksumSHA256: checksum,
                    originalRetained: receipt.originalRetained,
                    thumbnailRelativePath: paths.thumbnailRelativePath
                )
            )
            if review.hasTransactionChanges {
                do {
                    try onApplyReview(review)
                } catch {
                    receiptWasSaved = true
                    safeError = String(
                        localized: "The receipt was saved, but its reviewed fields could not update the transaction."
                    )
                }
            }
            Task { await sync.synchronize(session: session) }
            isSaving = false
            if safeError == nil { dismiss() }
        } catch {
            if let storedPaths { fileStore.remove(storedPaths) }
            isSaving = false
            safeError = reviewMessage(error)
        }
    }

    private func reviewSelection() throws -> ReceiptReviewSelection {
        let reviewedMoney: Money?
        if applyAmount {
            guard currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ==
                transaction.currencyCode
            else {
                throw ReceiptReviewError.currencyMismatch
            }
            reviewedMoney = try parseReviewedMoney(total)
        } else {
            reviewedMoney = nil
        }
        return ReceiptReviewSelection(
            merchant: applyMerchant ? merchant : nil,
            occurredAt: applyDate ? occurredAt : nil,
            money: reviewedMoney
        )
    }

    private func parseReviewedMoney(_ value: String) throws -> Money {
        for locale in [Locale.current, Locale(identifier: "en_US_POSIX"), Locale(identifier: "de_DE")] {
            if let money = try? Money.positive(
                majorUnits: value,
                currencyCode: transaction.currencyCode,
                exponent: transaction.currencyExponent,
                locale: locale
            ) {
                return money
            }
        }
        throw ReceiptReviewError.invalidAmount
    }

    private func resetPreparedReceipt() {
        preparedReceipt = nil
        ocrSucceeded = false
        merchant = ""
        total = ""
        currencyCode = ""
        tax = ""
        applyMerchant = false
        applyDate = false
        applyAmount = false
    }

    private func preparationMessage(_ error: Error) -> String {
        guard let preparationError = error as? ReceiptPreparationError else {
            return String(localized: "The selected receipt could not be prepared safely.")
        }
        switch preparationError {
        case .inputTooLarge, .outputTooLarge:
            return String(
                localized: "The receipt is too large to store safely. Choose a smaller image or PDF."
            )
        case .imageDimensionsTooLarge:
            return String(localized: "The image dimensions are too large. Choose a smaller image.")
        case .encryptedPDF:
            return String(localized: "Encrypted PDFs are not supported. Choose an unlocked copy.")
        case .tooManyPDFPages:
            return String(localized: "The PDF has too many pages. Choose a shorter document.")
        default:
            return String(localized: "The selected receipt could not be prepared safely.")
        }
    }

    private func reviewMessage(_ error: Error) -> String {
        if let reviewError = error as? ReceiptReviewError {
            switch reviewError {
            case .currencyMismatch:
                return String(
                    localized: "The reviewed currency must match the transaction currency."
                )
            case .invalidAmount:
                return String(localized: "Enter a valid positive receipt total.")
            }
        }
        if error is MoneyError {
            return String(localized: "Enter a valid positive receipt total.")
        }
        return String(localized: "The receipt could not be saved locally. No upload was started.")
    }
}

@MainActor
private struct ReceiptCameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (Data) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.92)
            else {
                onCancel()
                return
            }
            onCapture(data)
        }
    }
}

struct ReceiptAttachmentRow: View {
    let attachment: LocalAttachment
    let transfer: AttachmentTransfer?

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var thumbnailData: Data?
    @State private var preview: ReceiptPreviewItem?
    @State private var isOpening = false
    @State private var safeError: String?

    var body: some View {
        Button {
            Task { await openReceipt() }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let thumbnailData, let image = UIImage(data: thumbnailData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: attachment.contentType == AttachmentContentType.pdf.rawValue
                            ? "doc.richtext"
                            : "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.originalFilename)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(
                        fromByteCount: attachment.byteCount,
                        countStyle: .file
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Label(statusText, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if isOpening {
                    ProgressView()
                        .accessibilityLabel("Opening receipt")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpening || isQuarantined)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(
            isQuarantined
                ? String(localized: "This receipt cannot be opened because the server quarantined it.")
                : String(localized: "Opens the private receipt.")
        ))
        .task(id: attachment.thumbnailRelativePath) {
            guard let path = attachment.thumbnailRelativePath else { return }
            thumbnailData = try? AttachmentFileStore().loadThumbnail(relativePath: path)
        }
        .sheet(item: $preview) { item in
            ReceiptPreviewView(item: item)
        }
        .alert("Could not open receipt", isPresented: Binding(
            get: { safeError != nil },
            set: { if !$0 { safeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(safeError ?? "")
        }
        .contextMenu {
            if transfer?.state == .failed || transfer?.state == .cancelled {
                Button("Retry upload", systemImage: "arrow.clockwise") {
                    Task { await retryUpload() }
                }
            }
            if transfer?.state == .pending || transfer?.state == .failed {
                Button("Cancel upload", systemImage: "xmark.circle", role: .destructive) {
                    Task { await cancelUpload() }
                }
            }
        }
    }

    private var isQuarantined: Bool {
        attachment.uploadState == .quarantined ||
            [.blocked, .error].contains(attachment.scanStatus)
    }

    private var statusText: String {
        if isQuarantined {
            return String(localized: "Quarantined")
        }
        switch transfer?.state {
        case .pending:
            return String(localized: "Pending upload")
        case .uploading:
            return String(localized: "Uploading")
        case .failed:
            return String(localized: "Upload failed")
        case .cancelled:
            return String(localized: "Upload cancelled")
        case .uploaded:
            return String(localized: "Stored privately")
        case nil:
            return attachment.uploadState == .ready
                ? String(localized: "Stored privately")
                : String(localized: "Pending upload")
        }
    }

    private var statusSymbol: String {
        if isQuarantined {
            return "exclamationmark.shield"
        }
        switch transfer?.state {
        case .pending:
            return "clock"
        case .uploading:
            return "arrow.up.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark.circle"
        case .uploaded:
            return "lock.shield"
        case nil:
            return attachment.uploadState == .ready ? "lock.shield" : "clock"
        }
    }

    private var statusColor: Color {
        if isQuarantined {
            return LedgerTheme.negative
        }
        return transfer?.state == .failed ? LedgerTheme.negative : .secondary
    }

    @MainActor
    private func openReceipt() async {
        isOpening = true
        defer { isOpening = false }
        let fileStore = AttachmentFileStore()
        let knownPath = attachment.contentRelativePath ?? transfer?.localRelativePath
        if let knownPath,
           let url = try? fileStore.verifiedPreview(
               relativePath: knownPath,
               expectedByteCount: attachment.byteCount,
               expectedChecksumSHA256: attachment.checksumSHA256
           ) {
            preview = ReceiptPreviewItem(url: url, contentType: attachment.contentType)
            return
        }
        guard attachment.uploadState == .ready,
              let contentType = AttachmentContentType(rawValue: attachment.contentType)
        else {
            safeError = String(
                localized: "The local receipt file is unavailable. It will remain queued for upload."
            )
            return
        }
        do {
            let data = try await authenticatedDownload()
            let stored = try fileStore.storeDownloaded(
                data,
                attachmentID: attachment.id,
                contentType: contentType,
                expectedByteCount: attachment.byteCount,
                expectedChecksumSHA256: attachment.checksumSHA256
            )
            let previousPath = attachment.contentRelativePath
            attachment.contentRelativePath = stored.relativePath
            do {
                try modelContext.save()
            } catch {
                attachment.contentRelativePath = previousPath
                fileStore.remove(relativePath: stored.relativePath)
                throw error
            }
            preview = ReceiptPreviewItem(
                url: stored.verifiedFile.url,
                contentType: attachment.contentType
            )
        } catch is URLError {
            safeError = String(localized: "The server is unreachable. Try again when connected.")
        } catch {
            safeError = String(
                localized: "The private receipt could not be downloaded or verified."
            )
        }
    }

    @MainActor
    private func authenticatedDownload() async throws -> Data {
        guard let authentication = try await session.synchronizationContext() else {
            throw ReceiptPreviewError.authenticationRequired
        }
        do {
            return try await download(authentication: authentication)
        } catch let error as APIClientError where error.statusCode == 401 {
            _ = await sync.synchronize(session: session)
            guard let refreshed = try await session.synchronizationContext() else {
                throw ReceiptPreviewError.authenticationRequired
            }
            return try await download(authentication: refreshed)
        }
    }

    private func download(authentication: SyncAuthenticationContext) async throws -> Data {
        let tokens = try await authentication.tokenStore.load(
            scopeKey: authentication.scopeKey
        ) ?? authentication.tokens
        return try await APIClient(baseURL: authentication.baseURL).downloadAttachmentContent(
            id: attachment.id,
            expectedContentType: attachment.contentType,
            maximumByteCount: AttachmentTransferQueuePolicy.defaultMaximumByteCount,
            accessToken: tokens.accessToken
        )
    }

    @MainActor
    private func cancelUpload() async {
        do {
            try await AttachmentTransferQueue(modelContainer: modelContext.container).cancel(
                scopeKey: attachment.scopeKey,
                attachmentID: attachment.id
            )
        } catch {
            safeError = String(localized: "The pending receipt upload could not be cancelled.")
        }
    }

    @MainActor
    private func retryUpload() async {
        do {
            try await AttachmentTransferQueue(modelContainer: modelContext.container).retry(
                scopeKey: attachment.scopeKey,
                attachmentID: attachment.id
            )
            _ = await sync.synchronize(session: session)
        } catch {
            safeError = String(localized: "The receipt upload could not be prepared for retry.")
        }
    }
}

private enum ReceiptPreviewError: Error {
    case authenticationRequired
}

private struct ReceiptPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let contentType: String
}

private struct ReceiptPreviewView: View {
    let item: ReceiptPreviewItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if item.contentType == AttachmentContentType.pdf.rawValue {
                    ReceiptPDFView(url: item.url)
                } else if let image = UIImage(contentsOfFile: item.url.path) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                    .background(Color.black.opacity(0.04))
                } else {
                    ContentUnavailableView(
                        "Receipt unavailable",
                        systemImage: "doc.questionmark",
                        description: Text("The verified receipt cannot be displayed on this iPhone.")
                    )
                }
            }
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ReceiptPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
