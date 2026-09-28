"""
Admin Web UI — Jinja2 + Bootstrap 5
All routes live under /web/ prefix.
Auth: JWT stored in httpOnly cookie "pos_web_token" (30-day expiry).
"""
import csv
import io
import os
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from pathlib import Path
from urllib.parse import urlencode, urlsplit

from reportlab.lib.pagesizes import A7
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas as rl_canvas

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates
from starlette.concurrency import run_in_threadpool
from jinja2 import Environment, FileSystemLoader
from sqlalchemy import Numeric, case, cast, func, or_
from sqlalchemy.orm import Session, joinedload

import models
from auth import verify_password
from database import get_db
from report_router import _sales_query, _top_products_query, _to_decimal
from token_utils import create_access_token, decode_access_token
from time_utils import local_now, local_today
from login_limiter import (
    account_login_limiter, client_ip, login_keys, login_limiter,
    take_registration_slot, take_resend_slot,
)
from image_utils import load_upload_image
from payment_cash_records import sync_payment_cash_records
from auth_router import _send_verification_safely
from email_service import email_delivery_configured
from registration_service import register_admin, resend_verification, verify_email_token
from tenant_database import select_for_user, sync_user_shadow
import drive_connections
import schemas
from csv_utils import format_qty, safe_csv_writer

TEMPLATES = Jinja2Templates(env=Environment(
    loader=FileSystemLoader(str(Path(__file__).parent / "templates")),
    autoescape=True,
    cache_size=0,
))
router = APIRouter(prefix="/web", include_in_schema=False)


_MONTH_NAMES = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]


# ── Auth helpers ───────────────────────────────────────────────────────────────

class WebLoginRequired(Exception):
    pass


def _enforce_same_origin(request: Request) -> None:
    """Reject cross-site cookie-authenticated mutations (basic CSRF guard)."""
    if request.method not in {"POST", "PUT", "PATCH", "DELETE"}:
        return
    source = request.headers.get("origin") or request.headers.get("referer")
    if not source:
        raise HTTPException(status_code=403, detail="Missing request origin")
    source_host = urlsplit(source).netloc.lower()
    expected_host = (
        request.headers.get("x-forwarded-host")
        or request.headers.get("host")
        or ""
    ).lower()
    if source_host != expected_host:
        raise HTTPException(status_code=403, detail="Cross-site request rejected")


def _require_web_admin(
    request: Request, db: Session = Depends(get_db)
) -> models.User:
    _enforce_same_origin(request)
    token = request.cookies.get("pos_web_token")
    if not token:
        raise WebLoginRequired()
    payload = decode_access_token(token)
    if not payload:
        raise WebLoginRequired()
    user_id = payload.get("uid")
    query = db.query(models.User).filter(
        models.User.is_active == True,
        models.User.is_deleted == False,
        models.User.role == "admin",
    )
    user = query.filter(models.User.id == user_id).first() if user_id else query.filter(
        models.User.username == payload.get("sub")
    ).first()
    if not user or (user.email and not user.email_verified):
        raise WebLoginRequired()
    try:
        select_for_user(db, user)
    except HTTPException:
        raise WebLoginRequired()
    return user


def _ctx(user: models.User, **kw) -> dict:
    return {"user": user, **kw}


# ── StoreSettings key-value helpers ────────────────────────────────────────────

def _get_setting(db: Session, key: str, default: str = "") -> str:
    row = db.query(models.StoreSettings).filter(models.StoreSettings.key == key).first()
    return row.value if row else default


def _put_setting(db: Session, key: str, value: str) -> None:
    row = db.query(models.StoreSettings).filter(models.StoreSettings.key == key).first()
    if row:
        row.value = value
    else:
        db.add(models.StoreSettings(key=key, value=value))


# ── Login / Logout ─────────────────────────────────────────────────────────────

@router.get("/login", response_class=HTMLResponse)
async def get_login(request: Request):
    return TEMPLATES.TemplateResponse(
        request,
        "login.html",
        {"verified": request.query_params.get("verified")},
    )


@router.post("/login")
async def post_login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    db: Session = Depends(get_db),
):
    _enforce_same_origin(request)
    ip_key, account_key = login_keys(request, username)
    if not (login_limiter.allowed(ip_key) and account_login_limiter.allowed(account_key)):
        return TEMPLATES.TemplateResponse(
            request,
            "login.html",
            {"error": "Too many failed attempts. Try again in 15 minutes."},
            status_code=429,
        )
    identifier = username.strip().lower()
    user = (
        db.query(models.User)
        .filter(
            or_(
                func.lower(models.User.username) == identifier,
                func.lower(models.User.email) == identifier,
            ),
            models.User.is_deleted == False,
            models.User.role == "admin",
        )
        .first()
    )
    password_matches = user is not None and verify_password(password, user.password_hash)
    ok = password_matches and user.is_active

    db.add(models.LoginLog(
        user_id=user.id if user else None,
        restaurant_id=user.restaurant_id if user else None,
        username=username,
        success=ok,
        ip_address=client_ip(request),
        user_agent=request.headers.get("user-agent"),
    ))
    db.commit()

    if password_matches and user.email and not user.email_verified:
        login_limiter.record_failure(ip_key)
        account_login_limiter.record_failure(account_key)
        return TEMPLATES.TemplateResponse(
            request,
            "login.html",
            {"error": "Please verify your email before signing in."},
            status_code=403,
        )

    if not ok:
        login_limiter.record_failure(ip_key)
        account_login_limiter.record_failure(account_key)
        return TEMPLATES.TemplateResponse(
            request, "login.html",
            {"error": "Invalid credentials or not an admin account"},
            status_code=401,
        )

    login_limiter.clear(ip_key)
    account_login_limiter.clear(account_key)
    try:
        select_for_user(db, user)
    except HTTPException as exc:
        return TEMPLATES.TemplateResponse(
            request, "login.html", {"error": exc.detail}, status_code=exc.status_code,
        )
    token = create_access_token({
        "sub": user.username,
        "uid": user.id,
        "restaurant_id": user.restaurant_id,
        "role": user.role,
    })
    resp = RedirectResponse(url="/web/dashboard", status_code=303)
    cookie_secure = os.getenv("WEB_COOKIE_SECURE", "true").lower() != "false"
    resp.set_cookie(
        "pos_web_token", token, httponly=True, secure=cookie_secure,
        max_age=30 * 24 * 3600, samesite="lax", path="/web",
    )
    return resp


@router.get("/register", response_class=HTMLResponse)
async def get_register(request: Request):
    return TEMPLATES.TemplateResponse(request, "register.html")


