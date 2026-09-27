from decimal import Decimal, ROUND_HALF_UP
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user, require_permission
import models
import schemas
from time_utils import as_local_naive, local_now

router = APIRouter(prefix="/promotions", tags=["Promotions"])

TWO = Decimal("0.01")
VALID_TYPES = {"discount_pct", "b1f1", "happy_hour", "promo_code"}


# ── Conditions validator ──────────────────────────────────────────────────────

def _validate_conditions(promo_type: str, conditions: dict):
    if promo_type == "discount_pct":
        if "percent" not in conditions:
            raise HTTPException(status_code=400, detail="discount_pct requires 'percent' in conditions")
        p = float(conditions["percent"])
        if not (0 < p <= 100):
            raise HTTPException(status_code=400, detail="percent must be between 0 and 100")

    elif promo_type == "b1f1":
        if "product_id" not in conditions:
            raise HTTPException(status_code=400, detail="b1f1 requires 'product_id' in conditions")

    elif promo_type == "happy_hour":
        for key in ("percent", "start_time", "end_time"):
            if key not in conditions:
                raise HTTPException(status_code=400, detail=f"happy_hour requires '{key}' in conditions")
        p = float(conditions["percent"])
        if not (0 < p <= 100):
            raise HTTPException(status_code=400, detail="percent must be between 0 and 100")
        for t in (conditions["start_time"], conditions["end_time"]):
            parts = str(t).split(":")
            if len(parts) != 2 or not all(x.isdigit() for x in parts):
                raise HTTPException(status_code=400, detail="start_time/end_time must be 'HH:MM'")

    elif promo_type == "promo_code":
        if "code" not in conditions or "percent" not in conditions:
            raise HTTPException(status_code=400, detail="promo_code requires 'code' and 'percent' in conditions")
        p = float(conditions["percent"])
        if not (0 < p <= 100):
            raise HTTPException(status_code=400, detail="percent must be between 0 and 100")
        if not str(conditions["code"]).strip():
            raise HTTPException(status_code=400, detail="promo code cannot be empty")


# ── Core discount computation (shared with payment_router) ────────────────────

def _check_active(promo: models.Promotion, now: datetime) -> str | None:
    """Returns error message if promotion cannot be applied, else None."""
    if not promo.is_active or promo.is_deleted:
        return "Promotion is not active"
    now = as_local_naive(now)
    if promo.starts_at and now < as_local_naive(promo.starts_at):
        return "Promotion has not started yet"
    if promo.ends_at and now > as_local_naive(promo.ends_at):
        return "Promotion has expired"
    return None


