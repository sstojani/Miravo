from django.urls import path

from apps.sync.views import SyncAckView, SyncBootstrapView, SyncPullView, SyncPushView

urlpatterns = [
    path("push", SyncPushView.as_view(), name="sync-push"),
    path("pull", SyncPullView.as_view(), name="sync-pull"),
    path("ack", SyncAckView.as_view(), name="sync-ack"),
    path("bootstrap", SyncBootstrapView.as_view(), name="sync-bootstrap"),
]
