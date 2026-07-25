from decimal import Decimal as D
from sqlalchemy import Column, Integer, String, Boolean, DateTime, Numeric, ForeignKey, Text, JSON
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from database import Base

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(50), unique=True, index=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    role = Column(String(20), nullable=False)  # "admin" 或 "cashier"
    full_name = Column(String(100))
    is_active = Column(Boolean, default=True)
    # cashier permission overrides; NULL treated as all defaults
    permissions = Column(JSON, nullable=True)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())


class Category(Base):
    __tablename__ = "categories"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(50), unique=True, nullable=False)
    sort_order = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    products = relationship("Product", back_populates="category")


class Product(Base):
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


class Table(Base):
    __tablename__ = "tables"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(20), unique=True, nullable=False)   # e.g. "T01"
    capacity = Column(Integer, default=4)
    # "available" | "occupied"
    status = Column(String(20), default="available", nullable=False)
    sort_order = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    orders = relationship("Order", back_populates="table")


class Order(Base):
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


class OrderItem(Base):
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


class StoreSettings(Base):
    """
    简单 key-value 配置表，存税率开关等。
    预置 key：
      sst_enabled (0/1), sst_rate (e.g. "0.06")
      service_charge_enabled (0/1), service_charge_rate (e.g. "0.10")
    """
    __tablename__ = "store_settings"

    id = Column(Integer, primary_key=True, index=True)
    key = Column(String(50), unique=True, nullable=False)
    value = Column(String(100), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())


class Payment(Base):
    __tablename__ = "payments"

    id = Column(Integer, primary_key=True, index=True)
    order_id = Column(Integer, ForeignKey("orders.id"), nullable=False, index=True)
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


class PaymentAuditLog(Base):
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


class CashRecord(Base):
    __tablename__ = "cash_records"

    id = Column(Integer, primary_key=True, index=True)
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


class LoginLog(Base):
    __tablename__ = "login_logs"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    username = Column(String(50), nullable=False, index=True)
    success = Column(Boolean, nullable=False)
    ip_address = Column(String(45), nullable=True)
    user_agent = Column(String(255), nullable=True)
    created_at = Column(DateTime, server_default=func.now())

    user = relationship("User")


class Worker(Base):
    __tablename__ = "workers"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    ic_number = Column(String(20), nullable=True)
    phone = Column(String(20), nullable=True)
    position = Column(String(100), nullable=True)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, server_default=func.now())

    salary_payments = relationship("SalaryPayment", back_populates="worker")


class SalaryPayment(Base):
    __tablename__ = "salary_payments"

    id = Column(Integer, primary_key=True, index=True)
    worker_id = Column(Integer, ForeignKey("workers.id"), nullable=False)
    year = Column(Integer, nullable=False)
    month = Column(Integer, nullable=False)
    amount = Column(Numeric(10, 2), nullable=False)
    note = Column(String(255), nullable=True)
    cash_record_id = Column(Integer, ForeignKey("cash_records.id"), nullable=True)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now())

    worker = relationship("Worker", back_populates="salary_payments")
    cash_record = relationship("CashRecord")
    creator = relationship("User")

    @property
    def worker_name(self) -> str:
        return self.worker.name if self.worker else ""


class Promotion(Base):
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
    conditions = Column(JSON, nullable=False, default={})
    starts_at = Column(DateTime, nullable=True)
    ends_at = Column(DateTime, nullable=True)
    usage_count = Column(Integer, default=0, nullable=False)
    is_active = Column(Boolean, default=True, nullable=False)
    is_deleted = Column(Boolean, default=False, nullable=False)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    creator = relationship("User", foreign_keys=[created_by])