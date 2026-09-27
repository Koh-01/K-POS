from datetime import date

import pytest

from web_router import _cash_filter_url, _cash_period, _safe_cash_return_url


def test_monthly_cash_period_uses_full_calendar_month():
    mode, start, end, year, month = _cash_period(
        "monthly", 2024, 2, None, None
    )

    assert mode == "monthly"
    assert (start, end) == (date(2024, 2, 1), date(2024, 2, 29))
    assert (year, month) == (2024, 2)
    assert _cash_filter_url(mode, start, end, year, month) == (
        "/web/cash?mode=monthly&year=2024&month=2"
    )


def test_custom_cash_period_rejects_reversed_dates():
    with pytest.raises(ValueError, match="Start date"):
        _cash_period("custom", None, None, "2026-09-13", "2026-09-01")


def test_cash_return_url_cannot_redirect_outside_cash_page():
    assert _safe_cash_return_url("https://example.com") == "/web/cash"
    assert _safe_cash_return_url("/web/cash?mode=custom") == (
        "/web/cash?mode=custom"
    )
