from django.urls import re_path

from apps.sync.consumers import SyncInvalidationConsumer

websocket_urlpatterns = [
    re_path(r"^api/v1/sync/events/?$", SyncInvalidationConsumer.as_asgi()),
]
