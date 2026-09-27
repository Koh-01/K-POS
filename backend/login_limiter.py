"""Small in-process login failure limiter.

This protects a single-store deployment without adding Redis. If the backend
is later scaled to multiple workers/hosts, replace it with a shared store.
"""
import os
from collections import defaultdict, deque
from datetime import timedelta
from threading import Lock

from fastapi import Request

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


def client_ip(request: Request) -> str:
    """The real visitor IP.

    Behind the Cloudflare Tunnel every request reaches the app from the same
    local address, so per-IP limits would lock out every restaurant at once.
    With TRUST_PROXY_HEADERS=true (only safe when the port is reachable solely
    by cloudflared, e.g. bound to 127.0.0.1) Cloudflare's header is used.
    """
    if os.getenv("TRUST_PROXY_HEADERS", "false").lower() == "true":
        forwarded = (
            request.headers.get("cf-connecting-ip")
            or request.headers.get("x-forwarded-for", "").split(",")[0]
        ).strip()
        if forwarded:
            return forwarded
    return request.client.host if request.client else "unknown"


def login_keys(request: Request, identifier: str) -> tuple[str, str]:
    """Failures count per visitor IP and per account, so neither brute force
    from one IP nor a distributed attack on one account gets unlimited tries."""
    return f"ip:{client_ip(request)}", f"account:{identifier.strip().lower()}"


login_limiter = LoginRateLimiter()
# Per-account limit is looser so an attacker cannot easily lock a real user out.
account_login_limiter = LoginRateLimiter(limit=20, window=timedelta(minutes=15))
# Each registration creates a database and sends an email.
registration_limiter = LoginRateLimiter(limit=5, window=timedelta(hours=1))
resend_ip_limiter = LoginRateLimiter(limit=10, window=timedelta(hours=1))
resend_email_limiter = LoginRateLimiter(limit=3, window=timedelta(hours=1))


def take_registration_slot(request: Request) -> bool:
    """Count a registration attempt; False once this IP has used its hourly quota."""
    key = client_ip(request)
    if not registration_limiter.allowed(key):
        return False
    registration_limiter.record_failure(key)
    return True


def take_resend_slot(request: Request, email: str) -> bool:
    """Count a resend request; False when the IP or the address is over its quota."""
    ip_key, email_key = client_ip(request), email.strip().lower()
    if not (resend_ip_limiter.allowed(ip_key) and resend_email_limiter.allowed(email_key)):
        return False
    resend_ip_limiter.record_failure(ip_key)
    resend_email_limiter.record_failure(email_key)
    return True
