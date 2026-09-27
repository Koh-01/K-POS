from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from database import Base
import models
from user_router import delete_user, list_users


def _session():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)()


def test_user_with_history_is_safely_deleted_without_removing_records():
    db = _session()
    admin = models.User(
        username="admin",
        password_hash="test",
        role="admin",
        full_name="Admin",
        is_active=True,
    )
    cashier = models.User(
        username="cashier",
        password_hash="test",
        role="cashier",
        full_name="Original Cashier",
        is_active=True,
    )
    db.add_all([admin, cashier])
    db.flush()
    order = models.Order(
        order_number="ORD-1",
        order_type="take_away",
        status="paid",
        created_by=cashier.id,
    )
    db.add(order)
    db.commit()

    old_username = cashier.username
    delete_user(cashier.id, db=db, current_admin=admin)

    db.refresh(cashier)
    db.refresh(order)
    assert cashier.is_deleted is True
    assert cashier.is_active is False
    assert cashier.username != old_username
    assert cashier.full_name == "Original Cashier"
    assert order.created_by == cashier.id
    assert cashier not in list_users(db=db, _=admin)
    db.close()
