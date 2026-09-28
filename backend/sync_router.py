from decimal import Decimal, ROUND_HALF_UP
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user
import models
import schemas
from order_router import _generate_order_number, _validated_weight, attach_current_orders
from payment_router import _calc, _release_table_if_unused
from promotion_router import _check_active, compute_discount
from settings_router import _get_settings
from time_utils import as_local_naive, local_now

router = APIRouter(prefix="/sync", tags=["Sync"])
TWO = Decimal("0.01")


def _public_sync_error(exc: Exception) -> str:
    if isinstance(exc, HTTPException):
        return str(exc.detail)
    if isinstance(exc, ValueError):
        return str(exc)
    if isinstance(exc, IntegrityError):
        return "A matching record already exists; retrying will reconcile it"
    return "Unexpected server error while syncing; retry later"


@router.get("/catalog")
def get_catalog(db: Session = Depends(get_db), _=Depends(get_current_user)):
    """Full product/category/table snapshot for offline caching."""
    categories = (
        db.query(models.Category)
        .filter(models.Category.is_active == True)
        .order_by(models.Category.sort_order, models.Category.id)
        .all()
    )
    products = (
        db.query(models.Product)
        .filter(models.Product.is_deleted == False, models.Product.status == "active")
        .order_by(models.Product.sort_order, models.Product.id)
        .all()
    )
    tables = (
        db.query(models.Table)
        .filter(models.Table.is_active == True)
        .order_by(models.Table.sort_order, models.Table.id)
        .all()
    )
    return {
        "synced_at": local_now().isoformat(),
        "categories": [schemas.CategoryResponse.model_validate(c) for c in categories],
        "products": [schemas.ProductResponse.model_validate(p) for p in products],
        "tables": [schemas.TableResponse.model_validate(t) for t in attach_current_orders(db, tables)],
    }


