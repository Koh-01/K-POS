from decimal import Decimal as D
from sqlalchemy import (
    Column, Integer, String, Boolean, DateTime, Numeric, ForeignKey, Text, JSON,
    UniqueConstraint, event,
)
from sqlalchemy.orm import Session, declared_attr, relationship, with_loader_criteria
from sqlalchemy.sql import func
from database import Base


class TenantMixin:
    """Marks a row as belonging to exactly one restaurant."""

    @declared_attr
    def restaurant_id(cls):
        # The default keeps old scripts/tests compatible. Request sessions
        # always overwrite it with the authenticated user's restaurant.
        return Column(
            Integer,
            ForeignKey("restaurants.id"),
            nullable=False,
            index=True,
            default=1,
            server_default="1",
        )


class Restaurant(Base):
    __tablename__ = "restaurants"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(150), nullable=False)
    slug = Column(String(180), unique=True, nullable=False, index=True)
    database_name = Column(String(64), unique=True, nullable=True)
    database_ready = Column(Boolean, default=False, server_default="0", nullable=False)
    is_active = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    users = relationship("User", back_populates="restaurant")
    drive_connection = relationship(
        "RestaurantDriveConnection", back_populates="restaurant", uselist=False
    )


class RestaurantDriveConnection(Base):
    """The Google Drive account a restaurant's backups and reports go to."""

    __tablename__ = "restaurant_drive_connections"

    id = Column(Integer, primary_key=True, index=True)
    restaurant_id = Column(Integer, ForeignKey("restaurants.id"), unique=True, nullable=False)
    google_email = Column(String(254), nullable=True)
    # Fernet-encrypted OAuth refresh token (key derived from SECRET_KEY).
    refresh_token_encrypted = Column(Text, nullable=False)
    folder_id = Column(String(128), nullable=True)
    connected_by_user_id = Column(Integer, nullable=True)
    connected_at = Column(DateTime, server_default=func.now())
    last_upload_at = Column(DateTime, nullable=True)
    last_error = Column(Text, nullable=True)

    restaurant = relationship("Restaurant", back_populates="drive_connection")


class User(TenantMixin, Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    # Usernames are intentionally globally unique. This makes cashier login
    # unambiguous even when many restaurants share one K POS installation.
    username = Column(String(254), unique=True, index=True, nullable=False)
    email = Column(String(254), unique=True, index=True, nullable=True)
    email_verified = Column(Boolean, default=False, nullable=False)
    password_hash = Column(String(255), nullable=False)
    role = Column(String(20), nullable=False)  # "admin" 或 "cashier"
    full_name = Column(String(100))
    is_active = Column(Boolean, default=True)
    # Soft deletion preserves historical foreign-key references while hiding
    # the account from management screens and preventing future login.
    is_deleted = Column(Boolean, default=False, nullable=False)
    # cashier permission overrides; NULL treated as all defaults
    permissions = Column(JSON, nullable=True)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    restaurant = relationship("Restaurant", back_populates="users")


class EmailVerificationToken(Base):
    __tablename__ = "email_verification_tokens"

    id = Column(Integer, primary_key=True, index=True)
    restaurant_id = Column(Integer, ForeignKey("restaurants.id"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    token_hash = Column(String(64), unique=True, nullable=False, index=True)
    expires_at = Column(DateTime, nullable=False)
    used_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, server_default=func.now())

    user = relationship("User")


class Category(TenantMixin, Base):
    __tablename__ = "categories"
    __table_args__ = (UniqueConstraint("restaurant_id", "name", name="uq_category_restaurant_name"),)

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(50), nullable=False)
    sort_order = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    products = relationship("Product", back_populates="category")


class Product(TenantMixin, Base):
    __tablename__ = "products"

    id = Column(Integer, primary_key=True, index=True)
    category_id = Column(Integer, ForeignKey("categories.id"), nullable=True)
    name = Column(String(100), nullable=False)
    description = Column(Text, nullable=True)
    price = Column(Numeric(10, 2), nullable=False)
    # "active" = 售卖中, "inactive" = 停售
    status = Column(String(20), default="active", nullable=False)
    image_path = Column(String(255), nullable=True)
    sort_order = Column(Integer, default=0)
    sold_by_weight = Column(Boolean, default=False, nullable=False)
    is_deleted = Column(Boolean, default=False)  # 软删除，不真删数据
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    category = relationship("Category", back_populates="products")


class Table(TenantMixin, Base):
    __tablename__ = "tables"
    __table_args__ = (UniqueConstraint("restaurant_id", "name", name="uq_table_restaurant_name"),)

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(20), nullable=False)   # e.g. "T01"
    capacity = Column(Integer, default=4)
    # "available" | "occupied"
    status = Column(String(20), default="available", nullable=False)
    sort_order = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    orders = relationship("Order", back_populates="table")


