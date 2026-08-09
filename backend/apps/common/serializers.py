from __future__ import annotations

from collections.abc import Mapping
from typing import Any, cast

from rest_framework import serializers


def _reject_unknown_fields(data: Any, known_fields: set[str]) -> None:
    if not isinstance(data, Mapping):
        return
    unknown = sorted(str(key) for key in data if key not in known_fields)
    if unknown:
        raise serializers.ValidationError(
            {field: ["Unknown field."] for field in unknown}, code="unknown_field"
        )


class StrictSerializer(serializers.Serializer[dict[str, Any]]):
    """Serializer that rejects misspelled or unsupported request fields."""

    def to_internal_value(self, data: Any) -> dict[str, Any]:
        _reject_unknown_fields(data, set(self.fields))
        return cast(dict[str, Any], super().to_internal_value(data))


class StrictModelSerializer(serializers.ModelSerializer[Any]):
    """Model serializer with strict input-field handling."""

    def to_internal_value(self, data: Any) -> dict[str, Any]:
        _reject_unknown_fields(data, set(self.fields))
        return cast(dict[str, Any], super().to_internal_value(data))
