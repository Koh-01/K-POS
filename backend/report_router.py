import io
import csv
from decimal import Decimal, ROUND_HALF_UP
from datetime import date, datetime, time
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import Response
from sqlalchemy.orm import Session
from sqlalchemy import Numeric, case, cast, func

from database import get_db
from dependencies import require_admin
import models
import schemas
from time_utils import local_today
from csv_utils import format_qty, safe_csv_writer

router = APIRouter(prefix="/reports", tags=["Reports"])

TWO_PLACES = Decimal("0.01")


def _to_decimal(val) -> Decimal:
    return Decimal(str(val)).quantize(TWO_PLACES, ROUND_HALF_UP)


def _date_range(start_date: date, end_date: date):
    if end_date < start_date:
        raise HTTPException(status_code=400, detail="end_date must be >= start_date")
    return datetime.combine(start_date, time.min), datetime.combine(end_date, time.max)


# ── Dashboard ─────────────────────────────────────────────────────────────────

@router.get("/dashboard", response_model=schemas.DashboardResponse)
def get_dashboard(
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    today = local_today()
    start_dt = datetime.combine(today, time.min)
    end_dt = datetime.combine(today, time.max)

    today_revenue = db.query(func.sum(models.Payment.grand_total)).filter(
        models.Payment.status == "completed",
        models.Payment.created_at >= start_dt,
        models.Payment.created_at <= end_dt,
    ).scalar() or Decimal("0")

    orders_today = db.query(func.count(models.Order.id)).filter(
        models.Order.is_deleted == False,
        models.Order.created_at >= start_dt,
        models.Order.created_at <= end_dt,
    ).scalar() or 0

    top_row = (
        db.query(
            models.Product.name,
            func.sum(case(
                (models.OrderItem.weight_kg.isnot(None), models.OrderItem.weight_kg),
                else_=cast(models.OrderItem.quantity, Numeric(12, 3)),
            )).label("total_qty"),
        )
        .select_from(models.Payment)
        .join(models.Order, models.Order.id == models.Payment.order_id)
        .join(models.OrderItem, models.OrderItem.order_id == models.Order.id)
        .join(models.Product, models.Product.id == models.OrderItem.product_id)
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at >= start_dt,
            models.Payment.created_at <= end_dt,
        )
        .group_by(models.Product.id, models.Product.name)
        .order_by(func.sum(case(
            (models.OrderItem.weight_kg.isnot(None), models.OrderItem.weight_kg),
            else_=cast(models.OrderItem.quantity, Numeric(12, 3)),
        )).desc())
        .first()
    )

    active_tables = db.query(func.count(models.Table.id)).filter(
        models.Table.status == "occupied",
        models.Table.is_active == True,
    ).scalar() or 0

    cash_in_today = db.query(func.sum(models.CashRecord.amount)).filter(
        models.CashRecord.type == "cash_in",
        models.CashRecord.created_at >= start_dt,
        models.CashRecord.created_at <= end_dt,
    ).scalar() or Decimal("0")

    cash_out_today = db.query(func.sum(models.CashRecord.amount)).filter(
        models.CashRecord.type == "cash_out",
        models.CashRecord.created_at >= start_dt,
        models.CashRecord.created_at <= end_dt,
    ).scalar() or Decimal("0")

    return schemas.DashboardResponse(
        today_revenue=_to_decimal(today_revenue),
        orders_today=orders_today,
        top_product_today=top_row[0] if top_row else None,
        active_tables=active_tables,
        total_cash_in_today=_to_decimal(cash_in_today),
        total_cash_out_today=_to_decimal(cash_out_today),
    )


# ── Sales Summary (daily breakdown) ──────────────────────────────────────────