class Order(TenantMixin, Base):
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, index=True)
    order_number = Column(String(30), unique=True, nullable=False, index=True)
    table_id = Column(Integer, ForeignKey("tables.id"), nullable=True)   # takeaway or custom = NULL
    table_name = Column(String(50), nullable=True)                        # custom table label
    # "dine_in" | "take_away"
    order_type = Column(String(20), default="dine_in", nullable=False)
    # "open" | "paid" | "cancelled"
    status = Column(String(20), default="open", nullable=False)
    notes = Column(Text, nullable=True)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    offline_ref = Column(String(100), unique=True, nullable=True)   # device UUID for offline sync dedup
    is_deleted = Column(Boolean, default=False)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    table = relationship("Table", back_populates="orders")
    creator = relationship("User")
    items = relationship("OrderItem", back_populates="order", cascade="all, delete-orphan")


class OrderItem(TenantMixin, Base):
    __tablename__ = "order_items"

    id = Column(Integer, primary_key=True, index=True)
    order_id = Column(Integer, ForeignKey("orders.id"), nullable=False)
    product_id = Column(Integer, ForeignKey("products.id"), nullable=False)
    quantity = Column(Integer, nullable=False, default=1)
    # 下单时的价格快照，不跟随商品调价
    unit_price = Column(Numeric(10, 2), nullable=False)
    weight_kg = Column(Numeric(8, 3), nullable=True)   # for sold_by_weight products
    notes = Column(String(255), nullable=True)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    order = relationship("Order", back_populates="items")
    product = relationship("Product")

    @property
    def product_name(self) -> str:
        return self.product.name if self.product else ""

    @property
    def subtotal(self) -> D:
        if self.weight_kg is not None:
            return D(str(self.weight_kg)) * D(str(self.unit_price))
        return D(str(self.quantity)) * D(str(self.unit_price))


class StoreSettings(TenantMixin, Base):
    """
    简单 key-value 配置表，存税率开关等。
    预置 key：
      sst_enabled (0/1), sst_rate (e.g. "0.06")
      service_charge_enabled (0/1), service_charge_rate (e.g. "0.10")
    """
    __tablename__ = "store_settings"
    __table_args__ = (UniqueConstraint("restaurant_id", "key", name="uq_setting_restaurant_key"),)

    id = Column(Integer, primary_key=True, index=True)
    key = Column(String(50), nullable=False)
    value = Column(String(100), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())


class Payment(TenantMixin, Base):
    __tablename__ = "payments"

    id = Column(Integer, primary_key=True, index=True)
    order_id = Column(Integer, ForeignKey("orders.id"), nullable=False, index=True)
    offline_ref = Column(String(100), unique=True, nullable=True, index=True)
    # "cash" | "duitnow"
    payment_method = Column(String(20), nullable=False)
    # "completed" | "voided"
    status = Column(String(20), default="completed", nullable=False)
    subtotal = Column(Numeric(10, 2), nullable=False)
    discount_percent = Column(Numeric(5, 2), default=0)   # 0-100
    discount_amount = Column(Numeric(10, 2), default=0)
    service_charge_rate = Column(Numeric(5, 4), default=0)  # 快照结账时的税率
    service_charge_amount = Column(Numeric(10, 2), default=0)
    sst_rate = Column(Numeric(5, 4), default=0)
    sst_amount = Column(Numeric(10, 2), default=0)
    grand_total = Column(Numeric(10, 2), nullable=False)
    cash_tendered = Column(Numeric(10, 2), nullable=True)   # 现金时顾客付了多少
    change_amount = Column(Numeric(10, 2), nullable=True)   # 找零
    promotion_id = Column(Integer, ForeignKey("promotions.id"), nullable=True)
    notes = Column(String(255), nullable=True)
    # Set when "add payment income to cash record" is enabled in settings.
    cash_record_id = Column(Integer, ForeignKey("cash_records.id"), nullable=True)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    order = relationship("Order")
    cashier = relationship("User", foreign_keys=[created_by])
    promotion = relationship("Promotion", foreign_keys=[promotion_id])
    audit_logs = relationship("PaymentAuditLog", back_populates="payment")
    cash_record = relationship("CashRecord")


class PaymentAuditLog(TenantMixin, Base):
    __tablename__ = "payment_audit_logs"

    id = Column(Integer, primary_key=True, index=True)
    payment_id = Column(Integer, ForeignKey("payments.id"), nullable=False)
    # "edit" | "void"
    action = Column(String(20), nullable=False)
    reason = Column(Text, nullable=False)
    # 操作前的完整状态快照（order + items + payment），JSON 存储
    snapshot_before = Column(JSON, nullable=False)
    changed_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now())

    payment = relationship("Payment", back_populates="audit_logs")
    editor = relationship("User")


