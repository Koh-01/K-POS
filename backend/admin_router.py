from datetime import datetime, timedelta
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from database import get_db
from dependencies import require_admin
import models
import schemas
from time_utils import local_now

router = APIRouter(prefix="/admin", tags=["Admin"])


# ── Login Logs ────────────────────────────────────────────────────────────────

@router.get("/login-logs", response_model=list[schemas.LoginLogResponse])
def list_login_logs(
    username: str | None = None,
    success: bool | None = None,
    limit: int = Query(50, ge=1, le=200),
    page: int = Query(1, ge=1),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    q = db.query(models.LoginLog).order_by(models.LoginLog.id.desc())
    if username:
        q = q.filter(models.LoginLog.username.contains(username))
    if success is not None:
        q = q.filter(models.LoginLog.success == success)
    return q.offset((page - 1) * limit).limit(limit).all()


# ── Data Retention ────────────────────────────────────────────────────────────

def _cutoff(years: int) -> datetime:
    return local_now() - timedelta(days=365 * years)


def _old_order_ids(db: Session, cutoff: datetime) -> list[int]:
    return [
        o.id for o in db.query(models.Order.id).filter(
            models.Order.created_at < cutoff,
            models.Order.status.in_(["paid", "cancelled"]),
        ).all()
    ]


def _payment_ids_for_orders(db: Session, order_ids: list[int]) -> list[int]:
    if not order_ids:
        return []
    return [
        p.id for p in db.query(models.Payment.id).filter(
            models.Payment.order_id.in_(order_ids)
        ).all()
    ]


@router.get("/data-retention/preview", response_model=schemas.DataRetentionPreview)
def data_retention_preview(
    years: int = Query(2, ge=1, le=10),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    cutoff = _cutoff(years)
    order_ids = _old_order_ids(db, cutoff)
    payment_ids = _payment_ids_for_orders(db, order_ids)

    audit_count = (
        db.query(models.PaymentAuditLog)
        .filter(models.PaymentAuditLog.payment_id.in_(payment_ids))
        .count()
    ) if payment_ids else 0

    return schemas.DataRetentionPreview(
        cutoff_date=cutoff.strftime("%Y-%m-%d"),
        orders_to_delete=len(order_ids),
        payments_to_delete=len(payment_ids),
        cash_records_to_delete=db.query(models.CashRecord)
            .filter(models.CashRecord.created_at < cutoff).count(),
        login_logs_to_delete=db.query(models.LoginLog)
            .filter(models.LoginLog.created_at < cutoff).count(),
        audit_logs_to_delete=audit_count,
    )


@router.post("/data-retention/cleanup")
def data_retention_cleanup(
    years: int = Query(2, ge=1, le=10),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    cutoff = _cutoff(years)
    order_ids = _old_order_ids(db, cutoff)
    payment_ids = _payment_ids_for_orders(db, order_ids)

    deleted: dict[str, int] = {
        "audit_logs": 0,
        "payments": 0,
        "order_items": 0,
        "orders": 0,
        "cash_records": 0,
        "login_logs": 0,
    }

    if payment_ids:
        deleted["audit_logs"] = db.query(models.PaymentAuditLog).filter(
            models.PaymentAuditLog.payment_id.in_(payment_ids)
        ).delete(synchronize_session=False)

        deleted["payments"] = db.query(models.Payment).filter(
            models.Payment.order_id.in_(order_ids)
        ).delete(synchronize_session=False)

    if order_ids:
        deleted["order_items"] = db.query(models.OrderItem).filter(
            models.OrderItem.order_id.in_(order_ids)
        ).delete(synchronize_session=False)

        deleted["orders"] = db.query(models.Order).filter(
            models.Order.id.in_(order_ids)
        ).delete(synchronize_session=False)

    deleted["cash_records"] = db.query(models.CashRecord).filter(
        models.CashRecord.created_at < cutoff
    ).delete(synchronize_session=False)

    deleted["login_logs"] = db.query(models.LoginLog).filter(
        models.LoginLog.created_at < cutoff
    ).delete(synchronize_session=False)

    db.commit()
    return {
        "status": "ok",
        "cutoff_date": cutoff.strftime("%Y-%m-%d"),
        "deleted": deleted,
    }
