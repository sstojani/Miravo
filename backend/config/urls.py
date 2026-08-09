from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView

urlpatterns = [
    path("internal/admin/", admin.site.urls),
    path("api/v1/", include("apps.common.urls")),
    path("api/v1/auth/", include("apps.users.urls")),
    path("api/schema/", SpectacularAPIView.as_view(), name="openapi-schema"),
]
