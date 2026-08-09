import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

from channels.routing import ProtocolTypeRouter, URLRouter
from django.core.asgi import get_asgi_application

django_asgi_application = get_asgi_application()

from apps.sync.realtime import AccessTokenASGIMiddleware  # noqa: E402
from apps.sync.routing import websocket_urlpatterns  # noqa: E402

application = ProtocolTypeRouter(
    {
        "http": django_asgi_application,
        "websocket": AccessTokenASGIMiddleware(URLRouter(websocket_urlpatterns)),
    }
)
