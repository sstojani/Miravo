import uuid

from django.db import models


class UUIDTimestampedModel(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class SyncableModel(UUIDTimestampedModel):
    deleted_at = models.DateTimeField(null=True, blank=True, db_index=True)
    version = models.PositiveBigIntegerField(default=1)

    class Meta:
        abstract = True
