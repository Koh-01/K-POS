"""
Monthly report generator — creates a CSV with sales, top products, and cash records
for a given month, then uploads it to Google Drive.

Called automatically on the 1st of each month at 01:00 (APScheduler in main.py).
Also exposed as POST /admin/monthly-report for manual triggers.
"""
import io
import csv
import os
from datetime import date, datetime, time
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

from sqlalchemy.orm import Session
from sqlalchemy import func

import models
from database import SessionLocal
from gdrive_backup import _upload

TWO = Decimal("0.01")


def _to_dec(val) -> Decimal:
    return Decimal(str(val or 0)).quantize(TWO, ROUND_HALF_UP)


def _build_csv(year: int, month: int, db: Session) -> str:
    """Build the full CSV content as a string."""
    start_dt = datetime(year, month, 1, 0, 0, 0)
    # Last day of month
    if month == 12:
        end_dt = datetime(year + 1, 1, 1, 0, 0, 0)
    else:
        end_dt = datetime(year, month + 1, 1, 0, 0, 0)

    output = io.StringIO()
    w = csv.writer(output)

    month_label = f"{year}-{month:02d}"

    # ── Section 1: Daily Sales ────────────────────────────────────────────────
    w.writerow([f"Monthly Sales Report — {month_label}"])
    w.writerow([])
    w.writerow(["=== DAILY SALES ==="])
    w.writerow(["Date", "Revenue (MYR)", "Orders"])

    daily_rows = (
        db.query(
            func.date(models.Payment.created_at).label("sale_date"),
            func.sum(models.Payment.grand_total).label("revenue"),
            func.count(models.Payment.id).label("orders"),
        )
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at >= start_dt,
            models.Payment.created_at < end_dt,
        )
        .group_by(func.date(models.Payment.created_at))
        .order_by(func.date(models.Payment.created_at))
        .all()
    )

    total_revenue = Decimal("0")
    total_orders = 0
    for row in daily_rows:
        rev = _to_dec(row.revenue)
        w.writerow([str(row.sale_date), str(rev), row.orders])
        total_revenue += rev
        total_orders += row.orders

    w.writerow(["TOTAL", str(total_revenue), total_orders])
    w.writerow([])

    # ── Section 2: Top Products ───────────────────────────────────────────────
    w.writerow(["=== PRODUCT SALES ==="])
    w.writerow(["Rank", "Product", "Category", "Qty Sold", "Revenue (MYR)"])

    product_rows = (
        db.query(
            models.Product.name.label("product_name"),
            models.Category.name.label("category_name"),
            func.sum(models.OrderItem.quantity).label("total_qty"),
            func.sum(models.OrderItem.unit_price * models.OrderItem.quantity).label("total_revenue"),
        )
        .select_from(models.Payment)
        .join(models.Order, models.Order.id == models.Payment.order_id)
        .join(models.OrderItem, models.OrderItem.order_id == models.Order.id)
        .join(models.Product, models.Product.id == models.OrderItem.product_id)
        .join(models.Category, models.Category.id == models.Product.category_id)
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at >= start_dt,
            models.Payment.created_at < end_dt,
        )
        .group_by(models.Product.id, models.Product.name, models.Category.name)
        .order_by(func.sum(models.OrderItem.quantity).desc())
        .all()
    )

    for i, row in enumerate(product_rows, 1):
        w.writerow([i, row.product_name, row.category_name, row.total_qty, str(_to_dec(row.total_revenue))])

    w.writerow([])

    # ── Section 3: Cash In / Out ──────────────────────────────────────────────
    w.writerow(["=== CASH IN / OUT ==="])
    w.writerow(["Date", "Type", "Amount (MYR)", "Description", "Reference"])

    cash_rows = (
        db.query(models.CashRecord)
        .filter(
            models.CashRecord.created_at >= start_dt,
            models.CashRecord.created_at < end_dt,
        )
        .order_by(models.CashRecord.created_at)
        .all()
    )

    total_in = Decimal("0")
    total_out = Decimal("0")
    for rec in cash_rows:
        amt = _to_dec(rec.amount)
        w.writerow([
            rec.created_at.strftime("%Y-%m-%d %H:%M"),
            rec.type,
            str(amt),
            rec.description,
            rec.reference or "",
        ])
        if rec.type == "cash_in":
            total_in += amt
        else:
            total_out += amt

    w.writerow(["Total Cash In", "", str(total_in), "", ""])
    w.writerow(["Total Cash Out", "", str(total_out), "", ""])
    w.writerow(["Net Cash", "", str(total_in - total_out), "", ""])

    return output.getvalue()


def run_monthly_report(year: int, month: int) -> dict:
    """Generate and upload the monthly report CSV. Returns filename + drive_file_id."""
    folder_id = os.getenv("GDRIVE_FOLDER_ID")
    if not folder_id:
        raise RuntimeError("GDRIVE_FOLDER_ID not set in environment")

    db: Session = SessionLocal()
    try:
        csv_content = _build_csv(year, month, db)
    finally:
        db.close()

    filename = f"pos_monthly_{year}_{month:02d}.csv"
    tmp_path = Path(__file__).parent / "backups" / filename
    tmp_path.parent.mkdir(exist_ok=True)

    try:
        tmp_path.write_text(csv_content, encoding="utf-8-sig")   # utf-8-sig for Excel compatibility
        drive_file_id = _upload(str(tmp_path), filename, folder_id)
    finally:
        try:
            tmp_path.unlink()
        except Exception:
            pass

    return {"status": "ok", "filename": filename, "drive_file_id": drive_file_id, "year": year, "month": month}
