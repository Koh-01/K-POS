"""Provision and maintain one physical MariaDB database per restaurant."""

import os
import re
import logging

from fastapi import HTTPException
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session

import models
from database import DATABASE_URL, get_tenant_engine, select_restaurant_database


logger = logging.getLogger(__name__)
_VALID_DATABASE = re.compile(r"^[a-zA-Z0-9_]{1,64}$")
_COPY_ORDER = (
    models.Restaurant,
    models.User,
    models.Category,
    models.Product,
    models.Table,
    models.CashRecord,
    models.Promotion,
    models.Order,
    models.OrderItem,
    models.Payment,
    models.PaymentAuditLog,
    models.StoreSettings,
    models.Worker,
    models.SalaryPayment,
)


def database_name_for(restaurant: models.Restaurant) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", restaurant.slug.lower()).strip("_")[:36]
    return f"kpos_r_{restaurant.id}_{slug or 'restaurant'}"[:64]


def _admin_engine():
    admin_url = os.getenv("TENANT_DATABASE_ADMIN_URL", "").strip()
    if not admin_url:
        raise RuntimeError("TENANT_DATABASE_ADMIN_URL is not configured")
    return create_engine(admin_url, pool_pre_ping=True)


def _control_database_name() -> str:
    name = make_url(DATABASE_URL).database
    if not name or not _VALID_DATABASE.fullmatch(name):
        raise RuntimeError("Control DATABASE_URL must include a valid database name")
    return name


def _grant_app_access(conn, database_name: str) -> None:
    app_user = os.getenv("TENANT_DATABASE_APP_USER") or make_url(DATABASE_URL).username
    app_host = os.getenv("TENANT_DATABASE_APP_HOST", "%")
    safe_account = re.compile(r"^[a-zA-Z0-9_.:@%+-]+$")
    if not app_user or not safe_account.fullmatch(app_user) or not safe_account.fullmatch(app_host):
        raise RuntimeError("Invalid tenant database application account")
    conn.execute(text(
        f"GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES "
        f"ON `{database_name}`.* TO '{app_user}'@'{app_host}'"
    ))


def _copy_row_set(conn, database_name: str, model, restaurant_id: int) -> None:
    table = model.__table__
    columns = [column.name for column in table.columns]
    names = ", ".join(f"`{name}`" for name in columns)
    control_database = _control_database_name()
    if table.name == "restaurants":
        predicate = "id=:restaurant_id"
    else:
        predicate = "restaurant_id=:restaurant_id"
    conn.execute(text(
        f"INSERT IGNORE INTO `{database_name}`.`{table.name}` ({names}) "
        f"SELECT {names} FROM `{control_database}`.`{table.name}` WHERE {predicate}"
    ), {"restaurant_id": restaurant_id})


def provision_restaurant_database(db: Session, restaurant: models.Restaurant) -> None:
    """Create the tenant database and copy this restaurant's seed/current rows."""
    if not restaurant.database_name:
        restaurant.database_name = database_name_for(restaurant)
        db.commit()
        db.refresh(restaurant)
    database_name = restaurant.database_name
    if not _VALID_DATABASE.fullmatch(database_name):
        raise RuntimeError("Invalid restaurant database name")

    admin_engine = _admin_engine()
    try:
        with admin_engine.begin() as conn:
            conn.execute(text(
                f"CREATE DATABASE IF NOT EXISTS `{database_name}` "
                "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
            ))
            _grant_app_access(conn, database_name)

        tenant_engine = get_tenant_engine(database_name)
        models.Base.metadata.create_all(bind=tenant_engine)

        # The tenant database contains one restaurant reference and only that
        # restaurant's user shadows so its local foreign keys stay enforceable.
        with admin_engine.begin() as conn:
            for model in _COPY_ORDER:
                _copy_row_set(conn, database_name, model, restaurant.id)
    except Exception as exc:
        logger.exception("Unable to provision database for restaurant %s", restaurant.id)
        restaurant.database_ready = False
        db.commit()
        raise HTTPException(
            status_code=503,
            detail="Unable to prepare restaurant database. Please try again later.",
        ) from exc
    finally:
        admin_engine.dispose()

    restaurant.database_ready = True
    db.commit()
    db.refresh(restaurant)


def sync_user_shadow(db: Session, user: models.User) -> None:
    """Mirror a control-plane account into its restaurant DB for local FKs."""
    restaurant = db.query(models.Restaurant).filter(models.Restaurant.id == user.restaurant_id).first()
    if not restaurant or not restaurant.database_ready:
        return
    database_name = restaurant.database_name
    control_database = _control_database_name()
    columns = [column.name for column in models.User.__table__.columns]
    names = ", ".join(f"`{name}`" for name in columns)
    updates = ", ".join(
        f"`{name}`=VALUES(`{name}`)" for name in columns if name != "id"
    )
    admin_engine = _admin_engine()
    try:
        with admin_engine.begin() as conn:
            conn.execute(text(
                f"INSERT INTO `{database_name}`.`users` ({names}) "
                f"SELECT {names} FROM `{control_database}`.`users` WHERE id=:user_id "
                f"ON DUPLICATE KEY UPDATE {updates}"
            ), {"user_id": user.id})
    finally:
        admin_engine.dispose()


def select_for_user(db: Session, user: models.User) -> None:
    restaurant = user.restaurant
    if not restaurant or not restaurant.is_active:
        raise HTTPException(status_code=403, detail="Restaurant account is inactive")
    if not restaurant.database_ready:
        try:
            provision_restaurant_database(db, restaurant)
        except HTTPException:
            raise HTTPException(status_code=503, detail="Restaurant database is not ready")
    select_restaurant_database(db, restaurant)
