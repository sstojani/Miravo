from __future__ import annotations

import asyncio
import time
from typing import Any

from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.sync.realtime import GLOBAL_SYNC_GROUP, user_sync_group
from apps.users.models import User


class SyncInvalidationConsumer(AsyncJsonWebsocketConsumer):  # type: ignore[misc]
    """Foreground-only invalidations. Financial representations never travel here."""

    groups_joined: tuple[str, ...] = ()
    expiry_task: asyncio.Task[None] | None = None

    async def connect(self) -> None:
        user = self.scope.get("user")
        if not isinstance(user, User) or not user.is_active:
            await self.close(code=4401)
            return

        self.groups_joined = (GLOBAL_SYNC_GROUP, user_sync_group(user.id))
        for group in self.groups_joined:
            await self.channel_layer.group_add(group, self.channel_name)
        await self.accept()
        await self.send_json({"type": "ready", "protocol_version": 1})
        auth = self.scope.get("auth", {})
        expiry = auth.get("exp") if isinstance(auth, dict) else None
        if isinstance(expiry, int):
            self.expiry_task = asyncio.create_task(self.close_at_expiry(expiry))

    async def disconnect(self, close_code: int) -> None:
        del close_code
        if self.expiry_task is not None:
            self.expiry_task.cancel()
            self.expiry_task = None
        for group in self.groups_joined:
            await self.channel_layer.group_discard(group, self.channel_name)

    async def receive_json(self, content: Any, **kwargs: Any) -> None:
        del content, kwargs
        await self.close(code=4400)

    async def sync_invalidate(self, event: dict[str, Any]) -> None:
        sequence = event.get("sequence")
        if not isinstance(sequence, int) or sequence < 0:
            return
        await self.send_json(
            {
                "type": "sync.invalidate",
                "protocol_version": 1,
                "sequence": sequence,
            }
        )

    async def close_at_expiry(self, expiry_epoch: int) -> None:
        try:
            await asyncio.sleep(max(0, expiry_epoch - time.time()))
        except asyncio.CancelledError:
            return
        await self.close(code=4401)
