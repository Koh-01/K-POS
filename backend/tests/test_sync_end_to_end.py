from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

import models
import schemas
from sync_router import sync_orders, sync_payments


def test_offline_order_and_payment_sync_are_end_to_end_idempotent():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    models.Base.metadata.create_all(engine)
    session = sessionmaker(bind=engine)()
    try:
        cashier = models.User(
            username="offline-cashier",
            password_hash="test-only",
            role="cashier",
            full_name="Offline Cashier",
            is_active=True,
        )
        product = models.Product(
            name="Cached Drink",
            price="10.00",
            status="active",
            sold_by_weight=False,
            is_deleted=False,
        )
        session.add_all([cashier, product])
        session.commit()

        order_request = schemas.SyncOrderCreate(
            offline_ref="device-order-e2e",
            order_type="take_away",
            paid_locally=True,
            items=[
                {
                    "product_id": product.id,
                    "quantity": 2,
                    "unit_price": "10.00",
                }
            ],
        )
        first_order = sync_orders([order_request], session, cashier)[0]
        repeated_order = sync_orders([order_request], session, cashier)[0]

        assert first_order.action == "created"
        assert repeated_order.action == "skipped"
        assert repeated_order.order_id == first_order.order_id

        payment_request = schemas.SyncPaymentCreate(
            offline_ref="device-payment-e2e",
            order_id=first_order.order_id,
            payment_method="cash",
            subtotal="20.00",
            grand_total="20.00",
            cash_tendered="50.00",
        )
        first_payment = sync_payments([payment_request], session, cashier)[0]
        repeated_payment = sync_payments([payment_request], session, cashier)[0]

        assert first_payment.action == "created"
        assert repeated_payment.action == "skipped"
        assert repeated_payment.payment_id == first_payment.payment_id
        assert session.query(models.Order).count() == 1
        assert session.query(models.Payment).count() == 1
        assert session.get(models.Order, first_order.order_id).status == "paid"
        assert session.get(models.Payment, first_payment.payment_id).change_amount == 30
    finally:
        session.close()
        models.Base.metadata.drop_all(engine)
        engine.dispose()
