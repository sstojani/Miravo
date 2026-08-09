from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.planning.views import (
    BudgetViewSet,
    RecurringOccurrenceViewSet,
    RecurringRuleViewSet,
    SubscriptionViewSet,
)

router = DefaultRouter()
router.register("budgets", BudgetViewSet, basename="budget")
router.register("recurring-rules", RecurringRuleViewSet, basename="recurring-rule")
router.register(
    "recurring-occurrences", RecurringOccurrenceViewSet, basename="recurring-occurrence"
)
router.register("subscriptions", SubscriptionViewSet, basename="subscription")

urlpatterns = [path("", include(router.urls))]
