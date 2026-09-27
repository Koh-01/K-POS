from decimal import Decimal
from datetime import datetime
from types import SimpleNamespace
import unittest

from fastapi import HTTPException

from order_router import _validated_weight
from payment_router import _calc
from promotion_router import compute_discount
from sync_router import _public_sync_error


class PaymentMathTests(unittest.TestCase):
    def test_weighted_item_tax_and_service_charge_rounding(self):
        items = [SimpleNamespace(subtotal=Decimal("12.345"))]
        result = _calc(items, Decimal("0"), Decimal("0"), {
            "service_charge_enabled": "1",
            "service_charge_rate": "0.10",
            "sst_enabled": "1",
            "sst_rate": "0.06",
        })
        self.assertEqual(result["subtotal"], Decimal("12.35"))
        self.assertEqual(result["service_charge_amount"], Decimal("1.24"))
        self.assertEqual(result["sst_amount"], Decimal("0.82"))
        self.assertEqual(result["grand_total"], Decimal("14.41"))

    def test_fixed_discount_cannot_exceed_subtotal(self):
        items = [SimpleNamespace(subtotal=Decimal("8.00"))]
        result = _calc(items, Decimal("0"), Decimal("50"), {})
        self.assertEqual(result["discount_amount"], Decimal("8.00"))
        self.assertEqual(result["grand_total"], Decimal("0.00"))

    def test_targeted_discount_keeps_exact_fixed_amount(self):
        promo = SimpleNamespace(
            type="discount_pct",
            conditions={"percent": 10, "product_ids": [1]},
        )
        items = [
            SimpleNamespace(
                product_id=1,
                subtotal=Decimal("9.99"),
                unit_price=Decimal("9.99"),
                quantity=1,
            ),
            SimpleNamespace(
                product_id=2,
                subtotal=Decimal("20.00"),
                unit_price=Decimal("20.00"),
                quantity=1,
            ),
        ]
        percent, amount, _ = compute_discount(promo, items)
        self.assertEqual(percent, Decimal("0"))
        self.assertEqual(amount, Decimal("1.00"))

    def test_happy_hour_uses_checkout_timestamp(self):
        promo = SimpleNamespace(
            type="happy_hour",
            conditions={
                "percent": 10,
                "days": [0],
                "start_time": "11:00",
                "end_time": "13:00",
            },
        )
        item = SimpleNamespace(
            product_id=1,
            subtotal=Decimal("10.00"),
            unit_price=Decimal("10.00"),
            quantity=1,
        )
        percent, _, _ = compute_discount(
            promo,
            [item],
            datetime(2026, 1, 5, 12, 0),
        )
        self.assertEqual(percent, Decimal("10"))

    def test_weight_mode_must_match_catalogue(self):
        weighted = SimpleNamespace(id=1, sold_by_weight=True)
        quantity = SimpleNamespace(id=2, sold_by_weight=False)
        self.assertEqual(_validated_weight(weighted, 1.25), 1.25)
        with self.assertRaises(HTTPException):
            _validated_weight(weighted, None)
        with self.assertRaises(HTTPException):
            _validated_weight(quantity, 1.25)

    def test_unexpected_sync_error_is_not_exposed(self):
        message = _public_sync_error(RuntimeError("database password leaked"))
        self.assertNotIn("password", message)


if __name__ == "__main__":
    unittest.main()