@router.post("/register", response_class=HTMLResponse)
async def post_register(
    request: Request,
    background_tasks: BackgroundTasks,
    restaurant_name: str = Form(...),
    full_name: str = Form(...),
    email: str = Form(...),
    password: str = Form(...),
    confirm_password: str = Form(...),
    db: Session = Depends(get_db),
):
    _enforce_same_origin(request)
    if password != confirm_password:
        return TEMPLATES.TemplateResponse(
            request, "register.html", {"error": "Passwords do not match"}, status_code=400,
        )
    if not email_delivery_configured():
        return TEMPLATES.TemplateResponse(
            request,
            "register.html",
            {"error": "Email verification is not configured. Contact the system operator."},
            status_code=503,
        )
    if not take_registration_slot(request):
        return TEMPLATES.TemplateResponse(
            request, "register.html", {"error": "Too many registration attempts. Please try again later."}, status_code=429,
        )
    try:
        data = schemas.AdminRegistrationRequest(
            restaurant_name=restaurant_name,
            full_name=full_name,
            email=email,
            password=password,
        )
        user, token = register_admin(db, data)
    except Exception as exc:
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        return TEMPLATES.TemplateResponse(
            request,
            "register.html",
            {"error": detail, "restaurant_name": restaurant_name, "full_name": full_name, "email": email},
            status_code=getattr(exc, "status_code", 400),
        )
    background_tasks.add_task(
        _send_verification_safely,
        user.email,
        user.full_name or user.email,
        data.restaurant_name,
        token,
    )
    return TEMPLATES.TemplateResponse(
        request,
        "register.html",
        {
            "success": "Account created. Check your email and open the verification link before signing in.",
            "email": user.email,
        },
        status_code=202,
    )


@router.post("/resend-verification", response_class=HTMLResponse)
async def web_resend_verification(
    request: Request,
    background_tasks: BackgroundTasks,
    email: str = Form(...),
    db: Session = Depends(get_db),
):
    _enforce_same_origin(request)
    if not email_delivery_configured():
        return TEMPLATES.TemplateResponse(
            request,
            "register.html",
            {"error": "Email verification is not configured. Contact the system operator."},
            status_code=503,
        )
    try:
        data = schemas.ResendVerificationRequest(email=email)
        result = resend_verification(db, data.email) if take_resend_slot(request, data.email) else None
        if result:
            user, token = result
            background_tasks.add_task(
                _send_verification_safely,
                user.email,
                user.full_name or user.email,
                user.restaurant.name,
                token,
            )
    except Exception:
        pass
    return TEMPLATES.TemplateResponse(
        request,
        "register.html",
        {
            "success": "If this account is awaiting verification, a new email will be sent.",
            "email": email,
        },
        status_code=202,
    )


@router.get("/verify-email", response_class=HTMLResponse)
async def web_verify_email(request: Request, token: str, db: Session = Depends(get_db)):
    try:
        verify_email_token(db, token)
    except HTTPException as exc:
        return TEMPLATES.TemplateResponse(
            request, "verify_email.html", {"error": exc.detail}, status_code=exc.status_code,
        )
    return RedirectResponse(url="/web/login?verified=1", status_code=303)


@router.get("/logout")
async def logout():
    resp = RedirectResponse(url="/web/login", status_code=303)
    resp.delete_cookie("pos_web_token", path="/web")
    return resp


# ── Dashboard ──────────────────────────────────────────────────────────────────

@router.get("/", response_class=HTMLResponse)
async def root(user: models.User = Depends(_require_web_admin)):
    return RedirectResponse(url="/web/dashboard", status_code=303)


@router.get("/dashboard", response_class=HTMLResponse)
async def dashboard(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    today = local_today()
    start_dt = datetime.combine(today, time.min)
    end_dt = datetime.combine(today, time.max)

    today_revenue = db.query(func.sum(models.Payment.grand_total)).filter(
        models.Payment.status == "completed",
        models.Payment.created_at.between(start_dt, end_dt),
    ).scalar() or Decimal("0")

    orders_today = db.query(func.count(models.Order.id)).filter(
        models.Order.is_deleted == False,
        models.Order.created_at.between(start_dt, end_dt),
    ).scalar() or 0

    active_tables = db.query(func.count(models.Table.id)).filter(
        models.Table.status == "occupied",
        models.Table.is_active == True,
    ).scalar() or 0

    week_start = today - timedelta(days=today.weekday())
    week_revenue = db.query(func.sum(models.Payment.grand_total)).filter(
        models.Payment.status == "completed",
        models.Payment.created_at >= datetime.combine(week_start, time.min),
        models.Payment.created_at <= end_dt,
    ).scalar() or Decimal("0")

    month_start = today.replace(day=1)
    month_revenue = db.query(func.sum(models.Payment.grand_total)).filter(
        models.Payment.status == "completed",
        models.Payment.created_at >= datetime.combine(month_start, time.min),
        models.Payment.created_at <= end_dt,
    ).scalar() or Decimal("0")

    sold_amount = case(
        (models.OrderItem.weight_kg.isnot(None), models.OrderItem.weight_kg),
        else_=cast(models.OrderItem.quantity, Numeric(12, 3)),
    )
    top_row = (
        db.query(models.Product.name, func.sum(sold_amount).label("qty"))
        .select_from(models.Payment)
        .join(models.Order, models.Order.id == models.Payment.order_id)
        .join(models.OrderItem, models.OrderItem.order_id == models.Order.id)
        .join(models.Product, models.Product.id == models.OrderItem.product_id)
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at.between(start_dt, end_dt),
        )
        .group_by(models.Product.id)
        .order_by(func.sum(sold_amount).desc())
        .first()
    )

    return TEMPLATES.TemplateResponse(request, "dashboard.html", _ctx(
        user,
        store_name=_get_setting(db, "store_name", "POS System"),
        today_revenue=float(today_revenue),
        orders_today=orders_today,
        active_tables=active_tables,
        week_revenue=float(week_revenue),
        month_revenue=float(month_revenue),
        top_product=top_row[0] if top_row else "—",
        today_str=today.strftime("%d %b %Y"),
    ))


# ── Reports ────────────────────────────────────────────────────────────────────

