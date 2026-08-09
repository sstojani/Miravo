from __future__ import annotations

import os
from pathlib import Path

import dj_database_url
from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent
REPOSITORY_ROOT = BASE_DIR.parent


def env(name: str, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if value is None:
        raise ImproperlyConfigured(f"Missing required environment variable: {name}")
    return value


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ImproperlyConfigured(f"{name} must be a boolean")


def env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError as exc:
        raise ImproperlyConfigured(f"{name} must be an integer") from exc


def env_list(name: str, default: str = "") -> list[str]:
    return [item.strip() for item in os.getenv(name, default).split(",") if item.strip()]


ENVIRONMENT = env("PROJECT_LEDGER_ENV", "development").lower()
DEBUG = env_bool("PROJECT_LEDGER_DEBUG", ENVIRONMENT == "development")
IS_PRODUCTION = ENVIRONMENT == "production"
MINIMUM_PRODUCTION_SECRET_LENGTH = 50

SECRET_KEY = env("PROJECT_LEDGER_SECRET_KEY", "development-only-secret-key-change-me")
JWT_SIGNING_KEY = env("PROJECT_LEDGER_JWT_SIGNING_KEY", SECRET_KEY + ":jwt")
REFRESH_TOKEN_PEPPER = env("PROJECT_LEDGER_REFRESH_TOKEN_PEPPER", SECRET_KEY + ":refresh")
INVITE_TOKEN_PEPPER = env("PROJECT_LEDGER_INVITE_TOKEN_PEPPER", SECRET_KEY + ":invite")

if IS_PRODUCTION:
    forbidden = {"development-only-secret-key-change-me", "replace-me", "change-me"}
    production_secrets = {
        "PROJECT_LEDGER_SECRET_KEY": SECRET_KEY,
        "PROJECT_LEDGER_JWT_SIGNING_KEY": JWT_SIGNING_KEY,
        "PROJECT_LEDGER_REFRESH_TOKEN_PEPPER": REFRESH_TOKEN_PEPPER,
        "PROJECT_LEDGER_INVITE_TOKEN_PEPPER": INVITE_TOKEN_PEPPER,
    }
    missing_production_secrets = [name for name in production_secrets if name not in os.environ]
    if missing_production_secrets:
        raise ImproperlyConfigured(
            "Production requires explicit independent secrets: "
            + ", ".join(missing_production_secrets)
        )
    for setting_name, setting_value in production_secrets.items():
        if len(setting_value) < MINIMUM_PRODUCTION_SECRET_LENGTH or any(
            token in setting_value for token in forbidden
        ):
            raise ImproperlyConfigured(
                f"{setting_name} must be an independent high-entropy production secret"
            )
    if len(set(production_secrets.values())) != len(production_secrets):
        raise ImproperlyConfigured("Production secrets must not reuse the same value")
    if DEBUG:
        raise ImproperlyConfigured("PROJECT_LEDGER_DEBUG must be false in production")

ALLOWED_HOSTS = env_list("PROJECT_LEDGER_ALLOWED_HOSTS", "localhost,127.0.0.1,testserver")
CSRF_TRUSTED_ORIGINS = env_list("PROJECT_LEDGER_CSRF_TRUSTED_ORIGINS")
CORS_ALLOWED_ORIGINS = env_list("PROJECT_LEDGER_CORS_ALLOWED_ORIGINS")
CORS_ALLOW_ALL_ORIGINS = False
CORS_ALLOW_CREDENTIALS = False

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "corsheaders",
    "rest_framework",
    "drf_spectacular",
    "channels",
    "apps.common",
    "apps.users",
    "apps.audit",
    "apps.ledger",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "corsheaders.middleware.CorsMiddleware",
    "apps.common.middleware.RequestContextMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    }
]

database_default = "sqlite:///" + str(BASE_DIR / "db.sqlite3")
DATABASES = {
    "default": dj_database_url.parse(
        env("PROJECT_LEDGER_DATABASE_URL", database_default),
        conn_max_age=60 if IS_PRODUCTION else 0,
        conn_health_checks=True,
    )
}
if IS_PRODUCTION and DATABASES["default"]["ENGINE"] == "django.db.backends.sqlite3":
    raise ImproperlyConfigured("Production requires PostgreSQL")

REDIS_URL = os.getenv("PROJECT_LEDGER_REDIS_URL", "")
if REDIS_URL:
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.redis.RedisCache",
            "LOCATION": REDIS_URL,
            "KEY_PREFIX": "project-ledger",
            "TIMEOUT": 300,
        }
    }
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels_redis.core.RedisChannelLayer",
            "CONFIG": {"hosts": [REDIS_URL]},
        }
    }
else:
    CACHES = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
    CHANNEL_LAYERS = {"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}}

AUTH_USER_MODEL = "users.User"
AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]
PASSWORD_HASHERS = [
    "django.contrib.auth.hashers.Argon2PasswordHasher",
    "django.contrib.auth.hashers.PBKDF2PasswordHasher",
]

