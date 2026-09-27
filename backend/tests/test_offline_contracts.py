from decimal import Decimal
from types import SimpleNamespace
import unittest

import schemas
from sync_router import _validate_payment_snapshot


class OfflineContractTests(unittest.TestCase):
    def test_online_order_accepts_idempotency_reference(self):
        order = schemas.OrderCreate(
            offline_ref="device-order-1",
            order_type="take_away",
            items=[{"product_id": 7, "quantity": 1}],
        )
        self.assertEqual(order.offline_ref, "device-order-1")

    def test_legacy_takeaway_value_is_normalised(self):
        order = schemas.SyncOrderCreate(
            offline_ref="order-1",
            order_type="takeaway",
            table_name="Pickup A",
            items=[{
                "product_id": 7,
                "quantity": 1,
                "unit_price": "12.50",
                "weight_kg": None,
            }],
        )
        self.assertEqual(order.order_type, "take_away")
        self.assertEqual(order.table_name, "Pickup A")
        self.assertEqual(order.items[0].unit_price, Decimal("12.50"))

    def test_valid_offline_payment_snapshot(self):
        order = SimpleNamespace(items=[
            SimpleNamespace(subtotal=Decimal("20.00")),
            SimpleNamespace(subtotal=Decimal("5.50")),
        ])
        payment = schemas.SyncPaymentCreate(
            offline_ref="payment-1",
            order_id=1,
            payment_method="cash",
            subtotal="25.50",
            discount_amount="0.50",
            service_charge_rate="0.10",
            service_charge_amount="2.50",
            sst_rate="0.06",
            sst_amount="1.65",
            grand_total="29.15",
            cash_tendered="30.00",
        )
        _validate_payment_snapshot(payment, order)

    def test_tampered_offline_total_is_rejected(self):
        order = SimpleNamespace(
            items=[SimpleNamespace(subtotal=Decimal("10.00"))]
        )
        payment = schemas.SyncPaymentCreate(
            offline_ref="payment-2",
            order_id=1,
            payment_method="cash",
            subtotal="10.00",
            grand_total="9.00",
            cash_tendered="10.00",
        )
        with self.assertRaisesRegex(ValueError, "Grand total snapshot mismatch"):
            _validate_payment_snapshot(payment, order)


if __name__ == "__main__":
    unittest.main()
