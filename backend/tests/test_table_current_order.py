from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from database import Base
import models
import schemas
from order_router import attach_current_orders


def test_occupied_table_reports_its_open_order():
    db = sessionmaker(bind=create_engine("sqlite:///:memory:"))()
    Base.metadata.create_all(db.get_bind())
    db.add(models.Restaurant(id=1, name="R", slug="r", is_active=True))
    user = models.User(username="cashier", password_hash="x", role="cashier")
    busy = models.Table(name="T1", status="occupied")
    free = models.Table(name="T2", status="available")
    db.add_all([user, busy, free])
    db.flush()
    db.add_all([
        models.Order(order_number="PAID-1", table_id=busy.id, status="paid", created_by=user.id),
        models.Order(order_number="OPEN-1", table_id=busy.id, status="open", created_by=user.id),
    ])
    db.commit()
    open_id = db.query(models.Order).filter_by(order_number="OPEN-1").one().id

    rows = [schemas.TableResponse.model_validate(t) for t in attach_current_orders(db, [busy, free])]

    assert rows[0].current_order_id == open_id
    assert rows[1].current_order_id is None
