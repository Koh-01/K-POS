from decimal import Decimal, ROUND_HALF_UP
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from datetime import datetime, timezone

from database import get_db
from dependencies import get_current_user, require_admin, require_permission
import models
import schemas
from settings_router import _get_settings
from promotion_router import compute_discount, find_by_code, _check_active

router = APIRouter()

TWO_PLACES = Decimal("0.01")


def _calc(
    items: list[models.OrderItem],
    discount_percent: Decimal,
    discount_amount: Decimal,
    cfg: dict,
) -> dict:
    subtotal = sum(
        Decimal(str(i.subtotal)) for i in items
    ).quantize(TWO_PLACES, ROUND_HALF_UP)

    # 折扣：percent 优先
    if discount_percent > 0:
        disc = (subtotal * discount_percent / 100).quantize(TWO_PLACES, ROUND_HALF_UP)
    else:
        disc = discount_percent  # 0
        if discount_amount > 0:
            disc = min(discount_amount, subtotal).quantize(TWO_PLACES, ROUND_HALF_UP)

    after_discount = subtotal - disc

    sc_rate = Decimal("0")
    sc_amount = Decimal("0")
    if cfg.get("service_charge_enabled") == "1":
        sc_rate = Decimal(cfg["service_charge_rate"])
        sc_amount = (after_discount * sc_rate).quantize(TWO_PLACES, ROUND_HALF_UP)

    sst_rate = Decimal("0")
    sst_amount = Decimal("0")
    if cfg.get("sst_enabled") == "1":
        sst_rate = Decimal(cfg["sst_rate"])
        sst_amount = ((after_discount + sc_amount) * sst_rate).quantize(TWO_PLACES, ROUND_HALF_UP)

    grand_total = (after_discount + sc_amount + sst_amount).quantize(TWO_PLACES, ROUND_HALF_UP)

    return {
        "subtotal": subtotal,
        "discount_percent": discount_percent,
        "discount_amount": disc,
        "service_charge_rate": sc_rate,
        "service_charge_amount": sc_amount,
        "sst_rate": sst_rate,
        "sst_amount": sst_amount,
        "grand_total": grand_total,
    }


# ── Payment Preview ───────────────────────────────────────────────────────────

@router.get("/orders/{order_id}/payment-preview", response_model=schemas.PaymentPreview)
def payment_preview(
    order_id: int,
    discount_percent: Decimal = Decimal("0"),
    discount_amount: Decimal = Decimal("0"),
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    order = db.query(models.Order).filter(
        models.Order.id == order_id,
        models.Order.is_deleted == False,
        models.Order.status == "open",
    ).first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found or not open")
    if not order.items:
        raise HTTPException(status_code=400, detail="Order has no items")

    result = _calc(order.items, discount_percent, discount_amount, _get_settings(db))
    return schemas.PaymentPreview(order_id=order_id, **result)


# ── Checkout ──────────────────────────────────────────────────────────────────

@router.post("/payments", response_model=schemas.PaymentResponse, status_code=201)
def create_payment(
    data: schemas.PaymentCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if data.payment_method not in ("cash", "duitnow", "card"):
        raise HTTPException(status_code=400, detail="payment_method must be 'cash', 'duitnow', or 'card'")

    order = db.query(models.Order).filter(
        models.Order.id == data.order_id,
        models.Order.is_deleted == False,
        models.Order.status == "open",
    ).first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found or not open")
    if not order.items:
        raise HTTPException(status_code=400, detail="Order has no items")

    already_paid = db.query(models.Payment).filter(
        models.Payment.order_id == data.order_id,
        models.Payment.status == "completed",
    ).first()
    if already_paid:
        raise HTTPException(status_code=400, detail="Order already paid")

    # Resolve promotion (overrides manual discount fields)
    promo: models.Promotion | None = None
    disc_pct = data.discount_percent
    disc_amt = data.discount_amount

    if data.promotion_id or data.promo_code:
        if data.promotion_id:
            promo = db.query(models.Promotion).filter(
                models.Promotion.id == data.promotion_id,
                models.Promotion.is_deleted == False,
            ).first()
            if not promo:
                raise HTTPException(status_code=404, detail="Promotion not found")
        else:
            promo = find_by_code(data.promo_code, db)
            if not promo:
                raise HTTPException(status_code=404, detail="Promo code not found or inactive")

        now = datetime.now(timezone.utc)
        err = _check_active(promo, now)
        if err:
            raise HTTPException(status_code=400, detail=err)

        try:
            disc_pct, disc_amt, _ = compute_discount(promo, order.items, now)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))

    settings_cfg = _get_settings(db)
    result = _calc(order.items, disc_pct, disc_amt, settings_cfg)
    grand_total = result["grand_total"]

    change_amount = None
    if data.payment_method == "cash":
        if data.cash_tendered is None:
            raise HTTPException(status_code=400, detail="cash_tendered is required for cash payments")
        cash = data.cash_tendered.quantize(TWO_PLACES, ROUND_HALF_UP)
        if cash < grand_total:
            raise HTTPException(
                status_code=400,
                detail=f"Cash tendered ({cash}) is less than grand total ({grand_total})",
            )
        change_amount = (cash - grand_total).quantize(TWO_PLACES, ROUND_HALF_UP)

    payment = models.Payment(
        order_id=order.id,
        promotion_id=promo.id if promo else None,
        payment_method=data.payment_method,
        subtotal=result["subtotal"],
        discount_percent=result["discount_percent"],
        discount_amount=result["discount_amount"],
        service_charge_rate=result["service_charge_rate"],
        service_charge_amount=result["service_charge_amount"],
        sst_rate=result["sst_rate"],
        sst_amount=result["sst_amount"],
        grand_total=grand_total,
        cash_tendered=data.cash_tendered,
        change_amount=change_amount,
        notes=data.notes,
        created_by=current_user.id,
    )
    db.add(payment)

    # Increment usage_count for promo_code type
    if promo and promo.type == "promo_code":
        promo.usage_count = (promo.usage_count or 0) + 1

    order.status = "paid"
    if order.table_id:
        table = db.query(models.Table).filter(models.Table.id == order.table_id).first()
        if table:
            table.status = "available"

    if settings_cfg.get("payment_to_cash_record") == "1":
        cash_record = models.CashRecord(
            type="cash_in",
            amount=grand_total,
            description=f"Payment - Order #{order.order_number}",
            category="Sales",
            created_by=current_user.id,
        )
        db.add(cash_record)
        db.flush()
        payment.cash_record_id = cash_record.id

    db.commit()
    db.refresh(payment)
    return payment