@router.post("/orders", response_model=list[schemas.SyncOrderResult])
def sync_orders(
    orders: list[schemas.SyncOrderCreate],
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """
    Batch-create orders from offline device.
    Each item must have a unique offline_ref (device UUID).
    Already-synced refs are skipped (idempotent).
    """
    results: list[schemas.SyncOrderResult] = []

    for item in orders:
        # Idempotency: if already synced, return existing
        existing = (
            db.query(models.Order)
            .filter(models.Order.offline_ref == item.offline_ref)
            .first()
        )
        if existing:
            results.append(schemas.SyncOrderResult(
                offline_ref=item.offline_ref,
                order_id=existing.id,
                order_number=existing.order_number,
                action="skipped",
            ))
            continue

        try:
            if not item.items:
                raise ValueError("Order has no items")

            table = None
            if item.table_id:
                table = db.query(models.Table).filter(
                    models.Table.id == item.table_id,
                    models.Table.is_active == True,
                ).with_for_update().first()
                if not table:
                    raise ValueError("Table not found or inactive")
                if table.status == "occupied" and not item.paid_locally:
                    raise ValueError("Table is already occupied")

            order = models.Order(
                order_number=_generate_order_number(db),
                table_id=item.table_id,
                table_name=item.table_name,
                order_type=item.order_type,
                notes=item.notes,
                created_by=current_user.id,
                offline_ref=item.offline_ref,
                status="open",
                created_at=as_local_naive(item.device_created_at),
            )
            db.add(order)
            db.flush()

            for item_data in item.items:
                product = db.query(models.Product).filter(
                    models.Product.id == item_data.product_id,
                ).first()
                if not product:
                    raise ValueError(f"Product {item_data.product_id} not found")
                if item_data.quantity <= 0:
                    raise ValueError("quantity must be > 0")
                db.add(models.OrderItem(
                    order_id=order.id,
                    product_id=product.id,
                    quantity=item_data.quantity,
                    unit_price=item_data.unit_price,
                    weight_kg=_validated_weight(product, item_data.weight_kg),
                    notes=item_data.notes,
                ))

            if table and not item.paid_locally:
                table.status = "occupied"

            db.commit()
            db.refresh(order)

            results.append(schemas.SyncOrderResult(
                offline_ref=item.offline_ref,
                order_id=order.id,
                order_number=order.order_number,
                action="created",
            ))

        except Exception as e:
            db.rollback()
            results.append(schemas.SyncOrderResult(
                offline_ref=item.offline_ref,
                order_id=None,
                order_number=None,
                action="error",
                error=_public_sync_error(e),
            ))

    return results


def _q(value: Decimal) -> Decimal:
    return value.quantize(TWO, ROUND_HALF_UP)


def _validate_payment_snapshot(
    data: schemas.SyncPaymentCreate, order: models.Order
) -> None:
    values = (
        data.subtotal,
        data.discount_percent,
        data.discount_amount,
        data.service_charge_rate,
        data.service_charge_amount,
        data.sst_rate,
        data.sst_amount,
        data.grand_total,
    )
    if any(value < 0 for value in values):
        raise ValueError("Payment amounts and rates cannot be negative")
    if data.discount_percent > 100:
        raise ValueError("Discount percent cannot exceed 100")
    if data.service_charge_rate > 1 or data.sst_rate > 1:
        raise ValueError("Charge and tax rates cannot exceed 1")

    expected_subtotal = _q(sum(
        (Decimal(str(line.subtotal)) for line in order.items),
        Decimal("0"),
    ))
    if _q(data.subtotal) != expected_subtotal:
        raise ValueError(
            f"Subtotal snapshot mismatch: expected {expected_subtotal}, got {_q(data.subtotal)}"
        )
    if data.discount_amount > data.subtotal:
        raise ValueError("Discount cannot exceed subtotal")
    after_discount = data.subtotal - data.discount_amount
    expected_service = _q(after_discount * data.service_charge_rate)
    if _q(data.service_charge_amount) != expected_service:
        raise ValueError(
            f"Service charge snapshot mismatch: expected {expected_service}"
        )
    expected_sst = _q(
        (after_discount + data.service_charge_amount) * data.sst_rate
    )
    if _q(data.sst_amount) != expected_sst:
        raise ValueError(f"SST snapshot mismatch: expected {expected_sst}")
    expected_total = _q(
        data.subtotal
        - data.discount_amount
        + data.service_charge_amount
        + data.sst_amount
    )
    if _q(data.grand_total) != expected_total:
        raise ValueError(
            f"Grand total snapshot mismatch: expected {expected_total}, got {_q(data.grand_total)}"
        )
    if data.payment_method not in ("cash", "duitnow", "card"):
        raise ValueError("Unsupported payment method")
    if data.payment_method == "cash":
        if data.cash_tendered is None:
            raise ValueError("cash_tendered is required for cash payments")
        if _q(data.cash_tendered) < expected_total:
            raise ValueError("Cash tendered is less than grand total")


@router.post("/payments", response_model=list[schemas.SyncPaymentResult])
def sync_payments(
    payments: list[schemas.SyncPaymentCreate],
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Idempotently persist checkouts completed while the device was offline."""
    results: list[schemas.SyncPaymentResult] = []
    for item in payments:
        existing = db.query(models.Payment).filter(
            models.Payment.offline_ref == item.offline_ref
        ).first()
        if existing:
            results.append(schemas.SyncPaymentResult(
                offline_ref=item.offline_ref,
                payment_id=existing.id,
                action="skipped",
            ))
            continue

        try:
            order = db.query(models.Order).filter(
                models.Order.id == item.order_id,
                models.Order.is_deleted == False,
            ).with_for_update().first()
            if not order:
                raise ValueError("Order not found")
            if order.status != "open":
                raise ValueError(f"Order is already {order.status}")

            _validate_payment_snapshot(item, order)
            promo = None
            discount_percent = item.discount_percent
            if item.promotion_id is not None:
                promo = db.query(models.Promotion).filter(
                    models.Promotion.id == item.promotion_id,
                ).with_for_update().first()
                if not promo:
                    raise ValueError("Promotion not found")
                checkout_time = as_local_naive(item.device_created_at)
                active_error = _check_active(promo, checkout_time)
                if active_error:
                    raise ValueError(active_error)
                promo_pct, promo_amount, _ = compute_discount(
                    promo, order.items, checkout_time
                )
                expected_discount = _calc(
                    order.items,
                    promo_pct,
                    promo_amount,
                    {},
                )["discount_amount"]
                if _q(expected_discount) != _q(item.discount_amount):
                    raise ValueError(
                        f"Promotion discount mismatch: expected {_q(expected_discount)}"
                    )
                discount_percent = promo_pct
            elif (
                _q(item.discount_amount) != Decimal("0")
                or _q(item.discount_percent) != Decimal("0")
            ):
                raise ValueError("Offline discount requires a valid promotion")

            change = None
            if item.payment_method == "cash":
                change = _q(item.cash_tendered - item.grand_total)

            payment = models.Payment(
                order_id=order.id,
                offline_ref=item.offline_ref,
                promotion_id=promo.id if promo else None,
                payment_method=item.payment_method,
                subtotal=_q(item.subtotal),
                discount_percent=_q(discount_percent),
                discount_amount=_q(item.discount_amount),
                service_charge_rate=item.service_charge_rate,
                service_charge_amount=_q(item.service_charge_amount),
                sst_rate=item.sst_rate,
                sst_amount=_q(item.sst_amount),
                grand_total=_q(item.grand_total),
                cash_tendered=_q(item.cash_tendered) if item.cash_tendered is not None else None,
                change_amount=change,
                notes="Synced from offline checkout",
                created_by=current_user.id,
                created_at=as_local_naive(item.device_created_at),
            )
            db.add(payment)
            if promo and promo.type == "promo_code":
                promo.usage_count = (promo.usage_count or 0) + 1
            order.status = "paid"
            _release_table_if_unused(db, order)

            settings = _get_settings(db)
            if settings.get("payment_to_cash_record") == "1":
                cash = models.CashRecord(
                    type="cash_in",
                    amount=payment.grand_total,
                    description=f"Payment - Order #{order.order_number}",
                    category="Sales",
                    created_by=current_user.id,
                    created_at=payment.created_at,
                )
                db.add(cash)
                db.flush()
                payment.cash_record_id = cash.id

            db.commit()
            db.refresh(payment)
            results.append(schemas.SyncPaymentResult(
                offline_ref=item.offline_ref,
                payment_id=payment.id,
                action="created",
            ))
        except Exception as exc:
            db.rollback()
            results.append(schemas.SyncPaymentResult(
                offline_ref=item.offline_ref,
                action="error",
                error=_public_sync_error(exc),
            ))
    return results
