from __future__ import annotations

import hashlib
import hmac
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

import jwt
from django.conf import settings
from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import AuthenticationFailed

from apps.audit.services import record_audit_event
from apps.users.models import DeviceSession, RefreshCredential, User

REFRESH_TOKEN_PART_COUNT = 3
REFRESH_TOKEN_PREFIX_MAX_LENGTH = 16


@dataclass(frozen=True)
class SessionTokens:
    access_token: str
    access_expires_at: datetime
    refresh_token: str
    refresh_expires_at: datetime
    session: DeviceSession


def _digest_refresh_token(raw_token: str) -> str:
    return hmac.new(
        settings.REFRESH_TOKEN_PEPPER.encode(),
        raw_token.encode(),
        hashlib.sha256,
    ).hexdigest()


def _new_access_token(user: User, session: DeviceSession) -> tuple[str, datetime]:
    now = timezone.now()
    expires_at = now + timedelta(minutes=settings.ACCESS_TOKEN_MINUTES)
    payload = {
        "iss": settings.JWT_ISSUER,
        "aud": settings.JWT_AUDIENCE,
        "typ": "access",
        "sub": str(user.id),
        "sid": str(session.id),
        "jti": str(uuid.uuid4()),
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
    }
    encoded: str | bytes = jwt.encode(
        payload,
        settings.JWT_SIGNING_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )
    token = encoded.decode("ascii") if isinstance(encoded, bytes) else encoded
    return token, expires_at


def _new_refresh_credential(session: DeviceSession) -> tuple[str, RefreshCredential]:
    for _ in range(5):
        prefix = secrets.token_urlsafe(9)[:12]
        raw_token = f"plr.{prefix}.{secrets.token_urlsafe(48)}"
        if not RefreshCredential.objects.filter(token_prefix=prefix).exists():
            credential = RefreshCredential.objects.create(
                session=session,
                token_prefix=prefix,
                token_digest=_digest_refresh_token(raw_token),
                expires_at=timezone.now() + timedelta(days=settings.REFRESH_TOKEN_DAYS),
            )
            return raw_token, credential
    raise RuntimeError("Could not allocate a unique refresh-token prefix")


def issue_session_tokens(
    *,
    user: User,
    device_id: str,
    device_name: str,
    app_version: str,
    request_id: str,
) -> SessionTokens:
    now = timezone.now()
    with transaction.atomic():
        previous = list(
            DeviceSession.objects.select_for_update().filter(
                user=user,
                device_id=device_id,
                revoked_at__isnull=True,
            )
        )
        if previous:
            DeviceSession.objects.filter(id__in=[item.id for item in previous]).update(
                revoked_at=now
            )
            RefreshCredential.objects.filter(
                session__in=previous,
                revoked_at__isnull=True,
            ).update(revoked_at=now)
        session = DeviceSession.objects.create(
            user=user,
            device_id=device_id,
            device_name=device_name,
            app_version=app_version,
            platform="ios",
            last_seen_at=now,
        )
        raw_refresh, refresh = _new_refresh_credential(session)
        access, access_expires = _new_access_token(user, session)
        record_audit_event(
            action="auth.login",
            actor=user,
            target_type="device_session",
            target_id=session.id,
            request_id=request_id,
            metadata={"device_name": device_name, "platform": "ios"},
        )
    return SessionTokens(access, access_expires, raw_refresh, refresh.expires_at, session)


def rotate_refresh_token(*, raw_token: str, request_id: str) -> SessionTokens:
    parts = raw_token.split(".", 2)
    if (
        len(parts) != REFRESH_TOKEN_PART_COUNT
        or parts[0] != "plr"
        or len(parts[1]) > REFRESH_TOKEN_PREFIX_MAX_LENGTH
    ):
        raise AuthenticationFailed(
            "The refresh credential is invalid.", code="invalid_refresh_token"
        )
    prefix = parts[1]
    failure: tuple[str, str] | None = None
    result: SessionTokens | None = None
    with transaction.atomic():
        try:
            credential = (
                RefreshCredential.objects.select_for_update()
                .select_related("session__user")
                .get(token_prefix=prefix)
            )
        except RefreshCredential.DoesNotExist:
            credential = None
        if credential is None or not hmac.compare_digest(
            credential.token_digest, _digest_refresh_token(raw_token)
        ):
            failure = ("The refresh credential is invalid.", "invalid_refresh_token")
        else:
            session = credential.session
            user = session.user
            now = timezone.now()
            if credential.used_at or credential.revoked_at:
                DeviceSession.objects.filter(id=session.id).update(revoked_at=now)
                RefreshCredential.objects.filter(
                    session=session,
                    revoked_at__isnull=True,
                ).update(revoked_at=now)
                record_audit_event(
                    action="auth.refresh_reuse_detected",
                    actor=user,
                    target_type="device_session",
                    target_id=session.id,
                    request_id=request_id,
                    metadata={"reason": "credential_reuse"},
                )
                failure = (
                    "Refresh credential reuse was detected; the device session was revoked.",
                    "refresh_reuse_detected",
                )
            elif session.revoked_at:
                failure = ("The device session is revoked.", "session_revoked")
            elif credential.expires_at <= now:
                credential.revoked_at = now
                credential.save(update_fields=("revoked_at", "updated_at"))
                failure = ("The refresh credential has expired.", "refresh_token_expired")
            else:
                credential.used_at = now
                credential.save(update_fields=("used_at", "updated_at"))
                raw_refresh, replacement = _new_refresh_credential(session)
                credential.replaced_by = replacement
                credential.save(update_fields=("replaced_by", "updated_at"))
                DeviceSession.objects.filter(id=session.id).update(last_seen_at=now)
                access, access_expires = _new_access_token(user, session)
                result = SessionTokens(
                    access,
                    access_expires,
                    raw_refresh,
                    replacement.expires_at,
                    session,
                )
    if failure:
        raise AuthenticationFailed(failure[0], code=failure[1])
    if result is None:
        raise AuthenticationFailed(
            "The refresh credential is invalid.", code="invalid_refresh_token"
        )
    return result


def revoke_session(*, session: DeviceSession, actor: User, request_id: str, reason: str) -> None:
    now = timezone.now()
    with transaction.atomic():
        locked = DeviceSession.objects.select_for_update().get(id=session.id, user=actor)
        if locked.revoked_at is None:
            locked.revoked_at = now
            locked.save(update_fields=("revoked_at", "updated_at"))
        RefreshCredential.objects.filter(
            session=locked,
            revoked_at__isnull=True,
        ).update(revoked_at=now)
        record_audit_event(
            action="auth.session_revoked",
            actor=actor,
            target_type="device_session",
            target_id=locked.id,
            request_id=request_id,
            metadata={"reason": reason},
        )