class CashRecord(TenantMixin, Base):
    __tablename__ = "cash_records"

    id = Column(Integer, primary_key=True, index=True)
    offline_ref = Column(String(100), unique=True, nullable=True, index=True)
    # "cash_in" | "cash_out"
    type = Column(String(20), nullable=False)
    amount = Column(Numeric(10, 2), nullable=False)
    description = Column(String(255), nullable=False)
    category = Column(String(100), nullable=True)
    reference = Column(String(100), nullable=True)
    receipt_image_path = Column(String(255), nullable=True)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now())

    creator = relationship("User")


class LoginLog(TenantMixin, Base):
    __tablename__ = "login_logs"

    id = Column(Integer, primary_key=True, index=True)
    # Failed logins cannot always be associated with a tenant; they remain
    # visible only to platform diagnostics, never to a restaurant admin.
    restaurant_id = Column(Integer, ForeignKey("restaurants.id"), nullable=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    username = Column(String(50), nullable=False, index=True)
    success = Column(Boolean, nullable=False)
    ip_address = Column(String(45), nullable=True)
    user_agent = Column(String(255), nullable=True)
    created_at = Column(DateTime, server_default=func.now())

    user = relationship("User")


class Worker(TenantMixin, Base):
    __tablename__ = "workers"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    ic_number = Column(String(20), nullable=True)
    phone = Column(String(20), nullable=True)
    position = Column(String(100), nullable=True)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, server_default=func.now())

    salary_payments = relationship("SalaryPayment", back_populates="worker")


class SalaryPayment(TenantMixin, Base):
    __tablename__ = "salary_payments"

    id = Column(Integer, primary_key=True, index=True)
    worker_id = Column(Integer, ForeignKey("workers.id"), nullable=False)
    year = Column(Integer, nullable=False)
    month = Column(Integer, nullable=False)
    amount = Column(Numeric(10, 2), nullable=False)
    note = Column(String(255), nullable=True)
    cash_record_id = Column(Integer, ForeignKey("cash_records.id"), nullable=True)
    signature_image_path = Column(String(255), nullable=True)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now())

    worker = relationship("Worker", back_populates="salary_payments")
    cash_record = relationship("CashRecord")
    creator = relationship("User")

    @property
    def worker_name(self) -> str:
        return self.worker.name if self.worker else ""


class Promotion(TenantMixin, Base):
    __tablename__ = "promotions"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    # "discount_pct" | "b1f1" | "happy_hour" | "promo_code"
    type = Column(String(30), nullable=False, index=True)
    # conditions shape per type:
    #   discount_pct  → {"percent": 10.0, "product_ids": []}   empty = whole order
    #   b1f1          → {"product_id": 5}
    #   happy_hour    → {"percent": 15.0, "days": [0,1,2,3,4], "start_time": "14:00", "end_time": "17:00", "product_ids": []}
    #   promo_code    → {"code": "SAVE10", "percent": 10.0, "usage_limit": 0, "min_order": 0}
    conditions = Column(JSON, nullable=False, default=dict)
    starts_at = Column(DateTime, nullable=True)
    ends_at = Column(DateTime, nullable=True)
    usage_count = Column(Integer, default=0, nullable=False)
    is_active = Column(Boolean, default=True, nullable=False)
    is_deleted = Column(Boolean, default=False, nullable=False)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    creator = relationship("User", foreign_keys=[created_by])


@event.listens_for(Session, "do_orm_execute")
def _apply_restaurant_scope(execute_state):
    """Automatically isolate every tenant-owned SELECT in request sessions."""
    restaurant_id = execute_state.session.info.get("restaurant_id")
    if restaurant_id is None or execute_state.execution_options.get("skip_tenant_scope"):
        return
    if execute_state.is_select:
        execute_state.statement = execute_state.statement.options(
            with_loader_criteria(
                TenantMixin,
                lambda row: row.restaurant_id == restaurant_id,
                include_aliases=True,
            )
        )
    elif execute_state.is_update or execute_state.is_delete:
        mapper = execute_state.bind_mapper
        if mapper is not None and issubclass(mapper.class_, TenantMixin):
            execute_state.statement = execute_state.statement.where(
                mapper.class_.restaurant_id == restaurant_id
            )


@event.listens_for(Session, "before_flush")
def _assign_and_validate_restaurant(session, _flush_context, _instances):
    """Assign new rows to the authenticated restaurant and reject cross-tenant writes."""
    restaurant_id = session.info.get("restaurant_id")
    if restaurant_id is None:
        return
    for row in session.new.union(session.dirty):
        if isinstance(row, TenantMixin):
            if row.restaurant_id is None:
                row.restaurant_id = restaurant_id
            elif row.restaurant_id != restaurant_id:
                raise ValueError("Cross-restaurant write rejected")