def compute_discount(
    promo: models.Promotion,
    items: list[models.OrderItem],
    now: datetime | None = None,
) -> tuple[Decimal, Decimal, str]:
    """
    Returns (discount_percent, discount_amount, message).
    discount_percent > 0 means _calc will use percent off subtotal.
    discount_amount > 0 (with percent=0) means fixed amount off.
    Raises ValueError if the promotion cannot be applied to these items.
    """
    if now is None:
        now = local_now()

    c = promo.conditions

    if promo.type == "discount_pct":
        percent = Decimal(str(c.get("percent", 0)))
        product_ids = [int(x) for x in c.get("product_ids", [])]
        if product_ids:
            targeted = sum(
                Decimal(str(i.subtotal))
                for i in items if i.product_id in product_ids
            )
            if targeted == 0:
                raise ValueError("No qualifying products in this order for the discount")
            discount_amount = (targeted * percent / 100).quantize(TWO, ROUND_HALF_UP)
            return Decimal("0"), discount_amount, f"{percent}% off selected products"
        else:
            return percent, Decimal("0"), f"{percent}% off entire order"

    elif promo.type == "b1f1":
        product_id = int(c.get("product_id", 0))
        for item in items:
            if item.product_id == product_id and item.quantity >= 2:
                free_qty = item.quantity // 2  # buy N get N//2 free (every pair: 1 free)
                discount_amount = (Decimal(str(item.unit_price)) * free_qty).quantize(TWO, ROUND_HALF_UP)
                return Decimal("0"), discount_amount, f"Buy {free_qty} Get {free_qty} Free"
        raise ValueError("Buy 1 Free 1 not applicable: need at least 2 of the qualifying product")

    elif promo.type == "happy_hour":
        # check time window (use local server time for happy hour)
        current_local = as_local_naive(now)
        days = [int(d) for d in c.get("days", list(range(7)))]
        if current_local.weekday() not in days:
            raise ValueError("Happy Hour: not available today")
        sh, sm = map(int, str(c["start_time"]).split(":"))
        eh, em = map(int, str(c["end_time"]).split(":"))
        cur = current_local.hour * 60 + current_local.minute
        if not (sh * 60 + sm <= cur <= eh * 60 + em):
            raise ValueError(f"Happy Hour: only valid between {c['start_time']} and {c['end_time']}")

        percent = Decimal(str(c.get("percent", 0)))
        product_ids = [int(x) for x in c.get("product_ids", [])]
        if product_ids:
            targeted = sum(
                Decimal(str(i.subtotal))
                for i in items if i.product_id in product_ids
            )
            if targeted == 0:
                raise ValueError("No qualifying products in this order for Happy Hour")
            discount_amount = (targeted * percent / 100).quantize(TWO, ROUND_HALF_UP)
            return Decimal("0"), discount_amount, f"Happy Hour: {percent}% off selected products"
        else:
            return percent, Decimal("0"), f"Happy Hour: {percent}% off"

    elif promo.type == "promo_code":
        usage_limit = int(c.get("usage_limit", 0))
        if usage_limit > 0 and promo.usage_count >= usage_limit:
            raise ValueError("Promo code has reached its usage limit")
        percent = Decimal(str(c.get("percent", 0)))
        min_order = Decimal(str(c.get("min_order", 0)))
        if min_order > 0:
            subtotal = sum(Decimal(str(i.subtotal)) for i in items)
            if subtotal < min_order:
                raise ValueError(f"Minimum order amount of {min_order} required")
        return percent, Decimal("0"), f"Promo code applied: {percent}% off"

    raise ValueError(f"Unknown promotion type: {promo.type}")


def find_by_code(code: str, db: Session) -> models.Promotion | None:
    """Find an active promo_code promotion matching the given code (case-insensitive)."""
    candidates = (
        db.query(models.Promotion)
        .filter(
            models.Promotion.type == "promo_code",
            models.Promotion.is_active == True,
            models.Promotion.is_deleted == False,
        )
        .all()
    )
    code_upper = code.strip().upper()
    return next(
        (p for p in candidates if p.conditions.get("code", "").upper() == code_upper),
        None,
    )


# ── CRUD ──────────────────────────────────────────────────────────────────────

