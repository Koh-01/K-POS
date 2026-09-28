"""
Monthly report generator — creates a CSV with sales, top products, and cash records
for a given month, then uploads it to the restaurant's own Google Drive.

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
from sqlalchemy import Numeric, case, cast, func

import models
from database import SessionLocal, select_restaurant_database
from drive_connections import DriveNotConnected, upload_for_restaurant
from gdrive_backup import _upload
from tenant_backup import BACKUP_PREFIX
from csv_utils import format_qty, safe_csv_writer

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
    w = safe_csv_writer(output)

    month_label = f"{year}-{month:02d}"

    # ── Section 1: Daily Sales ────────────────────────────────────────────────
    w.writerow([f"Monthly Sales Report — {month_label}"])
    w.writerow([])
    w.writerow(["DAILY SALES"])
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
    w.writerow(["PRODUCT SALES"])
    w.writerow(["Rank", "Product", "Category", "Qty Sold", "Revenue (MYR)"])

    sold_amount = case(
        (models.OrderItem.weight_kg.isnot(None), models.OrderItem.weight_kg),
        else_=cast(models.OrderItem.quantity, Numeric(12, 3)),
    )
    category_name = func.coalesce(models.Category.name, "Uncategorised")
    product_rows = (
        db.query(
            models.Product.name.label("product_name"),
            category_name.label("category_name"),
            func.sum(sold_amount).label("total_qty"),
            func.sum(models.OrderItem.unit_price * sold_amount).label("total_revenue"),
        )
        .select_from(models.Payment)
        .join(models.Order, models.Order.id == models.Payment.order_id)
        .join(models.OrderItem, models.OrderItem.order_id == models.Order.id)
        .join(models.Product, models.Product.id == models.OrderItem.product_id)
        .outerjoin(models.Category, models.Category.id == models.Product.category_id)
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at >= start_dt,
            models.Payment.created_at < end_dt,
        )
        .group_by(models.Product.id, models.Product.name, category_name)
        .order_by(func.sum(sold_amount).desc())
        .all()
    )

    for i, row in enumerate(product_rows, 1):
        w.writerow([i, row.product_name, row.category_name, format_qty(row.total_qty), str(_to_dec(row.total_revenue))])

    w.writerow([])

    # ── Section 3: Cash In / Out ──────────────────────────────────────────────
    w.writerow(["CASH IN / OUT"])
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


def run_monthly_report(year: int, month: int, restaurant_id: int | None = None) -> dict:
    """Generate and upload the monthly report CSV. Returns filename + drive_file_id.

    Restaurant reports go to that restaurant's own connected Google Drive; the
    all-restaurant report (restaurant_id=None) goes to the operator's Drive.
    """
    db: Session = SessionLocal()
    try:
        restaurant = None
        if restaurant_id is not None:
            restaurant = db.query(models.Restaurant).filter(models.Restaurant.id == restaurant_id).first()
            if not restaurant:
                raise RuntimeError("Restaurant not found")
            if restaurant.drive_connection is None:
                raise DriveNotConnected(
                    "Google Drive is not connected. Connect it in Web Admin → Settings → Google Drive."
                )
            select_restaurant_database(db, restaurant)
        else:
            folder_id = os.getenv("GDRIVE_FOLDER_ID")
            if not folder_id:
                raise RuntimeError("GDRIVE_FOLDER_ID not set in environment")
        csv_content = _build_csv(year, month, db)

        prefix = f"kpos_{restaurant.slug}" if restaurant is not None else "kpos_all"
        filename = f"{prefix}_monthly_{year}_{month:02d}.csv"
        tmp_path = Path(__file__).parent / "backups" / filename
        tmp_path.parent.mkdir(exist_ok=True)
        try:
            tmp_path.write_text(csv_content, encoding="utf-8-sig")   # utf-8-sig for Excel compatibility
            if restaurant is not None:
                drive_file_id = upload_for_restaurant(db, restaurant, str(tmp_path), filename, BACKUP_PREFIX)
            else:
                drive_file_id = _upload(str(tmp_path), filename, folder_id)
        finally:
            tmp_path.unlink(missing_ok=True)
    finally:
        db.close()

    return {"status": "ok", "filename": filename, "drive_file_id": drive_file_id, "year": year, "month": month}