def _sales_query(start_date: date, end_date: date, db: Session) -> schemas.SalesReportResponse:
    start_dt, end_dt = _date_range(start_date, end_date)

    rows = (
        db.query(
            func.date(models.Payment.created_at).label("sale_date"),
            func.sum(models.Payment.grand_total).label("revenue"),
            func.count(models.Payment.id).label("orders"),
        )
        .filter(
            models.Payment.status == "completed",
            models.Payment.created_at >= start_dt,
            models.Payment.created_at <= end_dt,
        )
        .group_by(func.date(models.Payment.created_at))
        .order_by(func.date(models.Payment.created_at))
        .all()
    )

    daily = [
        schemas.DailySalesSummary(
            date=str(row.sale_date),
            revenue=_to_decimal(row.revenue),
            orders=row.orders,
        )
        for row in rows
    ]

    total_revenue = sum((d.revenue for d in daily), Decimal("0"))
    total_orders = sum(d.orders for d in daily)

    return schemas.SalesReportResponse(
        start_date=str(start_date),
        end_date=str(end_date),
        total_revenue=total_revenue,
        total_orders=total_orders,
        daily_breakdown=daily,
    )


@router.get("/sales", response_model=schemas.SalesReportResponse)
def sales_report(
    start_date: date = Query(...),
    end_date: date = Query(...),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    return _sales_query(start_date, end_date, db)


# ── Annual Report (monthly breakdown) ────────────────────────────────────────

@router.get("/sales/annual", response_model=schemas.AnnualReportResponse)
def annual_report(
    year: int = Query(..., ge=2000, le=2100),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    start_dt = datetime(year, 1, 1, 0, 0, 0)
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
            models.Payment.created_at >= start_dt,
            models.Payment.created_at <= end_dt,
        )
        .group_by(
            func.year(models.Payment.created_at),
            func.month(models.Payment.created_at),
        )
        .order_by(func.year(models.Payment.created_at), func.month(models.Payment.created_at))
        .all()
    )

    monthly = [
        schemas.MonthlySalesSummary(
            month=f"{int(row.yr)}-{int(row.mn):02d}",
            revenue=_to_decimal(row.revenue),
            orders=row.orders,
        )
        for row in rows
    ]

    total_revenue = sum((m.revenue for m in monthly), Decimal("0"))
    total_orders = sum(m.orders for m in monthly)

    return schemas.AnnualReportResponse(
        year=year,
        total_revenue=total_revenue,
        total_orders=total_orders,
        monthly_breakdown=monthly,
    )


# ── Yearly Aggregation ───────────────────────────────────────────────────────