# ── List / Get Payments ───────────────────────────────────────────────────────

@router.get("/payments", response_model=list[schemas.PaymentResponse])
def list_payments(
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    return (
        db.query(models.Payment)
        .order_by(models.Payment.id.desc())
        .all()
    )


@router.get("/payments/{payment_id}", response_model=schemas.PaymentResponse)
def get_payment(
    payment_id: int,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    payment = db.query(models.Payment).filter(models.Payment.id == payment_id).first()
    if not payment:
        raise HTTPException(status_code=404, detail="Payment not found")
    return payment


@router.get("/payments/{payment_id}/detail", response_model=schemas.PaymentDetailResponse)
def get_payment_detail(
    payment_id: int,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    payment = db.query(models.Payment).filter(models.Payment.id == payment_id).first()
    if not payment:
        raise HTTPException(status_code=404, detail="Payment not found")
    order = payment.order
    return {
        "id": payment.id,
        "order_id": payment.order_id,
        "promotion_id": payment.promotion_id,
        "payment_method": payment.payment_method,
        "status": payment.status,
        "subtotal": payment.subtotal,
        "discount_percent": payment.discount_percent,
        "discount_amount": payment.discount_amount,
        "service_charge_rate": payment.service_charge_rate,
        "service_charge_amount": payment.service_charge_amount,
        "sst_rate": payment.sst_rate,
        "sst_amount": payment.sst_amount,
        "grand_total": payment.grand_total,
        "cash_tendered": payment.cash_tendered,
        "change_amount": payment.change_amount,
        "notes": payment.notes,
        "created_by": payment.created_by,
        "created_at": payment.created_at,
        "updated_at": payment.updated_at,
        "order_number": order.order_number if order else None,
        "table_name": order.table_name if order else None,
        "order_type": order.order_type if order else None,
        "items": order.items if order else [],
    }


# ── Audit helpers ─────────────────────────────────────────────────────────────

def _payment_snapshot(payment: models.Payment) -> dict:
    """把 payment + order + items 序列化成可存 JSON 的 dict。"""
    order = payment.order
    return {
        "payment": {
            "id": payment.id,
            "payment_method": payment.payment_method,
            "status": payment.status,
            "subtotal": str(payment.subtotal),
            "discount_percent": str(payment.discount_percent),
            "discount_amount": str(payment.discount_amount),
            "service_charge_rate": str(payment.service_charge_rate),
            "service_charge_amount": str(payment.service_charge_amount),
            "sst_rate": str(payment.sst_rate),
            "sst_amount": str(payment.sst_amount),
            "grand_total": str(payment.grand_total),
            "cash_tendered": str(payment.cash_tendered) if payment.cash_tendered else None,
            "change_amount": str(payment.change_amount) if payment.change_amount else None,
        },
        "order": {
            "id": order.id,
            "order_number": order.order_number,
            "order_type": order.order_type,
            "status": order.status,
            "notes": order.notes,
        },
        "order_items": [
            {
                "id": item.id,
                "product_id": item.product_id,
                "quantity": item.quantity,
                "unit_price": str(item.unit_price),
                "notes": item.notes,
            }
            for item in order.items
        ],
        "snapshotted_at": datetime.now(timezone.utc).isoformat(),
    }


def _require_completed_payment(payment_id: int, db: Session) -> models.Payment:
    payment = db.query(models.Payment).filter(models.Payment.id == payment_id).first()
    if not payment:
        raise HTTPException(status_code=404, detail="Payment not found")
    if payment.status != "completed":
        raise HTTPException(status_code=400, detail="Payment is not in completed status")
    return payment


# ── Void ──────────────────────────────────────────────────────────────────────

@router.post("/payments/{payment_id}/void", response_model=schemas.PaymentResponse)
def void_payment(
    payment_id: int,
    body: schemas.PaymentVoidRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission("can_manage_payment")),
):
    payment = _require_completed_payment(payment_id, db)

    # 记录快照
    log = models.PaymentAuditLog(
        payment_id=payment.id,
        action="void",
        reason=body.reason,
        snapshot_before=_payment_snapshot(payment),
        changed_by=current_user.id,
    )
    db.add(log)

    # 作废支付，订单同步作废（不重新打开，收银员需要的话手动建新单）
    payment.status = "voided"
    order = payment.order
    order.status = "cancelled"

    # 释放桌位
    if order.table_id:
        table = db.query(models.Table).filter(models.Table.id == order.table_id).first()
        if table:
            table.status = "available"

    # 撤销对应的 cash record（如果当初开了自动记账）
    if payment.cash_record_id:
        cash = db.query(models.CashRecord).filter(
            models.CashRecord.id == payment.cash_record_id
        ).first()
        if cash:
            db.delete(cash)
        payment.cash_record_id = None

    db.commit()
    db.refresh(payment)
    return payment


# ── Edit paid order ───────────────────────────────────────────────────────────

@router.put("/payments/{payment_id}", response_model=schemas.PaymentResponse)
def edit_paid_order(
    payment_id: int,
    data: schemas.PaymentEditRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission("can_manage_payment")),
):
    payment = _require_completed_payment(payment_id, db)
    order = payment.order

    if not data.items:
        raise HTTPException(status_code=400, detail="items cannot be empty")

    # 记录操作前快照
    log = models.PaymentAuditLog(
        payment_id=payment.id,
        action="edit",
        reason=data.reason,
        snapshot_before=_payment_snapshot(payment),
        changed_by=current_user.id,
    )
    db.add(log)

    # 替换 order_items
    for item in list(order.items):
        db.delete(item)
    db.flush()

    new_items = []
    for item_data in data.items:
        product = db.query(models.Product).filter(
            models.Product.id == item_data.product_id,
            models.Product.is_deleted == False,
        ).first()
        if not product:
            db.rollback()
            raise HTTPException(status_code=400, detail=f"Product {item_data.product_id} not found")
        if item_data.quantity <= 0:
            db.rollback()
            raise HTTPException(status_code=400, detail="quantity must be > 0")
        new_item = models.OrderItem(
            order_id=order.id,
            product_id=product.id,
            quantity=item_data.quantity,
            unit_price=product.price,
            weight_kg=item_data.weight_kg,
            notes=item_data.notes,
        )
        db.add(new_item)
        new_items.append(new_item)
    db.flush()

    # 重新计算金额
    result = _calc(new_items, data.discount_percent, data.discount_amount, _get_settings(db))

    payment.subtotal = result["subtotal"]
    payment.discount_percent = result["discount_percent"]
    payment.discount_amount = result["discount_amount"]
    payment.service_charge_rate = result["service_charge_rate"]
    payment.service_charge_amount = result["service_charge_amount"]
    payment.sst_rate = result["sst_rate"]
    payment.sst_amount = result["sst_amount"]
    payment.grand_total = result["grand_total"]
    # 现金找零按新金额重算（若原来是现金付款）
    if payment.cash_tendered is not None:
        new_change = payment.cash_tendered - result["grand_total"]
        payment.change_amount = max(new_change, Decimal("0")).quantize(TWO_PLACES, ROUND_HALF_UP)

    # 保持自动记的 cash record 金额同步
    if payment.cash_record_id:
        cash = db.query(models.CashRecord).filter(
            models.CashRecord.id == payment.cash_record_id
        ).first()
        if cash:
            cash.amount = result["grand_total"]

    db.commit()
    db.refresh(payment)
    return payment


# ── Audit log ─────────────────────────────────────────────────────────────────

@router.get("/payments/{payment_id}/audit-log", response_model=list[schemas.AuditLogResponse])
def get_audit_log(
    payment_id: int,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    payment = db.query(models.Payment).filter(models.Payment.id == payment_id).first()
    if not payment:
        raise HTTPException(status_code=404, detail="Payment not found")
    return (
        db.query(models.PaymentAuditLog)
        .filter(models.PaymentAuditLog.payment_id == payment_id)
        .order_by(models.PaymentAuditLog.id.asc())
        .all()
    )
