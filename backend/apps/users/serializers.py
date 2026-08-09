from typing import Any

from rest_framework import serializers


class LoginSerializer(serializers.Serializer[dict[str, Any]]):
    email = serializers.EmailField(max_length=254)
    password = serializers.CharField(trim_whitespace=False, write_only=True, max_length=1024)
    device_id = serializers.CharField(max_length=128)
    device_name = serializers.CharField(max_length=120)
    app_version = serializers.CharField(max_length=32, required=False, allow_blank=True, default="")


class RefreshSerializer(serializers.Serializer[dict[str, Any]]):
    refresh_token = serializers.CharField(trim_whitespace=False, write_only=True, max_length=512)


class SessionSerializer(serializers.Serializer[dict[str, Any]]):
    id = serializers.UUIDField()
    device_id = serializers.CharField()
    device_name = serializers.CharField()
    platform = serializers.CharField()
    app_version = serializers.CharField()
    last_seen_at = serializers.DateTimeField()
    created_at = serializers.DateTimeField()
    revoked_at = serializers.DateTimeField(allow_null=True)
    current = serializers.BooleanField()


class TokenResponseSerializer(serializers.Serializer[dict[str, Any]]):
    access_token = serializers.CharField()
    access_token_expires_at = serializers.DateTimeField()
    refresh_token = serializers.CharField()
    refresh_token_expires_at = serializers.DateTimeField()
    token_type = serializers.CharField()
    session_id = serializers.UUIDField()