@router.get("/sales/yearly")
def yearly_sales_report(
    db: Session = Depends(get_db),
    _=Depends(require_admin),
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

    yearly = [
        {
            "year": int(row.yr),
            "revenue": float(_to_decimal(row.revenue)),
            "orders": row.orders,
        }
        for row in rows
    ]
    total_revenue = round(sum(y["revenue"] for y in yearly), 2)
    total_orders = sum(y["orders"] for y in yearly)

    return {
        "total_revenue": total_revenue,
        "total_orders": total_orders,
        "yearly_breakdown": yearly,
    }


# ── Top Products ──────────────────────────────────────────────────────────────

def _top_products_query(
    start_date: date, end_date: date, limit: int, db: Session
) -> schemas.TopProductsResponse:
    start_dt, end_dt = _date_range(start_date, end_date)

    sold_amount = case(
        (models.OrderItem.weight_kg.isnot(None), models.OrderItem.weight_kg),
        else_=cast(models.OrderItem.quantity, Numeric(12, 3)),
    )
    category_name = func.coalesce(models.Category.name, "Uncategorised")

    rows = (
        db.query(
            models.Product.id.label("product_id"),
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
            models.Payment.created_at <= end_dt,
        )
        .group_by(models.Product.id, models.Product.name, category_name)
        .order_by(func.sum(sold_amount).desc())
        .limit(limit)
        .all()
    )

    products = [
        schemas.ProductSalesItem(
            product_id=row.product_id,
            product_name=row.product_name,
            category_name=row.category_name,
            total_qty=row.total_qty,
            total_revenue=_to_decimal(row.total_revenue),
        )
        for row in rows
    ]

    return schemas.TopProductsResponse(
        start_date=str(start_date),
        end_date=str(end_date),
        products=products,
    )


@router.get("/top-products", response_model=schemas.TopProductsResponse)
def top_products(
    start_date: date = Query(...),
    end_date: date = Query(...),
    limit: int = Query(default=10, ge=1, le=100),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    return _top_products_query(start_date, end_date, limit, db)


# ── CSV Export: Sales ─────────────────────────────────────────────────────────

@router.get("/sales/export/csv")
def export_sales_csv(
    start_date: date = Query(...),
    end_date: date = Query(...),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    report = _sales_query(start_date, end_date, db)

    output = io.StringIO()
    writer = safe_csv_writer(output)
    writer.writerow(["Date", "Revenue (MYR)", "Orders"])
    for d in report.daily_breakdown:
        writer.writerow([d.date, str(d.revenue), d.orders])
    writer.writerow([])
    writer.writerow(["TOTAL", str(report.total_revenue), report.total_orders])

    filename = f"sales_{start_date}_{end_date}.csv"
    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


# ── CSV Export: Top Products ──────────────────────────────────────────────────

@router.get("/products/export/csv")
def export_products_csv(
    start_date: date = Query(...),
    end_date: date = Query(...),
    limit: int = Query(default=100, ge=1, le=500),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    report = _top_products_query(start_date, end_date, limit, db)

    output = io.StringIO()
    writer = safe_csv_writer(output)
    writer.writerow(["Rank", "Product", "Category", "Qty Sold", "Revenue (MYR)"])
    for i, p in enumerate(report.products, 1):
        writer.writerow([i, p.product_name, p.category_name, format_qty(p.total_qty), str(p.total_revenue)])

    filename = f"products_{start_date}_{end_date}.csv"
    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


# ── Annual Tax Report CSV (3-in-1) ────────────────────────────────────────────

@router.get("/annual/export/csv")
def export_annual_tax_csv(
    year: int = Query(..., ge=2000, le=2100),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    """
    All-in-one annual CSV for tax purposes.
    Section 1: daily sales breakdown
    Section 2: full product sales
    Section 3: all cash in/out records
    """
    start_date = date(year, 1, 1)
    end_date = date(year, 12, 31)

    output = io.StringIO()
    writer = safe_csv_writer(output)

    # ── Section 1: Daily Sales ────────────────────────────────────────────────
    writer.writerow([f"Annual Tax Report — {year}"])
    writer.writerow([])
    writer.writerow(["DAILY SALES"])

    sales = _sales_query(start_date, end_date, db)
    writer.writerow(["Date", "Revenue (MYR)", "Orders"])
    for d in sales.daily_breakdown:
        writer.writerow([d.date, str(d.revenue), d.orders])
    writer.writerow(["TOTAL", str(sales.total_revenue), sales.total_orders])
    writer.writerow([])

    # ── Section 2: Product Sales ──────────────────────────────────────────────
    writer.writerow(["PRODUCT SALES"])
    products = _top_products_query(start_date, end_date, 500, db)
    writer.writerow(["Rank", "Product", "Category", "Qty Sold", "Revenue (MYR)"])
    for i, p in enumerate(products.products, 1):
        writer.writerow([i, p.product_name, p.category_name, format_qty(p.total_qty), str(p.total_revenue)])
    writer.writerow([])

    # ── Section 3: Cash In / Out ──────────────────────────────────────────────
    writer.writerow(["CASH IN / OUT"])
    start_dt = datetime.combine(start_date, time.min)
    end_dt = datetime.combine(end_date, time.max)
    cash_records = (
        db.query(models.CashRecord)
        .filter(
            models.CashRecord.created_at >= start_dt,
            models.CashRecord.created_at <= end_dt,
        )
        .order_by(models.CashRecord.created_at)
        .all()
    )
    writer.writerow(["Date", "Type", "Amount (MYR)", "Description", "Reference"])
    total_in = Decimal("0")
    total_out = Decimal("0")
    for r in cash_records:
        amt = _to_decimal(r.amount)
        writer.writerow([
            r.created_at.strftime("%Y-%m-%d %H:%M"),
            r.type,
            str(amt),
            r.description,
            r.reference or "",
        ])
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