@router.get("", response_model=list[schemas.PromotionResponse])
def list_promotions(
    type: str | None = None,
    is_active: bool | None = None,
    search: str | None = None,
    limit: int = Query(50, ge=1, le=200),
    page: int = Query(1, ge=1),
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    q = db.query(models.Promotion).filter(models.Promotion.is_deleted == False)
    if type:
        q = q.filter(models.Promotion.type == type)
    if is_active is not None:
        q = q.filter(models.Promotion.is_active == is_active)
    if search:
        q = q.filter(models.Promotion.name.contains(search))
    return q.order_by(models.Promotion.id.desc()).offset((page - 1) * limit).limit(limit).all()


@router.get("/{promotion_id}", response_model=schemas.PromotionResponse)
def get_promotion(
    promotion_id: int,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    promo = db.query(models.Promotion).filter(
        models.Promotion.id == promotion_id,
        models.Promotion.is_deleted == False,
    ).first()
    if not promo:
        raise HTTPException(status_code=404, detail="Promotion not found")
    return promo


@router.post("", response_model=schemas.PromotionResponse, status_code=201)
def create_promotion(
    data: schemas.PromotionCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission("can_manage_promotion")),
):
    if data.type not in VALID_TYPES:
        raise HTTPException(status_code=400, detail=f"type must be one of: {', '.join(VALID_TYPES)}")
    _validate_conditions(data.type, data.conditions)

    if data.starts_at and data.ends_at and data.starts_at >= data.ends_at:
        raise HTTPException(status_code=400, detail="starts_at must be before ends_at")

    promo = models.Promotion(
        name=data.name,
        type=data.type,
        conditions=data.conditions,
        starts_at=as_local_naive(data.starts_at) if data.starts_at else None,
        ends_at=as_local_naive(data.ends_at) if data.ends_at else None,
        is_active=data.is_active,
        created_by=current_user.id,
    )
    db.add(promo)
    db.commit()
    db.refresh(promo)
    return promo


@router.put("/{promotion_id}", response_model=schemas.PromotionResponse)
def update_promotion(
    promotion_id: int,
    data: schemas.PromotionUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_promotion")),
):
    promo = db.query(models.Promotion).filter(
        models.Promotion.id == promotion_id,
        models.Promotion.is_deleted == False,
    ).first()
    if not promo:
        raise HTTPException(status_code=404, detail="Promotion not found")

    if data.name is not None:
        promo.name = data.name
    if data.conditions is not None:
        _validate_conditions(promo.type, data.conditions)
        promo.conditions = data.conditions
    if data.starts_at is not None:
        promo.starts_at = as_local_naive(data.starts_at)
    if data.ends_at is not None:
        promo.ends_at = as_local_naive(data.ends_at)
    if data.is_active is not None:
        promo.is_active = data.is_active

    db.commit()
    db.refresh(promo)
    return promo


@router.delete("/{promotion_id}", status_code=204)
def delete_promotion(
    promotion_id: int,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_promotion")),
):
    promo = db.query(models.Promotion).filter(
        models.Promotion.id == promotion_id,
        models.Promotion.is_deleted == False,
    ).first()
    if not promo:
        raise HTTPException(status_code=404, detail="Promotion not found")
    promo.is_deleted = True
    db.commit()


# ── Apply preview (no payment created) ───────────────────────────────────────

@router.post("/apply", response_model=schemas.PromotionApplyResponse)
def apply_promotion_preview(
    body: schemas.PromotionApplyRequest,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    """Preview what discount a promotion would give on an order. Does not create a payment."""
    order = db.query(models.Order).filter(
        models.Order.id == body.order_id,
        models.Order.is_deleted == False,
        models.Order.status == "open",
    ).first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found or not open")
    if not order.items:
        raise HTTPException(status_code=400, detail="Order has no items")

    promo = _resolve_promotion(body, db)
    now = local_now()
    err = _check_active(promo, now)
    if err:
        raise HTTPException(status_code=400, detail=err)

    try:
        disc_pct, disc_amt, message = compute_discount(promo, order.items, now)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    return schemas.PromotionApplyResponse(
        promotion_id=promo.id,
        promotion_name=promo.name,
        discount_percent=disc_pct,
        discount_amount=disc_amt,
        message=message,
    )


def _resolve_promotion(body: schemas.PromotionApplyRequest, db: Session) -> models.Promotion:
    if body.promotion_id:
        promo = db.query(models.Promotion).filter(
            models.Promotion.id == body.promotion_id,
            models.Promotion.is_deleted == False,
        ).first()
        if not promo:
            raise HTTPException(status_code=404, detail="Promotion not found")
        return promo
    if body.promo_code:
        promo = find_by_code(body.promo_code, db)
        if not promo:
            raise HTTPException(status_code=404, detail="Promo code not found or inactive")
        return promo
    raise HTTPException(status_code=400, detail="Provide either promotion_id or promo_code")
