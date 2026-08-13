from __future__ import annotations

import hashlib
import os
import secrets
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import BinaryIO, cast

from django.conf import settings
from django.utils.module_loading import import_string

from apps.attachments.models import Attachment

AttachmentScanner = Callable[[Path, str], str]
MINIMUM_CONTAINER_HEADER_BYTES = 12
CAPTURED_HEADER_BYTES = 64


class AttachmentStorageError(Exception):
    def __init__(self, code: str, field: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.field = field
        self.message = message


@dataclass(frozen=True)
class StagedUpload:
    path: Path
    byte_count: int
    checksum_sha256: str
    detected_content_type: str

    def discard(self) -> None:
        self.path.unlink(missing_ok=True)


def _ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def _incoming_directory() -> Path:
    path = Path(settings.MEDIA_ROOT) / ".incoming"
    _ensure_private_directory(path)
    return path


def generated_storage_key(*, quarantined: bool = False) -> str:
    token = secrets.token_hex(32)
    area = "quarantine" if quarantined else "private"
    return f"{area}/{token[:2]}/{token[2:4]}/{token}"


def private_media_path(storage_key: str) -> Path:
    relative = PurePosixPath(storage_key)
    if (
        relative.is_absolute()
        or not relative.parts
        or relative.parts[0] not in {"private", "quarantine"}
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise AttachmentStorageError(
            "invalid_storage_key", "storage", "The private storage key is invalid."
        )
    root = Path(settings.MEDIA_ROOT).resolve()
    destination = (root / Path(*relative.parts)).resolve()
    if not destination.is_relative_to(root):
        raise AttachmentStorageError(
            "invalid_storage_key", "storage", "The private storage key is invalid."
        )
    return destination


def detect_content_type(header: bytes) -> str | None:
    detected: str | None = None
    if header.startswith(b"\xff\xd8\xff"):
        detected = Attachment.ContentType.JPEG
    elif header.startswith(b"\x89PNG\r\n\x1a\n"):
        detected = Attachment.ContentType.PNG
    elif header.startswith(b"%PDF-"):
        detected = Attachment.ContentType.PDF
    elif (
        len(header) >= MINIMUM_CONTAINER_HEADER_BYTES
        and header[:4] == b"RIFF"
        and header[8:12] == b"WEBP"
    ):
        detected = Attachment.ContentType.WEBP
    elif len(header) >= MINIMUM_CONTAINER_HEADER_BYTES and header[4:8] == b"ftyp":
        brand = header[8:12]
        if brand in {b"heic", b"heix", b"hevc", b"hevx"}:
            detected = Attachment.ContentType.HEIC
        elif brand in {b"heim", b"heis", b"mif1", b"msf1"}:
            detected = Attachment.ContentType.HEIF
    return detected


def stage_upload(stream: BinaryIO, *, maximum_bytes: int) -> StagedUpload:
    file_descriptor, raw_path = tempfile.mkstemp(prefix="upload-", dir=_incoming_directory())
    path = Path(raw_path)
    digest = hashlib.sha256()
    total = 0
    header = bytearray()
    try:
        with os.fdopen(file_descriptor, "wb") as destination:
            os.chmod(path, 0o600)
            while True:
                chunk = stream.read(settings.ATTACHMENT_UPLOAD_CHUNK_BYTES)
                if not chunk:
                    break
                if not isinstance(chunk, bytes):
                    raise AttachmentStorageError(
                        "invalid_upload_body", "content", "Upload body must contain binary data."
                    )
                total += len(chunk)
                if total > maximum_bytes:
                    raise AttachmentStorageError(
                        "attachment_too_large",
                        "content",
                        "Attachment exceeds the configured size limit.",
                    )
                if len(header) < CAPTURED_HEADER_BYTES:
                    header.extend(chunk[: CAPTURED_HEADER_BYTES - len(header)])
                digest.update(chunk)
                destination.write(chunk)
            destination.flush()
            os.fsync(destination.fileno())
        if total == 0:
            raise AttachmentStorageError(
                "empty_attachment", "content", "Attachment content cannot be empty."
            )
        detected = detect_content_type(bytes(header))
        if detected is None:
            raise AttachmentStorageError(
                "unsupported_attachment_content",
                "content_type",
                "Attachment content does not match a supported file type.",
            )
        return StagedUpload(
            path=path,
            byte_count=total,
            checksum_sha256=digest.hexdigest(),
            detected_content_type=detected,
        )
    except Exception:
        path.unlink(missing_ok=True)
        raise


def validate_staged_upload(staged: StagedUpload, attachment: Attachment) -> None:
    if staged.byte_count != attachment.byte_count:
        raise AttachmentStorageError(
            "attachment_size_mismatch",
            "byte_count",
            "Uploaded bytes do not match the reserved byte count.",
        )
    if staged.checksum_sha256 != attachment.checksum_sha256:
        raise AttachmentStorageError(
            "attachment_checksum_mismatch",
            "checksum_sha256",
            "Uploaded bytes do not match the reserved checksum.",
        )
    detected = staged.detected_content_type
    expected = attachment.content_type
    compatible_heif = {detected, expected} <= {
        Attachment.ContentType.HEIC,
        Attachment.ContentType.HEIF,
    }
    if detected != expected and not compatible_heif:
        raise AttachmentStorageError(
            "attachment_content_type_mismatch",
            "content_type",
            "Uploaded content does not match the reserved media type.",
        )


def scan_staged_upload(staged: StagedUpload, content_type: str) -> str:
    scanner_path = settings.ATTACHMENT_SCANNER
    if not scanner_path:
        return Attachment.ScanStatus.NOT_CONFIGURED
    try:
        scanner = cast(AttachmentScanner, import_string(scanner_path))
        result = scanner(staged.path, content_type)
    except Exception:  # noqa: BLE001 - scanner failure quarantines instead of leaking details
        return Attachment.ScanStatus.ERROR
    if result == "clean":
        return Attachment.ScanStatus.CLEAN
    if result == "blocked":
        return Attachment.ScanStatus.BLOCKED
    return Attachment.ScanStatus.ERROR


def move_staged_upload(staged: StagedUpload, storage_key: str) -> Path:
    destination = private_media_path(storage_key)
    _ensure_private_directory(destination.parent)
    os.replace(staged.path, destination)
    os.chmod(destination, 0o600)
    return destination
