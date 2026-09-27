from functools import lru_cache

from sqlalchemy import create_engine, event
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session, sessionmaker, declarative_base
import os
from dotenv import load_dotenv

load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL must be configured")

engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_recycle=3600)

# Authentication and restaurant discovery always live in the control database.
# Every other mapped table is routed to the authenticated restaurant's own
# physical database after dependencies.get_current_user selects it.
CONTROL_TABLES = {
    "restaurants", "users", "email_verification_tokens", "login_logs",
    "restaurant_drive_connections",
}


@lru_cache(maxsize=512)
def get_tenant_engine(database_name: str):
    if not database_name or not database_name.replace("_", "").isalnum():
        raise ValueError("Invalid tenant database name")
    url = make_url(DATABASE_URL).set(database=database_name)
    tenant_engine = create_engine(url, pool_pre_ping=True, pool_recycle=3600)
    event.listen(tenant_engine, "connect", _set_malaysia_session_timezone)
    return tenant_engine


class RestaurantRoutingSession(Session):
    def get_bind(self, mapper=None, clause=None, bind=None, **kw):
        if bind is not None:
            return bind
        table_name = None
        if mapper is not None:
            table_name = mapper.local_table.name
        if table_name in CONTROL_TABLES:
            return engine
        tenant_engine = self.info.get("tenant_engine")
        return tenant_engine or engine


@event.listens_for(engine, "connect")
def _set_malaysia_session_timezone(dbapi_connection, _connection_record):
    """Keep database-generated DATETIME values on the store's timezone."""
    cursor = dbapi_connection.cursor()
    try:
        cursor.execute("SET time_zone = '+08:00'")
    finally:
        cursor.close()
SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
    class_=RestaurantRoutingSession,
)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def select_restaurant_database(db: Session, restaurant) -> None:
    if not restaurant.database_ready or not restaurant.database_name:
        raise RuntimeError("Restaurant database is not ready")
    selected = db.info.get("restaurant_id")
    if selected is not None and selected != restaurant.id:
        raise RuntimeError("A database session cannot switch between restaurants")
    db.info["restaurant_id"] = restaurant.id
    db.info["tenant_engine"] = get_tenant_engine(restaurant.database_name)
