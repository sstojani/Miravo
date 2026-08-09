from rest_framework.pagination import CursorPagination


class LedgerCursorPagination(CursorPagination):
    page_size = 100
    max_page_size = 500
    ordering = ("-created_at", "-id")
