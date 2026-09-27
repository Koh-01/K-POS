from sqlalchemy import create_engine, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker

from database import Base
import models
import schemas
from registration_service import register_admin, verify_email_token


def _session():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)()


def _restaurant(db, name, slug):
    row = models.Restaurant(name=name, slug=slug, is_active=True)
    db.add(row)
    db.flush()
    return row


def test_tenant_session_isolates_reads_writes_and_bulk_deletes():
    db = _session()
    first = _restaurant(db, "First", "first")
    second = _restaurant(db, "Second", "second")
    db.add_all([
        models.Product(restaurant_id=first.id, name="First product", price=1),
        models.Product(restaurant_id=second.id, name="Second product", price=2),
    ])
    db.commit()

    db.info["restaurant_id"] = first.id
    assert [row.name for row in db.query(models.Product).all()] == ["First product"]
    assert db.query(func.sum(models.Product.price)).scalar() == 1

    db.add(models.Product(name="Automatically owned", price=3))
    db.commit()
    owned = db.query(models.Product).filter(models.Product.name == "Automatically owned").one()
    assert owned.restaurant_id == first.id

    assert db.query(models.Product).delete(synchronize_session=False) == 2
    db.commit()
    db.info.pop("restaurant_id")
    assert [row.name for row in db.query(models.Product).all()] == ["Second product"]


def test_registration_requires_one_time_email_verification(monkeypatch):
    db = _session()
    def _provision(_db, restaurant):
        restaurant.database_name = f"test_{restaurant.id}"
        restaurant.database_ready = True
        _db.commit()
    monkeypatch.setattr("registration_service.provision_restaurant_database", _provision)
    monkeypatch.setattr("registration_service.sync_user_shadow", lambda _db, _user: None)
    user, token = register_admin(db, schemas.AdminRegistrationRequest(
        restaurant_name="New Restaurant",
        full_name="Owner Name",
        email="Owner@Example.com",
        password="strong-pass-123",
    ))
    assert user.email == "owner@example.com"
    assert user.username == "owner@example.com"
    assert user.role == "admin"
    assert user.is_active is False
    assert user.email_verified is False
    assert user.restaurant.is_active is False

    verified = verify_email_token(db, token)
    assert verified.is_active is True
    assert verified.email_verified is True
    assert verified.restaurant.is_active is True


def test_cashier_username_is_unique_across_restaurants():
    db = _session()
    first = _restaurant(db, "First", "first")
    second = _restaurant(db, "Second", "second")
    db.add(models.User(
        restaurant_id=first.id,
        username="cashier01",
        password_hash="x",
        role="cashier",
    ))
    db.commit()
    db.add(models.User(
        restaurant_id=second.id,
        username="cashier01",
        password_hash="x",
        role="cashier",
    ))
    try:
        db.commit()
        assert False, "duplicate cashier username was accepted"
    except IntegrityError:
        db.rollback()


def test_category_names_are_unique_only_inside_each_restaurant():
    db = _session()
    first = _restaurant(db, "First", "first")
    second = _restaurant(db, "Second", "second")
    db.add_all([
        models.Category(restaurant_id=first.id, name="Drinks"),
        models.Category(restaurant_id=second.id, name="Drinks"),
    ])
    db.commit()
    assert db.query(models.Category).count() == 2
