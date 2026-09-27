"""Keep payment-generated cash records aligned with the store setting."""

from sqlalchemy.orm import Session

import models


def sync_payment_cash_records(db: Session, *, enabled: bool) -> tuple[int, int]:
    """Backfill or remove cash records created from completed payments.

    Returns ``(created_count, removed_count)``. Only records referenced by a
    payment's ``cash_record_id`` are removed, so manually entered cash records
    are never touched.
    """

    if enabled:
        payments = (
            db.query(models.Payment)
            .filter(models.Payment.status == "completed")
            .order_by(models.Payment.id.asc())
            .with_for_update()
            .all()
        )
        linked_ids = {
            payment.cash_record_id
            for payment in payments
            if payment.cash_record_id is not None
        }
        existing_ids = set()
        if linked_ids:
            existing_ids = {
                record_id
                for (record_id,) in db.query(models.CashRecord.id)
                .filter(models.CashRecord.id.in_(linked_ids))
                .all()
            }

        created = 0
        for payment in payments:
            if payment.cash_record_id in existing_ids:
                continue

            # Repair stale links as well as backfilling payments made before
            # the setting was enabled.
            payment.cash_record_id = None
            order_number = (
                payment.order.order_number if payment.order else payment.order_id
            )
            cash_record = models.CashRecord(
                type="cash_in",
                amount=payment.grand_total,
                description=f"Payment - Order #{order_number}",
                category="Sales",
                created_by=payment.created_by,
                created_at=payment.created_at,
            )
            db.add(cash_record)
            db.flush()
            payment.cash_record_id = cash_record.id
            existing_ids.add(cash_record.id)
            created += 1

        return created, 0

    payments = (
        db.query(models.Payment)
        .filter(models.Payment.cash_record_id.isnot(None))
        .order_by(models.Payment.id.asc())
        .with_for_update()
        .all()
    )
    linked_ids = {
        payment.cash_record_id
        for payment in payments
        if payment.cash_record_id is not None
    }
    for payment in payments:
        payment.cash_record_id = None
    db.flush()

    records = []
    if linked_ids:
        records = (
            db.query(models.CashRecord)
            .filter(models.CashRecord.id.in_(linked_ids))
            .all()
        )
        for record in records:
            db.delete(record)

    return 0, len(records)
