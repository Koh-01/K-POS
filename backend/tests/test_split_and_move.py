from decimal import Decimal

import pytest
from fastapi import HTTPException
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from database import Base
import models
import schemas
from order_router import change_table, delete_order, split_order


@pytest.fixture()
def db():
    session = sessionmaker(bind=create_engine("sqlite:///:memory:"))()
    Base.metadata.create_all(session.get_bind())
    session.add(models.Restaurant(id=1, name="R", slug="r", is_active=True))
    session.commit()
    return session


def _seed(db):
    user = models.User(username="cashier", password_hash="x", role="cashier")
    t1 = models.Table(name="T1", status="occupied")
    t2 = models.Table(name="T2", status="available")
    rice = models.Product(name="Rice", price=Decimal("2.00"))
    tea = models.Product(name="Tea", price=Decimal("3.50"))
    db.add_all([user, t1, t2, rice, tea])
    db.flush()
    order = models.Order(order_number="ORD-1", table_id=t1.id, order_type="dine_in",
                         status="open", created_by=user.id)
    db.add(order)
    db.flush()
    rice_line = models.OrderItem(order_id=order.id, product_id=rice.id, quantity=3, unit_price=Decimal("2.00"))
    tea_line = models.OrderItem(order_id=order.id, product_id=tea.id, quantity=1, unit_price=Decimal("3.50"))
    db.add_all([rice_line, tea_line])
    db.commit()
    return user, t1, t2, order, rice_line, tea_line


def _split(db, user, order, *moves):
    request = schemas.OrderSplitRequest(items=[
        schemas.OrderSplitItem(item_id=item_id, quantity=qty) for item_id, qty in moves
    ])
    return split_order(order.id, request, db, user)


def test_split_moves_partial_quantity_and_whole_lines(db):
    user, t1, _t2, order, rice, tea = _seed(db)

    result = _split(db, user, order, (rice.id, 1), (tea.id, None))

    source, new = result["source"], result["new_order"]
    assert new.table_id == t1.id and new.status == "open"
    assert {(i.product.name, i.quantity) for i in source.items} == {("Rice", 2)}
    assert {(i.product.name, i.quantity) for i in new.items} == {("Rice", 1), ("Tea", 1)}
    assert all(i.unit_price == Decimal("2.00") for i in new.items if i.product.name == "Rice")


def test_split_must_leave_something_on_the_original_bill(db):
    user, _t1, _t2, order, rice, tea = _seed(db)
    with pytest.raises(HTTPException) as err:
        _split(db, user, order, (rice.id, None), (tea.id, None))
    assert err.value.status_code == 400


def test_split_rejects_more_than_ordered(db):
    user, _t1, _t2, order, rice, _tea = _seed(db)
    with pytest.raises(HTTPException):
        _split(db, user, order, (rice.id, 4))


def test_table_stays_occupied_while_a_split_bill_is_open(db):
    user, t1, _t2, order, rice, _tea = _seed(db)
    new = _split(db, user, order, (rice.id, 1))["new_order"]

    delete_order(new.id, db)
    db.refresh(t1)
    assert t1.status == "occupied"      # original bill still seated

    delete_order(order.id, db)
    db.refresh(t1)
    assert t1.status == "available"


def test_move_table_frees_old_table_and_clears_custom_label(db):
    _user, t1, t2, order, _rice, _tea = _seed(db)
    order.table_name = "Patio"
    db.commit()

    moved = change_table(order.id, {"table_id": t2.id}, db)

    db.refresh(t1)
    db.refresh(t2)
    assert moved.table_id == t2.id and moved.table_name is None
    assert t1.status == "available" and t2.status == "occupied"


def test_move_table_refuses_an_occupied_table(db):
    user, t1, t2, order, _rice, _tea = _seed(db)
    t2.status = "occupied"
    db.commit()
    with pytest.raises(HTTPException) as err:
        change_table(order.id, {"table_id": t2.id}, db)
    assert err.value.status_code == 400
