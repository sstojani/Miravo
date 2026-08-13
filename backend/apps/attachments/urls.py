from rest_framework.routers import DefaultRouter

from apps.attachments.views import AttachmentViewSet

router = DefaultRouter()
router.register("attachments", AttachmentViewSet, basename="attachment")

urlpatterns = router.urls