@router.get("/reports/sales", response_class=HTMLResponse)
async def reports_sales(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    today = local_today()
    return TEMPLATES.TemplateResponse(request, "reports_sales.html", _ctx(
        user,
        today=today.isoformat(),
        current_year=today.year,
        years=list(range(today.year, today.year - 5, -1)),
    ))


@router.get("/reports/daily-json")
async def reports_daily_json(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
    start_date: str = None,
    end_date: str = None,
):
    today = local_today()
    sd = date.fromisoformat(start_date) if start_date else today - timedelta(days=29)
    ed = date.fromisoformat(end_date) if end_date else today
    report = _sales_query(sd, ed, db)
    return JSONResponse({
        "total_revenue": float(report.total_revenue),
        "total_orders": report.total_orders,
        "breakdown": [
            {"label": d.date, "revenue": float(d.revenue), "orders": d.orders}
            for d in report.daily_breakdown
        ],
    })


@router.get("/reports/monthly-json")
async def reports_monthly_json(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
    year: int = None,
):
    today = local_today()
    if not year:
        year = today.year
    start_dt = datetime(year, 1, 1)
    end_dt = datetime(year, 12, 31, 23, 59, 59)
    rows = (
        db.query(
            func.month(models.Payment.created_at).label("mn"),
            func.sum(models.Payment.grand_total).label("revenue"),
            func.count(models.Payment.id).label("orders"),
        )
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at.between(start_dt, end_dt),
        )
        .group_by(func.month(models.Payment.created_at))
        .order_by(func.month(models.Payment.created_at))
        .all()
    )
    breakdown = [
        {"label": _MONTH_NAMES[int(row.mn) - 1], "revenue": float(row.revenue or 0), "orders": row.orders}
        for row in rows
    ]
    return JSONResponse({
        "total_revenue": round(sum(b["revenue"] for b in breakdown), 2),
        "total_orders": sum(b["orders"] for b in breakdown),
        "year": year,
        "breakdown": breakdown,
    })


@router.get("/reports/yearly-json")
async def reports_yearly_json(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    rows = (
        db.query(
            func.year(models.Payment.created_at).label("yr"),
            func.sum(models.Payment.grand_total).label("revenue"),
            func.count(models.Payment.id).label("orders"),
        )
        .filter(models.Payment.status == "completed")
        .group_by(func.year(models.Payment.created_at))
        .order_by(func.year(models.Payment.created_at))
        .all()
    )
    breakdown = [
        {"label": str(int(row.yr)), "revenue": float(row.revenue or 0), "orders": row.orders}
        for row in rows
    ]
    return JSONResponse({
        "total_revenue": round(sum(b["revenue"] for b in breakdown), 2),
        "total_orders": sum(b["orders"] for b in breakdown),
        "breakdown": breakdown,
    })


@router.get("/reports/annual", response_class=HTMLResponse)
async def reports_annual(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
    year: int = None,
):
    today = local_today()
    if not year:
        year = today.year

    start_dt = datetime(year, 1, 1)
    end_dt = datetime(year, 12, 31, 23, 59, 59)

    rows = (
        db.query(
            func.year(models.Payment.created_at).label("yr"),
            func.month(models.Payment.created_at).label("mn"),
            func.sum(models.Payment.grand_total).label("revenue"),
            func.count(models.Payment.id).label("orders"),
        )
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at.between(start_dt, end_dt),
        )
        .group_by(
            func.year(models.Payment.created_at),
            func.month(models.Payment.created_at),
        )
        .order_by(
            func.year(models.Payment.created_at),
            func.month(models.Payment.created_at),
        )
        .all()
    )

    monthly = [
        {
            "month": _MONTH_NAMES[int(row.mn) - 1],
            "revenue": float(row.revenue or 0),
            "orders": row.orders,
        }
        for row in rows
    ]
    total_revenue = sum(m["revenue"] for m in monthly)
    total_orders = sum(m["orders"] for m in monthly)
    years = list(range(today.year, today.year - 5, -1))

    return TEMPLATES.TemplateResponse(request, "reports_annual.html", _ctx(
        user,
        year=year, years=years,
        monthly=monthly,
        total_revenue=total_revenue,
        total_orders=total_orders,
    ))


@router.get("/reports/top-products", response_class=HTMLResponse)
async def reports_top_products(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
    start_date: str = None,
    end_date: str = None,
):
    today = local_today()
    if not start_date:
        start_date = today.replace(day=1).isoformat()
    if not end_date:
        end_date = today.isoformat()

    report = None
    error = None
    try:
        sd = date.fromisoformat(start_date)
        ed = date.fromisoformat(end_date)
        report = _top_products_query(sd, ed, 20, db)
    except Exception as exc:
        error = str(exc)

    return TEMPLATES.TemplateResponse(request, "reports_top_products.html", _ctx(
        user,
        report=report, start_date=start_date, end_date=end_date, error=error,
    ))


# ── Payments ───────────────────────────────────────────────────────────────────

@router.get("/payments", response_class=HTMLResponse)
async def payments_list(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
    status_filter: str = "all",
):
    q = (
        db.query(models.Payment)
        .options(
            joinedload(models.Payment.order).joinedload(models.Order.table),
            joinedload(models.Payment.cashier),
        )
        .order_by(models.Payment.id.desc())
    )
    if status_filter == "completed":
        q = q.filter(models.Payment.status == "completed")
    elif status_filter == "voided":
        q = q.filter(models.Payment.status == "voided")
    payments = q.limit(100).all()

    return TEMPLATES.TemplateResponse(request, "payments.html", _ctx(
        user, payments=payments, status_filter=status_filter,
    ))


