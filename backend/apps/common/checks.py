from __future__ import annotations

from urllib.parse import urlparse

from django.conf import settings
from django.core.checks import Error, Tags, register
from django.core.checks import Warning as CheckWarning


@register(Tags.security)
def project_security_checks(app_configs: object, **kwargs: object) -> list[Error | CheckWarning]:
    del app_configs, kwargs
    findings: list[Error | CheckWarning] = []
    if settings.PUBLIC_API_BASE_URL:
        parsed = urlparse(settings.PUBLIC_API_BASE_URL)
        if settings.IS_PRODUCTION and parsed.scheme != "https":
            findings.append(
                Error(
                    "Production public API base URL must use HTTPS.",
                    id="project_ledger.E001",
                )
            )
        elif parsed.scheme not in {"http", "https"} or not parsed.netloc:
            findings.append(
                CheckWarning(
                    "Public API base URL is not a valid absolute URL.", id="project_ledger.W001"
                )
            )
    elif settings.IS_PRODUCTION:
        findings.append(
            Error("Production public API base URL is required.", id="project_ledger.E002")
        )
    return findings
