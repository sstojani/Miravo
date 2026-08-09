from django.urls import path

from apps.shortcut.views import (
    ShortcutAccountListView,
    ShortcutCategoryListView,
    ShortcutContextView,
    ShortcutCredentialCollectionView,
    ShortcutCredentialDetailView,
    ShortcutTransactionBatchView,
    ShortcutTransactionCreateView,
)

urlpatterns = [
    path("credentials", ShortcutCredentialCollectionView.as_view(), name="credentials"),
    path(
        "credentials/<uuid:credential_id>",
        ShortcutCredentialDetailView.as_view(),
        name="credential-detail",
    ),
    path("context", ShortcutContextView.as_view(), name="context"),
    path("categories", ShortcutCategoryListView.as_view(), name="categories"),
    path("accounts", ShortcutAccountListView.as_view(), name="accounts"),
    path("transactions/batch", ShortcutTransactionBatchView.as_view(), name="transactions-batch"),
    path("transactions", ShortcutTransactionCreateView.as_view(), name="transactions"),
]
