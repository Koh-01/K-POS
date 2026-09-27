"""Application time helpers.

MariaDB DATETIME columns are intentionally stored as naive Malaysia local
time for compatibility with the existing database. All application-created
timestamps pass through this module so reports, promotions and scheduled jobs
use one explicit business timezone.
"""
from datetime import date, datetime
from zoneinfo import ZoneInfo


APP_TIMEZONE_NAME = "Asia/Kuala_Lumpur"
APP_TIMEZONE = ZoneInfo(APP_TIMEZONE_NAME)


def local_now() -> datetime:
    return datetime.now(APP_TIMEZONE).replace(tzinfo=None)


def local_today() -> date:
    return datetime.now(APP_TIMEZONE).date()


def as_local_naive(value: datetime | None) -> datetime:
    if value is None:
        return local_now()
    if value.tzinfo is None:
        return value
    return value.astimezone(APP_TIMEZONE).replace(tzinfo=None)
