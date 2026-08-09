from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.planning.views import BudgetViewSet

router = DefaultRouter()
router.register("budgets", BudgetViewSet, basename="budget")

urlpatterns = [path("", include(router.urls))]
