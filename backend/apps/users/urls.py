from django.urls import path

from apps.users.views import LoginView, LogoutView, RefreshView, SessionDetailView, SessionListView

urlpatterns = [
    path("login", LoginView.as_view(), name="auth-login"),
    path("refresh", RefreshView.as_view(), name="auth-refresh"),
    path("logout", LogoutView.as_view(), name="auth-logout"),
    path("sessions", SessionListView.as_view(), name="auth-sessions"),
    path("sessions/<uuid:session_id>", SessionDetailView.as_view(), name="auth-session-detail"),
]
