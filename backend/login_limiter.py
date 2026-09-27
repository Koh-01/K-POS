"""Small in-process login failure limiter.

This protects a single-store deployment without adding Redis. If the backend
is later scaled to multiple workers/hosts, replace it with a shared store.
"""
from collections import defaultdict, deque
from datetime import timedelta
from threading import Lock

from time_utils import local_now


class LoginRateLimiter:
    def __init__(self, limit: int = 5, window: timedelta = timedelta(minutes=15)):
        self.limit = limit
        self.window = window
        self._failures = defaultdict(deque)
        self._lock = Lock()

    def allowed(self, key: str) -> bool:
        now = local_now()
        with self._lock:
            failures = self._failures[key]
            while failures and now - failures[0] > self.window:
                failures.popleft()
            return len(failures) < self.limit

    def record_failure(self, key: str) -> None:
        with self._lock:
            self._failures[key].append(local_now())

    def clear(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)


login_limiter = LoginRateLimiter()
