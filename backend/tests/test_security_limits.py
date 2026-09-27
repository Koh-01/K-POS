from datetime import timedelta
from types import SimpleNamespace

import login_limiter
from login_limiter import LoginRateLimiter, client_ip, login_keys


def _request(peer="192.168.65.1", **headers):
    return SimpleNamespace(client=SimpleNamespace(host=peer), headers={k.lower(): v for k, v in headers.items()})


def test_proxy_header_ignored_unless_trusted(monkeypatch):
    monkeypatch.delenv("TRUST_PROXY_HEADERS", raising=False)
    assert client_ip(_request(**{"CF-Connecting-IP": "1.2.3.4"})) == "192.168.65.1"


def test_cloudflare_visitor_ip_used_when_trusted(monkeypatch):
    monkeypatch.setenv("TRUST_PROXY_HEADERS", "true")
    assert client_ip(_request(**{"CF-Connecting-IP": "1.2.3.4"})) == "1.2.3.4"
    assert client_ip(_request(**{"X-Forwarded-For": "5.6.7.8, 10.0.0.1"})) == "5.6.7.8"
    assert client_ip(_request()) == "192.168.65.1"


def test_one_visitor_failing_does_not_lock_out_others(monkeypatch):
    monkeypatch.setenv("TRUST_PROXY_HEADERS", "true")
    limiter = LoginRateLimiter(limit=5, window=timedelta(minutes=15))
    attacker, _ = login_keys(_request(**{"CF-Connecting-IP": "9.9.9.9"}), "x")
    for _ in range(5):
        limiter.record_failure(attacker)
    assert not limiter.allowed(attacker)
    other, _ = login_keys(_request(**{"CF-Connecting-IP": "1.1.1.1"}), "owner@example.com")
    assert limiter.allowed(other)


def test_registration_quota_per_ip(monkeypatch):
    monkeypatch.setenv("TRUST_PROXY_HEADERS", "true")
    monkeypatch.setattr(login_limiter, "registration_limiter", LoginRateLimiter(limit=2, window=timedelta(hours=1)))
    req = _request(**{"CF-Connecting-IP": "7.7.7.7"})
    assert login_limiter.take_registration_slot(req)
    assert login_limiter.take_registration_slot(req)
    assert not login_limiter.take_registration_slot(req)
    assert login_limiter.take_registration_slot(_request(**{"CF-Connecting-IP": "8.8.8.8"}))


def test_resend_quota_per_email(monkeypatch):
    monkeypatch.setattr(login_limiter, "resend_email_limiter", LoginRateLimiter(limit=1, window=timedelta(hours=1)))
    monkeypatch.setattr(login_limiter, "resend_ip_limiter", LoginRateLimiter(limit=10, window=timedelta(hours=1)))
    assert login_limiter.take_resend_slot(_request(), "Owner@Example.com")
    assert not login_limiter.take_resend_slot(_request("10.0.0.2"), "owner@example.com")
