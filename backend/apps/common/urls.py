from django.urls import path

from apps.common.views import LiveView, PublicConfigView, ReadyView

urlpatterns = [
    path("health/live", LiveView.as_view(), name="health-live"),
    path("health/ready", ReadyView.as_view(), name="health-ready"),
    path("config/public", PublicConfigView.as_view(), name="public-config"),
]
