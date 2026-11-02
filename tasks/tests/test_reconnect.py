"""A long-running server must survive a network change (new Wi-Fi address, sleep/wake).

Google's client keeps connections open between calls. After the Mac's address changes, the
old connection fails with "[Errno 49] Can't assign requested address", and httplib2 retries on
that same dead connection, so every call failed until Claude was restarted.
"""

from __future__ import annotations

import errno
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server  # noqa: E402


class FakeHttp:
    def __init__(self):
        self.closed = 0

    def close(self):
        self.closed += 1


class FlakyRequest:
    """Fails with the given errors in order, then succeeds."""

    def __init__(self, *errors):
        self.http = FakeHttp()
        self.errors = list(errors)
        self.calls = 0

    def execute(self):
        self.calls += 1
        if self.errors:
            raise self.errors.pop(0)
        return {"ok": True}


def test_stale_connection_is_dropped_and_call_retried():
    req = FlakyRequest(OSError(errno.EADDRNOTAVAIL, "Can't assign requested address"))
    assert server._call(req) == {"ok": True}
    assert req.http.closed == 1
    assert req.calls == 2


def test_second_network_failure_is_reported():
    req = FlakyRequest(OSError(errno.EADDRNOTAVAIL, "x"), OSError(errno.EADDRNOTAVAIL, "x"))
    with pytest.raises(server.ToolError, match="Errno 49"):
        server._call(req)
    assert req.calls == 2
