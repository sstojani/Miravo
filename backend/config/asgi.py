import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

from channels.routing import ProtocolTypeRouter
from django.core.asgi import get_asgi_application

django_asgi_application = get_asgi_application()

application = ProtocolTypeRouter(
    {
        "http": django_asgi_application,
        # Authenticated WebSocket invalidation is added in Milestone 4.
    }
)
