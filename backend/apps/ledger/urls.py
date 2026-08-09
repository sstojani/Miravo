from django.urls import path
from rest_framework.routers import DefaultRouter

from apps.ledger.views import (
    AccountViewSet,
    AuditEventViewSet,
    CategoryViewSet,
    InviteAcceptView,
    MerchantViewSet,
    TagViewSet,
    TrackerViewSet,
    TransactionViewSet,
)

router = DefaultRouter()
router.register("trackers", TrackerViewSet, basename="tracker")
router.register("accounts", AccountViewSet, basename="account")
router.register("categories", CategoryViewSet, basename="category")
router.register("tags", TagViewSet, basename="tag")
router.register("merchants", MerchantViewSet, basename="merchant")
router.register("transactions", TransactionViewSet, basename="transaction")
router.register("audit-events", AuditEventViewSet, basename="audit-event")

urlpatterns = [
    path("tracker-invites/accept", InviteAcceptView.as_view(), name="invite-accept"),
    *router.urls,
]