LANGUAGE_CODE = "en"
LANGUAGES = [("en", "English"), ("sq", "Albanian")]
TIME_ZONE = env("PROJECT_LEDGER_DEFAULT_TIME_ZONE", "Europe/Tirane")
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage"},
}
MEDIA_ROOT = Path(env("PROJECT_LEDGER_MEDIA_ROOT", str(BASE_DIR / "media")))
MEDIA_URL = "/never-serve-raw-media/"
EXPORT_ROOT = Path(env("PROJECT_LEDGER_EXPORT_ROOT", str(BASE_DIR / "exports")))
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": ["apps.users.authentication.AccessTokenAuthentication"],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
    "EXCEPTION_HANDLER": "apps.common.exceptions.api_exception_handler",
    "DEFAULT_PAGINATION_CLASS": "apps.common.pagination.LedgerCursorPagination",
    "PAGE_SIZE": 100,
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "DEFAULT_THROTTLE_RATES": {
        "auth_login": "10/minute",
        "auth_refresh": "30/minute",
        "user": "600/hour",
    },
    "TEST_REQUEST_DEFAULT_FORMAT": "json",
}

SPECTACULAR_SETTINGS = {
    "TITLE": "Project Ledger API",
    "DESCRIPTION": "Versioned API for the Project Ledger offline-first finance application.",
    "VERSION": "1.0.0",
    "SERVE_INCLUDE_SCHEMA": False,
    "SCHEMA_PATH_PREFIX": r"/api/v1",
    "COMPONENT_SPLIT_REQUEST": True,
    "ENUM_NAME_OVERRIDES": {
        "TransactionKind": "apps.ledger.models.Transaction.Kind",
        "CategoryKind": "apps.ledger.models.Category.Kind",
        "MembershipRole": "apps.ledger.models.TrackerMembership.Role",
        "InviteRole": "apps.ledger.models.TrackerInvite.Role",
    },
}

APP_NAME = env("PROJECT_LEDGER_APP_NAME", "Project Ledger")
BUNDLE_ID = env("PROJECT_LEDGER_BUNDLE_ID", "com.example.projectledger")
PUBLIC_API_BASE_URL = os.getenv("PROJECT_LEDGER_PUBLIC_API_BASE_URL", "")
PUBLIC_REGISTRATION_ENABLED = env_bool("PROJECT_LEDGER_PUBLIC_REGISTRATION", False)
DEFAULT_CURRENCY = env("PROJECT_LEDGER_DEFAULT_CURRENCY", "ALL").upper()
SUPPORTED_CURRENCIES = ["ALL", "EUR", "USD"]
SUPPORTED_LOCALES = ["en", "sq"]
MINIMUM_IOS_VERSION = "18.0"

ACCESS_TOKEN_MINUTES = env_int("PROJECT_LEDGER_ACCESS_TOKEN_MINUTES", 10)
REFRESH_TOKEN_DAYS = env_int("PROJECT_LEDGER_REFRESH_TOKEN_DAYS", 30)
JWT_ALGORITHM = "HS256"
JWT_ISSUER = "project-ledger-api"
JWT_AUDIENCE = "project-ledger-ios"

CELERY_BROKER_URL = env("PROJECT_LEDGER_CELERY_BROKER_URL", REDIS_URL or "memory://")
CELERY_RESULT_BACKEND = os.getenv("PROJECT_LEDGER_CELERY_RESULT_BACKEND") or None
CELERY_TASK_SERIALIZER = "json"
CELERY_ACCEPT_CONTENT = ["json"]
CELERY_RESULT_SERIALIZER = "json"
CELERY_TIMEZONE = "UTC"
CELERY_TASK_ACKS_LATE = True
CELERY_TASK_REJECT_ON_WORKER_LOST = True
CELERY_WORKER_PREFETCH_MULTIPLIER = 1

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
SECURE_SSL_REDIRECT = IS_PRODUCTION
SESSION_COOKIE_SECURE = IS_PRODUCTION
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Strict"
CSRF_COOKIE_SECURE = IS_PRODUCTION
CSRF_COOKIE_HTTPONLY = True
CSRF_COOKIE_SAMESITE = "Strict"
SECURE_HSTS_SECONDS = 31_536_000 if IS_PRODUCTION else 0
SECURE_HSTS_INCLUDE_SUBDOMAINS = IS_PRODUCTION
SECURE_HSTS_PRELOAD = IS_PRODUCTION
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = "DENY"
SECURE_REFERRER_POLICY = "same-origin"

EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"
LOG_LEVEL = env("PROJECT_LEDGER_LOG_LEVEL", "INFO")
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "filters": {"redact": {"()": "apps.common.logging.RedactingFilter"}},
    "formatters": {"json": {"()": "apps.common.logging.SafeJsonFormatter"}},
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "json",
            "filters": ["redact"],
        }
    },
    "root": {"handlers": ["console"], "level": LOG_LEVEL},
    "loggers": {
        "django.server": {"handlers": ["console"], "level": LOG_LEVEL, "propagate": False},
        "project_ledger": {"handlers": ["console"], "level": LOG_LEVEL, "propagate": False},
    },
}