@router.post("/payments/{payment_id}/void")
async def void_payment(
    payment_id: int,
    reason: str = Form(...),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    payment = db.query(models.Payment).filter(models.Payment.id == payment_id).first()
    if payment and payment.status == "completed":
        snapshot = {
            "payment_id": payment.id,
            "grand_total": float(payment.grand_total),
            "status_before": payment.status,
        }
        db.add(models.PaymentAuditLog(
            payment_id=payment.id,
            action="void",
            reason=reason,
            snapshot_before=snapshot,
            changed_by=user.id,
        ))
        payment.status = "voided"
        db.commit()
    return RedirectResponse(url="/web/payments", status_code=303)


# ── Cash Records ───────────────────────────────────────────────────────────────

def _cash_period(
    mode: str,
    year: int | None,
    month: int | None,
    start_date: str | None,
    end_date: str | None,
) -> tuple[str, date, date, int, int]:
    today = local_today()
    if mode == "custom":
        start = date.fromisoformat(start_date) if start_date else today.replace(day=1)
        end = date.fromisoformat(end_date) if end_date else today
        if start > end:
            raise ValueError("Start date cannot be after end date")
        return "custom", start, end, start.year, start.month

    selected_year = year or today.year
    selected_month = month or today.month
    if selected_year < 2000 or selected_year > today.year:
        raise ValueError("Year is outside the available range")
    if selected_month < 1 or selected_month > 12:
        raise ValueError("Month must be between 1 and 12")
    start = date(selected_year, selected_month, 1)
    if selected_month == 12:
        next_month = date(selected_year + 1, 1, 1)
    else:
        next_month = date(selected_year, selected_month + 1, 1)
    end = next_month - timedelta(days=1)
    return "monthly", start, end, selected_year, selected_month


def _cash_filter_url(
    mode: str,
    start: date,
    end: date,
    year: int,
    month: int,
    *,
    export: bool = False,
) -> str:
    if mode == "custom":
        query = urlencode({
            "mode": "custom",
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
        })
    else:
        query = urlencode({"mode": "monthly", "year": year, "month": month})
    path = "/web/cash/export.csv" if export else "/web/cash"
    return f"{path}?{query}"


def _safe_cash_return_url(return_to: str) -> str:
    return return_to if return_to.startswith("/web/cash?") else "/web/cash"


@router.get("/cash", response_class=HTMLResponse)
async def cash_list(
    request: Request,
    mode: str = "monthly",
    year: int | None = None,
    month: int | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    error = None
    try:
        mode, start, end, selected_year, selected_month = _cash_period(
            mode, year, month, start_date, end_date
        )
    except (TypeError, ValueError) as exc:
        error = str(exc)
        mode, start, end, selected_year, selected_month = _cash_period(
            "monthly", None, None, None, None
        )

    start_dt = datetime.combine(start, time.min)
    end_dt = datetime.combine(end, time.max)
    records = (
        db.query(models.CashRecord)
        .filter(models.CashRecord.created_at.between(start_dt, end_dt))
        .order_by(models.CashRecord.created_at.desc(), models.CashRecord.id.desc())
        .all()
    )
    total_in = sum(float(r.amount) for r in records if r.type == "cash_in")
    total_out = sum(float(r.amount) for r in records if r.type == "cash_out")
    cash_url = _cash_filter_url(
        mode, start, end, selected_year, selected_month
    )

    return TEMPLATES.TemplateResponse(request, "cash.html", _ctx(
        user,
        records=records,
        total_in=total_in, total_out=total_out, net=total_in - total_out,
        mode=mode,
        selected_year=selected_year,
        selected_month=selected_month,
        start_date=start.isoformat(),
        end_date=end.isoformat(),
        years=range(local_today().year, 1999, -1),
        months=list(enumerate(_MONTH_NAMES, start=1)),
        cash_url=cash_url,
        cash_export_url=_cash_filter_url(
            mode, start, end, selected_year, selected_month, export=True
        ),
        error=error,
    ))


@router.get("/cash/export.csv")
async def export_cash_records(
    request: Request,
    mode: str = "monthly",
    year: int | None = None,
    month: int | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    try:
        mode, start, end, selected_year, selected_month = _cash_period(
            mode, year, month, start_date, end_date
        )
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    records = (
        db.query(models.CashRecord)
        .filter(models.CashRecord.created_at.between(
            datetime.combine(start, time.min),
            datetime.combine(end, time.max),
        ))
        .order_by(models.CashRecord.created_at.desc(), models.CashRecord.id.desc())
        .all()
    )
    output = io.StringIO()
    writer = safe_csv_writer(output)
    writer.writerow(["Date", "Type", "Amount (RM)", "Description", "Category", "Reference"])
    for record in records:
        writer.writerow([
            record.created_at.strftime("%Y-%m-%d %H:%M:%S"),
            "Cash In" if record.type == "cash_in" else "Cash Out",
            f"{float(record.amount):.2f}",
            record.description,
            record.category or "",
            record.reference or "",
        ])
    filename = f"cash_records_{start:%Y%m%d}_{end:%Y%m%d}.csv"
    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.post("/cash")
async def add_cash_record(
    type: str = Form(...),
    amount: str = Form(...),
    description: str = Form(...),
    category: str = Form(""),
    reference: str = Form(""),
    return_to: str = Form("/web/cash"),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    try:
        db.add(models.CashRecord(
            type=type,
            amount=Decimal(amount),
            description=description,
            category=category.strip() or None,
            reference=reference or None,
            created_by=user.id,
        ))
        db.commit()
    except Exception:
        pass
    return RedirectResponse(url=_safe_cash_return_url(return_to), status_code=303)


@router.post("/cash/{record_id}/edit")
async def edit_cash_record(
    record_id: int,
    type: str = Form(...),
    amount: str = Form(...),
    description: str = Form(...),
    category: str = Form(""),
    reference: str = Form(""),
    return_to: str = Form("/web/cash"),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    r = db.query(models.CashRecord).filter(models.CashRecord.id == record_id).first()
    if r:
        try:
            r.type = type
            r.amount = Decimal(amount)
            r.description = description
            r.category = category.strip() or None
            r.reference = reference or None
            db.commit()
        except Exception:
            pass
    return RedirectResponse(url=_safe_cash_return_url(return_to), status_code=303)


@router.post("/cash/{record_id}/delete")
async def delete_cash_record(
    record_id: int,
    return_to: str = Form("/web/cash"),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    r = db.query(models.CashRecord).filter(models.CashRecord.id == record_id).first()
    if r:
        db.delete(r)
        db.commit()
    return RedirectResponse(url=_safe_cash_return_url(return_to), status_code=303)


# ── Products ───────────────────────────────────────────────────────────────────

@router.get("/products", response_class=HTMLResponse)
async def products_list(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    products = (
        db.query(models.Product)
        .options(joinedload(models.Product.category))
        .filter(models.Product.is_deleted == False)
        .order_by(models.Product.sort_order, models.Product.id)
        .all()
    )
    categories = (
        db.query(models.Category)
        .filter(models.Category.is_active == True)
        .order_by(models.Category.sort_order)
        .all()
    )
    return TEMPLATES.TemplateResponse(request, "products.html", _ctx(user, products=products, categories=categories))


@router.post("/products/{product_id}/toggle")
async def toggle_product(
    product_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    p = db.query(models.Product).filter(models.Product.id == product_id).first()
    if p:
        p.status = "inactive" if p.status == "active" else "active"
        db.commit()
    return RedirectResponse(url="/web/products", status_code=303)


@router.post("/products/reorder")
async def web_reorder_products(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    items = await request.json()
    for item in items:
        p = db.query(models.Product).filter(models.Product.id == item["id"]).first()
        if p:
            p.sort_order = item["sort_order"]
    db.commit()
    return JSONResponse({"ok": True})


@router.post("/products/new")
async def create_product(
    name: str = Form(...),
    category_id: str = Form(""),
    price: str = Form(...),
    description: str = Form(""),
    sort_order: str = Form("0"),
    sold_by_weight: str = Form(""),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    try:
        db.add(models.Product(
            name=name,
            category_id=int(category_id) if category_id else None,
            price=Decimal(price),
            description=description or None,
            sort_order=int(sort_order) if sort_order else 0,
            sold_by_weight=bool(sold_by_weight),
            status="active",
            is_deleted=False,
        ))
        db.commit()
    except Exception:
        pass
    return RedirectResponse(url="/web/products", status_code=303)


@router.post("/products/{product_id}/edit")
async def update_product(
    product_id: int,
    name: str = Form(...),
    category_id: str = Form(""),
    price: str = Form(...),
    description: str = Form(""),
    sort_order: str = Form("0"),
    sold_by_weight: str = Form(""),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    p = db.query(models.Product).filter(models.Product.id == product_id).first()
    if p:
        try:
            p.name = name
            p.category_id = int(category_id) if category_id else None
            p.price = Decimal(price)
            p.description = description or None
            p.sort_order = int(sort_order) if sort_order else 0
            p.sold_by_weight = bool(sold_by_weight)
            db.commit()
        except Exception:
            pass
    return RedirectResponse(url="/web/products", status_code=303)


@router.post("/products/{product_id}/delete")
async def delete_product(
    product_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    p = db.query(models.Product).filter(models.Product.id == product_id).first()
    if p:
        p.is_deleted = True
        db.commit()
    return RedirectResponse(url="/web/products", status_code=303)


@router.post("/categories/reorder")
async def web_reorder_categories(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    items = await request.json()
    for item in items:
        cat = db.query(models.Category).filter(models.Category.id == item["id"]).first()
        if cat:
            cat.sort_order = item["sort_order"]
    db.commit()
    return JSONResponse({"ok": True})


@router.post("/categories/new")
async def create_category(
    name: str = Form(...),
    sort_order: str = Form("0"),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    try:
        db.add(models.Category(
            name=name,
            sort_order=int(sort_order) if sort_order else 0,
            is_active=True,
        ))
        db.commit()
    except Exception:
        pass
    return RedirectResponse(url="/web/products", status_code=303)


@router.post("/categories/{category_id}/edit")
async def edit_category(
    category_id: int,
    name: str = Form(...),
    sort_order: str = Form("0"),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    cat = db.query(models.Category).filter(models.Category.id == category_id).first()
    if cat:
        try:
            cat.name = name.strip()
            cat.sort_order = int(sort_order) if sort_order else 0
            db.commit()
        except Exception:
            pass
    return RedirectResponse(url="/web/products", status_code=303)


@router.post("/categories/{category_id}/delete")
async def delete_category(
    category_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    cat = db.query(models.Category).filter(models.Category.id == category_id).first()
    if cat:
        cat.is_active = False
        db.commit()
    return RedirectResponse(url="/web/products", status_code=303)


# ── Promotions ─────────────────────────────────────────────────────────────────

def _get_all_active_products(db: Session):
    return (
        db.query(models.Product)
        .filter(models.Product.is_deleted == False, models.Product.status == "active")
        .order_by(models.Product.name)
        .all()
    )


def _build_conditions(promo_type: str, form_data) -> dict:
    if promo_type == "discount_pct":
        return {"percent": float(form_data.get("conditions_percent", 0) or 0)}
    elif promo_type == "b1f1":
        return {"product_id": int(form_data.get("conditions_product_id", 0) or 0)}
    elif promo_type == "happy_hour":
        return {
            "percent": float(form_data.get("conditions_percent", 0) or 0),
            "start_time": str(form_data.get("conditions_start_time", "") or ""),
            "end_time": str(form_data.get("conditions_end_time", "") or ""),
        }
    elif promo_type == "promo_code":
        return {
            "code": str(form_data.get("conditions_code", "") or ""),
            "percent": float(form_data.get("conditions_percent", 0) or 0),
            "usage_limit": int(form_data.get("conditions_usage_limit", 0) or 0),
            "min_order": float(form_data.get("conditions_min_order", 0) or 0),
        }
    return {}


@router.get("/promotions", response_class=HTMLResponse)
async def promotions_list(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    promotions = (
        db.query(models.Promotion)
        .filter(models.Promotion.is_deleted == False)
        .order_by(models.Promotion.is_active.desc(), models.Promotion.id.desc())
        .all()
    )
    return TEMPLATES.TemplateResponse(request, "promotions.html", _ctx(user, promotions=promotions))


@router.get("/promotions/new", response_class=HTMLResponse)
async def new_promotion_form(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    return TEMPLATES.TemplateResponse(request, "promotion_form.html", _ctx(
        user,
        promo=None,
        products=_get_all_active_products(db),
        form_action="/web/promotions/new",
        page_title="New Promotion",
    ))


@router.post("/promotions/new")
async def create_promotion(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    form = await request.form()
    promo_type = str(form.get("type", "discount_pct"))
    starts_at_raw = form.get("starts_at", "")
    ends_at_raw = form.get("ends_at", "")
    try:
        db.add(models.Promotion(
            name=str(form.get("name", "")),
            type=promo_type,
            conditions=_build_conditions(promo_type, form),
            starts_at=datetime.fromisoformat(starts_at_raw) if starts_at_raw else None,
            ends_at=datetime.fromisoformat(ends_at_raw) if ends_at_raw else None,
            is_active=bool(form.get("is_active")),
            is_deleted=False,
            usage_count=0,
            created_by=user.id,
        ))
        db.commit()
    except Exception:
        pass
    return RedirectResponse(url="/web/promotions", status_code=303)


@router.get("/promotions/{promotion_id}/edit", response_class=HTMLResponse)
async def edit_promotion_form(
    promotion_id: int,
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    promo = db.query(models.Promotion).filter(
        models.Promotion.id == promotion_id,
        models.Promotion.is_deleted == False,
    ).first()
    if not promo:
        return RedirectResponse(url="/web/promotions", status_code=303)
    return TEMPLATES.TemplateResponse(request, "promotion_form.html", _ctx(
        user,
        promo=promo,
        products=_get_all_active_products(db),
        form_action=f"/web/promotions/{promotion_id}/edit",
        page_title="Edit Promotion",
    ))


@router.post("/promotions/{promotion_id}/edit")
async def update_promotion(
    promotion_id: int,
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    promo = db.query(models.Promotion).filter(
        models.Promotion.id == promotion_id,
        models.Promotion.is_deleted == False,
    ).first()
    if promo:
        form = await request.form()
        promo_type = str(form.get("type", promo.type))
        starts_at_raw = form.get("starts_at", "")
        ends_at_raw = form.get("ends_at", "")
        try:
            promo.name = str(form.get("name", promo.name))
            promo.type = promo_type
            promo.conditions = _build_conditions(promo_type, form)
            promo.starts_at = datetime.fromisoformat(starts_at_raw) if starts_at_raw else None
            promo.ends_at = datetime.fromisoformat(ends_at_raw) if ends_at_raw else None
            promo.is_active = bool(form.get("is_active"))
            db.commit()
        except Exception:
            pass
    return RedirectResponse(url="/web/promotions", status_code=303)


@router.post("/promotions/{promotion_id}/delete")
async def delete_promotion(
    promotion_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    promo = db.query(models.Promotion).filter(models.Promotion.id == promotion_id).first()
    if promo:
        promo.is_deleted = True
        db.commit()
    return RedirectResponse(url="/web/promotions", status_code=303)


@router.post("/promotions/{promotion_id}/toggle")
async def toggle_promotion(
    promotion_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    promo = db.query(models.Promotion).filter(models.Promotion.id == promotion_id).first()
    if promo:
        promo.is_active = not promo.is_active
        db.commit()
    return RedirectResponse(url="/web/promotions", status_code=303)


# ── Users ──────────────────────────────────────────────────────────────────────

@router.get("/users", response_class=HTMLResponse)
async def users_list(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
    created: str = None,
    updated: str = None,
    error: str = None,
):
    users = (
        db.query(models.User)
        .filter(models.User.is_deleted == False)
        .order_by(models.User.id)
        .all()
    )
    return TEMPLATES.TemplateResponse(request, "users.html", _ctx(
        user, users=users, created=created, updated=updated, error=error,
    ))


@router.post("/users")
async def create_user(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
    username: str = Form(...),
    full_name: str = Form(...),
    password: str = Form(...),
):
    from auth import hash_password
    username = username.strip()
    existing = db.query(models.User).execution_options(skip_tenant_scope=True).filter(
        func.lower(models.User.username) == username.lower()
    ).first()
    if existing:
        return RedirectResponse(url=f"/web/users?error=Username+'{username}'+already+exists", status_code=303)
    if len(password) < 8:
        return RedirectResponse(url="/web/users?error=Password+must+be+at+least+8+characters", status_code=303)
    db.add(models.User(
        restaurant_id=user.restaurant_id,
        username=username,
        full_name=full_name,
        role="cashier",
        password_hash=hash_password(password),
        is_active=True,
    ))
    db.commit()
    created_user = db.query(models.User).filter(models.User.username == username).first()
    if created_user:
        sync_user_shadow(db, created_user)
    return RedirectResponse(url=f"/web/users?created={username}", status_code=303)


@router.post("/users/{user_id}/edit")
async def edit_user(
    user_id: int,
    full_name: str = Form(""),
    db: Session = Depends(get_db),
    current_admin: models.User = Depends(_require_web_admin),
):
    u = db.query(models.User).filter(models.User.id == user_id).first()
    if u and u.id != current_admin.id:
        if full_name.strip():
            u.full_name = full_name.strip()
        db.commit()
        sync_user_shadow(db, u)
    return RedirectResponse(url="/web/users?updated=1", status_code=303)


@router.post("/users/{user_id}/permissions")
async def update_user_permissions_web(
    user_id: int,
    request: Request,
    db: Session = Depends(get_db),
    _=Depends(_require_web_admin),
):
    form = await request.form()
    can_view = bool(form.get("can_view_cash"))
    perms = {
        "can_view_cash":          can_view,
        # sub-perms forced False when view is disabled
        "can_add_cash":           can_view and bool(form.get("can_add_cash")),
        "can_edit_cash":          can_view and bool(form.get("can_edit_cash")),
        "can_delete_cash":        can_view and bool(form.get("can_delete_cash")),
        "can_manage_catalog":     bool(form.get("can_manage_catalog")),
        "can_manage_promotion":   bool(form.get("can_manage_promotion")),
        "can_manage_payment":     bool(form.get("can_manage_payment")),
        "can_manage_settings":    bool(form.get("can_manage_settings")),
        "hide_salary_from_cash":  bool(form.get("hide_salary_from_cash")),
    }
    u = db.query(models.User).filter(models.User.id == user_id).first()
    if u and u.role == "cashier":
        u.permissions = perms
        db.commit()
        sync_user_shadow(db, u)
    return RedirectResponse(url="/web/users?updated=1", status_code=303)


@router.post("/users/{user_id}/toggle")
async def toggle_user(
    user_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    u = db.query(models.User).filter(models.User.id == user_id).first()
    if u and u.id != user.id:
        u.is_active = not u.is_active
        db.commit()
        sync_user_shadow(db, u)
    return RedirectResponse(url="/web/users", status_code=303)


# ── Settings ───────────────────────────────────────────────────────────────────

_SETTINGS_KEYS = [
    "store_name", "store_address", "store_phone", "store_email",
    "store_ssm_number",
    "tax_registration_number",
    "sst_enabled", "sst_rate",
    "service_charge_enabled", "service_charge_rate",
    "payment_to_cash_record",
    "receipt_show_logo",
    "receipt_header", "receipt_header_size", "receipt_header_align",
    "receipt_footer", "receipt_footer_size", "receipt_footer_align",
]
_BOOL_SETTINGS = {
    "sst_enabled", "service_charge_enabled", "payment_to_cash_record",
    "receipt_show_logo",
}


def _settings_ctx(db: Session) -> dict:
    from settings_router import _DEFAULTS
    s = {k: _get_setting(db, k, _DEFAULTS.get(k, "")) for k in _SETTINGS_KEYS}
    s["store_logo_path"] = _get_setting(db, "store_logo_path", "")
    return s


@router.get("/settings", response_class=HTMLResponse)
async def get_settings(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    return TEMPLATES.TemplateResponse(request, "settings.html", _ctx(
        user, s=_settings_ctx(db), saved=False,
        drive=drive_connections.status(user.restaurant),
        drive_msg=request.query_params.get("drive", ""),
    ))


@router.post("/settings", response_class=HTMLResponse)
async def post_settings(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    form = await request.form()
    was_payment_to_cash_record = (
        _get_setting(db, "payment_to_cash_record", "0") == "1"
    )
    for k in _SETTINGS_KEYS:
        if k in _BOOL_SETTINGS:
            _put_setting(db, k, "1" if form.get(k) else "0")
        else:
            _put_setting(db, k, str(form.get(k, "")))
    payment_to_cash_record = bool(form.get("payment_to_cash_record"))
    if payment_to_cash_record != was_payment_to_cash_record:
        sync_payment_cash_records(db, enabled=payment_to_cash_record)
    db.commit()

    return TEMPLATES.TemplateResponse(request, "settings.html", _ctx(
        user, s=_settings_ctx(db), saved=True,
        drive=drive_connections.status(user.restaurant), drive_msg="",
    ))


@router.post("/settings/logo")
async def web_upload_logo(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    import uuid as _uuid
    from PIL import Image as _Image
    from pathlib import Path as _Path
    if file.content_type not in ("image/jpeg", "image/png", "image/webp"):
        return RedirectResponse(url="/web/settings?error=invalid_file", status_code=303)
    try:
        img = load_upload_image(file)
    except ValueError:
        return RedirectResponse(url="/web/settings?error=invalid_file", status_code=303)
    existing = db.query(models.StoreSettings).filter(
        models.StoreSettings.key == "store_logo_path"
    ).first()
    old_path = (
        _Path(__file__).parent / existing.value
        if existing and existing.value
        else None
    )
    upload_dir = _Path(__file__).parent / "static" / "images"
    upload_dir.mkdir(parents=True, exist_ok=True)
    filename = f"store_logo_{_uuid.uuid4().hex[:8]}.jpg"
    img.thumbnail((1600, 1600), _Image.Resampling.LANCZOS)
    img.save(upload_dir / filename, format="JPEG", quality=90, optimize=True)
    rel = f"static/images/{filename}"
    if existing:
        existing.value = rel
    else:
        db.add(models.StoreSettings(key="store_logo_path", value=rel))
    db.commit()
    if old_path:
        old_path.unlink(missing_ok=True)
    return RedirectResponse(url="/web/settings?saved=logo", status_code=303)


# ── Google Drive (per restaurant) ──────────────────────────────────────────────

_DRIVE_SETTINGS_URL = "/web/settings?drive={}#google-drive"


@router.get("/settings/google-drive/connect")
async def google_drive_connect(
    request: Request,
    user: models.User = Depends(_require_web_admin),
):
    if not drive_connections.oauth_configured():
        return RedirectResponse(url=_DRIVE_SETTINGS_URL.format("not_configured"), status_code=303)
    auth_url, nonce = drive_connections.build_authorization_url(user)
    resp = RedirectResponse(url=auth_url, status_code=303)
    resp.set_cookie(
        drive_connections.STATE_COOKIE, nonce, httponly=True,
        secure=os.getenv("WEB_COOKIE_SECURE", "true").lower() != "false",
        max_age=600, samesite="lax", path="/web/settings/google-drive",
    )
    return resp


@router.get("/settings/google-drive/callback")
async def google_drive_callback(
    request: Request,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    params = request.query_params
    nonce = request.cookies.get(drive_connections.STATE_COOKIE)
    if params.get("error"):
        # The Admin pressed Cancel on Google's consent screen.
        result = "cancelled"
    elif not drive_connections.verify_state(params.get("state", ""), nonce, user) or not params.get("code"):
        result = "invalid_state"
    else:
        try:
            await run_in_threadpool(drive_connections.complete_connection, db, user, params["code"])
            result = "connected"
        except Exception as exc:
            db.rollback()
            print(f"[google-drive] Restaurant {user.restaurant_id} connect failed: {exc}")
            result = "failed"
    resp = RedirectResponse(url=_DRIVE_SETTINGS_URL.format(result), status_code=303)
    resp.delete_cookie(drive_connections.STATE_COOKIE, path="/web/settings/google-drive")
    return resp


@router.post("/settings/google-drive/disconnect")
async def google_drive_disconnect(
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    await run_in_threadpool(drive_connections.disconnect, db, user.restaurant)
    return RedirectResponse(url=_DRIVE_SETTINGS_URL.format("disconnected"), status_code=303)


@router.get("/reports/annual/export")
def web_annual_csv_export(
    year: int = Query(..., ge=2000, le=2100),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    start_date = date(year, 1, 1)
    end_date = date(year, 12, 31)
    output = io.StringIO()
    writer = safe_csv_writer(output)

    # Section 1: Daily Sales
    writer.writerow([f"Annual Tax Report — {year}"])
    writer.writerow([])
    writer.writerow(["DAILY SALES"])
    sales = _sales_query(start_date, end_date, db)
    writer.writerow(["Date", "Revenue (MYR)", "Orders"])
    for d in sales.daily_breakdown:
        writer.writerow([d.date, str(d.revenue), d.orders])
    writer.writerow(["TOTAL", str(sales.total_revenue), sales.total_orders])
    writer.writerow([])

    # Section 2: Product Sales
    writer.writerow(["PRODUCT SALES"])
    products = _top_products_query(start_date, end_date, 500, db)
    writer.writerow(["Rank", "Product", "Category", "Qty Sold", "Revenue (MYR)"])
    for i, p in enumerate(products.products, 1):
        writer.writerow([i, p.product_name, p.category_name, format_qty(p.total_qty), str(p.total_revenue)])
    writer.writerow([])

    # Section 3: Cash In / Out
    writer.writerow(["CASH IN / OUT"])
    start_dt = datetime.combine(start_date, time.min)
    end_dt = datetime.combine(end_date, time.max)
    cash_records = (
        db.query(models.CashRecord)
        .filter(models.CashRecord.created_at >= start_dt, models.CashRecord.created_at <= end_dt)
        .order_by(models.CashRecord.created_at)
        .all()
    )
    writer.writerow(["Date", "Type", "Amount (MYR)", "Description", "Reference"])
    total_in = Decimal("0")
    total_out = Decimal("0")
    for r in cash_records:
        amt = _to_decimal(r.amount)
        writer.writerow([r.created_at.strftime("%Y-%m-%d %H:%M"), r.type, str(amt), r.description, r.reference or ""])
        if r.type == "cash_in":
            total_in += amt
        else:
            total_out += amt
    writer.writerow(["Total Cash In", "", str(total_in), "", ""])
    writer.writerow(["Total Cash Out", "", str(total_out), "", ""])
    writer.writerow(["Net Cash", "", str(total_in - total_out), "", ""])

    filename = f"annual_tax_report_{year}.csv"
    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


# ── Salary ─────────────────────────────────────────────────────────────────────

_FULL_MONTH_NAMES = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]


@router.get("/salary", response_class=HTMLResponse)
async def salary_page(
    request: Request,
    tab: str = "workers",
    ok: str = None,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    workers = (
        db.query(models.Worker)
        .filter(models.Worker.is_active == True)
        .order_by(models.Worker.name)
        .all()
    )
    payments = (
        db.query(models.SalaryPayment)
        .options(joinedload(models.SalaryPayment.worker))
        .order_by(models.SalaryPayment.created_at.desc())
        .limit(200)
        .all()
    )
    now = local_now()
    years = [now.year - 1, now.year, now.year + 1]

    return TEMPLATES.TemplateResponse(request, "salary.html", _ctx(
        user,
        tab=tab,
        ok=ok,
        workers=workers,
        payments=payments,
        months=_FULL_MONTH_NAMES,
        current_month=now.month,
        current_year=now.year,
        years=years,
    ))


@router.post("/salary/workers")
async def web_create_worker(
    name: str = Form(...),
    position: str = Form(""),
    phone: str = Form(""),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    name = name.strip()
    if name:
        db.add(models.Worker(
            name=name,
            position=position.strip() or None,
            phone=phone.strip() or None,
        ))
        db.commit()
    return RedirectResponse(url="/web/salary?tab=workers&ok=worker_added", status_code=303)


@router.post("/salary/workers/{worker_id}/edit")
async def web_edit_worker(
    worker_id: int,
    name: str = Form(...),
    position: str = Form(""),
    phone: str = Form(""),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    w = db.query(models.Worker).filter(models.Worker.id == worker_id).first()
    if w:
        name = name.strip()
        if name:
            w.name = name
        w.position = position.strip() or None
        w.phone = phone.strip() or None
        db.commit()
    return RedirectResponse(url="/web/salary?tab=workers&ok=worker_edited", status_code=303)


@router.post("/salary/workers/{worker_id}/delete")
async def web_delete_worker(
    worker_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    w = db.query(models.Worker).filter(models.Worker.id == worker_id).first()
    if w:
        w.is_active = False
        db.commit()
    return RedirectResponse(url="/web/salary?tab=workers&ok=worker_deleted", status_code=303)


@router.post("/salary/payments")
async def web_create_payment(
    worker_id: str = Form(...),
    month: str = Form(...),
    year: str = Form(...),
    amount: str = Form(...),
    note: str = Form(""),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    try:
        wid = int(worker_id)
        m = int(month)
        y = int(year)
        amt = Decimal(amount)
        worker = db.query(models.Worker).filter(
            models.Worker.id == wid, models.Worker.is_active == True
        ).first()
        if worker and 1 <= m <= 12 and amt > 0:
            description = f"Salary - {worker.name} ({_MONTH_NAMES[m - 1]} {y})"
            cash_record = models.CashRecord(
                type="cash_out",
                amount=amt,
                description=description,
                category="Salary",
                created_by=user.id,
            )
            db.add(cash_record)
            db.flush()
            db.add(models.SalaryPayment(
                worker_id=wid,
                year=y,
                month=m,
                amount=amt,
                note=note.strip() or None,
                cash_record_id=cash_record.id,
                created_by=user.id,
            ))
            db.commit()
    except Exception:
        pass
    return RedirectResponse(url="/web/salary?tab=payments&ok=paid", status_code=303)


@router.post("/salary/payments/{payment_id}/edit")
async def web_edit_payment(
    payment_id: int,
    amount: str = Form(...),
    note: str = Form(""),
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    p = db.query(models.SalaryPayment).filter(models.SalaryPayment.id == payment_id).first()
    if p:
        try:
            amt = Decimal(amount)
            if amt > 0:
                p.amount = amt
                if p.cash_record_id:
                    cash = db.query(models.CashRecord).filter(
                        models.CashRecord.id == p.cash_record_id
                    ).first()
                    if cash:
                        cash.amount = amt
            p.note = note.strip() or None
            db.commit()
        except Exception:
            pass
    return RedirectResponse(url="/web/salary?tab=payments&ok=payment_edited", status_code=303)


@router.post("/salary/payments/{payment_id}/delete")
async def web_delete_payment(
    payment_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    p = db.query(models.SalaryPayment).filter(models.SalaryPayment.id == payment_id).first()
    if p:
        if p.cash_record_id:
            cash = db.query(models.CashRecord).filter(
                models.CashRecord.id == p.cash_record_id
            ).first()
            if cash:
                db.delete(cash)
        db.delete(p)
        db.commit()
    return RedirectResponse(url="/web/salary?tab=payments&ok=payment_deleted", status_code=303)


@router.get("/salary/payments/{payment_id}/print")
async def print_salary_slip(
    payment_id: int,
    db: Session = Depends(get_db),
    user: models.User = Depends(_require_web_admin),
):
    p = db.query(models.SalaryPayment).options(
        joinedload(models.SalaryPayment.worker)
    ).filter(models.SalaryPayment.id == payment_id).first()
    if not p:
        return RedirectResponse(url="/web/salary?tab=payments", status_code=303)

    store_name = _get_setting(db, "store_name", "POS System")
    now = local_now()
    printed_at = now.strftime("%d/%m/%Y %H:%M")
    month_name = _FULL_MONTH_NAMES[p.month - 1]
    position = (p.worker.position or "") if p.worker else ""

    # ── Pre-calculate exact page height ──
    LH = {8: 8 * 1.5, 9: 9 * 1.5, 10: 10 * 1.5, 11: 11 * 1.5, 12: 12 * 1.5}
    PAD = 6 * mm
    needed = (
        14              # top margin
        + LH[12] + 4   # store name + gap
        + LH[10]       # SALARY SLIP
        + LH[10]       # month year
        + 12           # divider
        + LH[10]       # Name row
        + (LH[10] if position else 0)
        + 12           # divider
        + LH[12]       # Salary row (bold/larger)
        + (LH[9] if p.note else 0)
        + 12           # divider
        + 6            # gap before "Received by"
        + LH[10]       # "Received by:"
        + 30           # signature space
        + 6            # after sig line gap
        + LH[8]        # "Signature" label
        + 6            # gap
        + LH[8]        # "Printed:" line
        + 16           # bottom margin
    )

    width = 80 * mm
    height = needed
    buf = io.BytesIO()
    c = rl_canvas.Canvas(buf, pagesize=(width, height))

    y = height - 14

    def draw_line(text, size=10, bold=False, align="center"):
        nonlocal y
        c.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        if align == "center":
            c.drawCentredString(width / 2, y, text)
        else:
            c.drawString(PAD, y, text)
        y -= LH[size]

    def draw_lr(left, right, size=10, bold=False):
        nonlocal y
        c.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        c.drawString(PAD, y, left)
        c.drawRightString(width - PAD, y, right)
        y -= LH[size]

    def draw_divider():
        nonlocal y
        c.setDash(3, 3)
        c.line(PAD, y + 3, width - PAD, y + 3)
        c.setDash()
        y -= 12

    draw_line(store_name, size=12, bold=True)
    y -= 4
    draw_line("** SALARY SLIP **", size=10, bold=True)
    draw_line(f"{month_name} {p.year}", size=10)
    draw_divider()
    draw_lr("Name", p.worker_name)
    if position:
        draw_lr("Position", position)
    draw_divider()
    draw_lr("Salary", f"RM {float(p.amount):.2f}", size=12, bold=True)
    if p.note:
        draw_line(f"Note: {p.note}", size=9, align="left")
    draw_divider()
    y -= 6
    draw_line("Received by:", size=10, align="left")
    y -= 24
    c.line(PAD, y, width - PAD * 2, y)
    y -= 6
    draw_line("Signature", size=8, align="left")
    y -= 6
    draw_line(f"Printed: {printed_at}", size=8, align="left")

    c.save()

    buf.seek(0)
    safe_name = p.worker_name.replace(" ", "_")
    filename = f"salary_slip_{safe_name}_{month_name}_{p.year}.pdf"
    return Response(
        content=buf.read(),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
