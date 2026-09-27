from datetime import datetime
from decimal import Decimal

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from database import Base
import models
from payment_cash_records import sync_payment_cash_records


def _session():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)()


def _payment(db, *, status="completed", created_at=None):
    user = models.User(
        username=f"cashier-{db.query(models.User).count()}",
        password_hash="test",
        role="cashier",
        is_active=True,
    )
    db.add(user)
    db.flush()
    order = models.Order(
        order_number=f"ORD-{db.query(models.Order).count() + 1}",
        order_type="take_away",
        status="paid",
        created_by=user.id,
    )
    db.add(order)
    db.flush()
    payment = models.Payment(
        order_id=order.id,
        payment_method="cash",
        status=status,
        subtotal=Decimal("12.00"),
        discount_percent=Decimal("0"),
        discount_amount=Decimal("0"),
        service_charge_rate=Decimal("0"),
        service_charge_amount=Decimal("0"),
        sst_rate=Decimal("0"),
        sst_amount=Decimal("0"),
        grand_total=Decimal("12.00"),
        cash_tendered=Decimal("20.00"),
        change_amount=Decimal("8.00"),
        created_by=user.id,
        created_at=created_at or datetime(2026, 1, 2, 9, 30),
    )
    db.add(payment)
    db.commit()
    return payment


def test_enable_backfills_at_payment_time_and_is_idempotent():
    db = _session()
    payment_time = datetime(2025, 12, 25, 18, 45)
    payment = _payment(db, created_at=payment_time)
    _payment(db, status="voided")

    created, removed = sync_payment_cash_records(db, enabled=True)
    db.commit()

    assert (created, removed) == (1, 0)
    db.refresh(payment)
    cash_record = db.get(models.CashRecord, payment.cash_record_id)
    assert cash_record is not None
    assert cash_record.amount == Decimal("12.00")
    assert cash_record.created_at == payment_time
    assert cash_record.created_by == payment.created_by
    assert cash_record.category == "Sales"

    assert sync_payment_cash_records(db, enabled=True) == (0, 0)
    assert db.query(models.CashRecord).count() == 1
    db.close()


def test_disable_removes_only_payment_generated_records():
    db = _session()
    payment = _payment(db)
    sync_payment_cash_records(db, enabled=True)
    manual = models.CashRecord(
        type="cash_in",
        amount=Decimal("5.00"),
        description="Manual float",
        category="Other",
        created_by=payment.created_by,
    )
    db.add(manual)
    db.commit()
    generated_id = payment.cash_record_id
    manual_id = manual.id

    created, removed = sync_payment_cash_records(db, enabled=False)
    db.commit()

    assert (created, removed) == (0, 1)
    db.refresh(payment)
    assert payment.cash_record_id is None
    assert db.get(models.CashRecord, generated_id) is None
    assert db.get(models.CashRecord, manual_id) is not None
    db.close()
