import pytest


@pytest.fixture(autouse=True)
def no_menu_bar_refresh(monkeypatch):
    """Tests must never touch the user's menu bar. Write tools call _refresh_menu_bar(), which
    talks to SwiftBar; GTASKS_NO_REFRESH turns that into a no-op."""
    monkeypatch.setenv("GTASKS_NO_REFRESH", "1")
