from pydantic import BaseModel, ConfigDict, Field, field_validator
from decimal import Decimal
from datetime import datetime

class UserCreate(BaseModel):
    username: str
    password: str
    role: str  # "admin" 或 "cashier"
    full_name: str | None = None

    @field_validator("role")
    @classmethod
    def _valid_role(cls, value: str) -> str:
        if value not in ("admin", "cashier"):
            raise ValueError("role must be 'admin' or 'cashier'")
        return value

    @field_validator("password")
    @classmethod
    def _valid_password(cls, value: str) -> str:
        if len(value) < 8:
            raise ValueError("password must be at least 8 characters")
        return value

class UserPermissionsUpdate(BaseModel):
    can_view_cash: bool = True
    can_add_cash: bool = True
    can_edit_cash: bool = True
    can_delete_cash: bool = True
    can_manage_catalog: bool = False
    can_manage_promotion: bool = False
    can_manage_payment: bool = False
    can_manage_settings: bool = False
    hide_salary_from_cash: bool = False

class UserResponse(BaseModel):
    id: int
    username: str
    email: str | None = None
    email_verified: bool = False
    restaurant_id: int
    role: str
    full_name: str | None = None
    is_active: bool
    permissions: dict = Field(default_factory=dict)

    @field_validator("permissions", mode="before")
    @classmethod
    def _norm_permissions(cls, v):
        return v if isinstance(v, dict) else {}

    model_config = ConfigDict(from_attributes=True)

class LoginRequest(BaseModel):
    username: str
    password: str


class AdminRegistrationRequest(BaseModel):
    restaurant_name: str = Field(min_length=2, max_length=150)
    full_name: str = Field(min_length=2, max_length=100)
    email: str = Field(min_length=3, max_length=254)
    password: str

    @field_validator("restaurant_name", "full_name")
    @classmethod
    def _strip_required_text(cls, value: str) -> str:
        value = value.strip()
        if len(value) < 2:
            raise ValueError("value is too short")
        return value

    @field_validator("password")
    @classmethod
    def _registration_password(cls, value: str) -> str:
        if len(value) < 8:
            raise ValueError("password must be at least 8 characters")
        return value

    @field_validator("email")
    @classmethod
    def _registration_email(cls, value: str) -> str:
        value = value.strip().lower()
        local, separator, domain = value.rpartition("@")
        if not separator or not local or "." not in domain or domain.startswith(".") or domain.endswith("."):
            raise ValueError("enter a valid email address")
        return value


class ResendVerificationRequest(BaseModel):
    email: str = Field(min_length=3, max_length=254)

    @field_validator("email")
    @classmethod
    def _resend_email(cls, value: str) -> str:
        value = value.strip().lower()
        local, separator, domain = value.rpartition("@")
        if not separator or not local or "." not in domain or domain.startswith(".") or domain.endswith("."):
            raise ValueError("enter a valid email address")
        return value


class VerifyEmailRequest(BaseModel):
    token: str = Field(min_length=20, max_length=200)

class UserProfileUpdate(BaseModel):
    full_name: str | None = None
    role: str | None = None             # admin-only field

class ChangePasswordRequest(BaseModel):
    current_password: str | None = None  # required when changing own password
    new_password: str

class UserStatusUpdate(BaseModel):
    is_active: bool


# ── Category ──────────────────────────────────────────────
class CategoryCreate(BaseModel):
    name: str
    sort_order: int = 0

class CategoryUpdate(BaseModel):
    name: str | None = None
    sort_order: int | None = None
    is_active: bool | None = None

class CategoryResponse(BaseModel):
    id: int
    name: str
    sort_order: int
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Product ───────────────────────────────────────────────
class ProductCreate(BaseModel):
    category_id: int | None = None
    name: str
    description: str | None = None
    price: Decimal
    status: str = "active"
    sort_order: int = 0
    sold_by_weight: bool = False

    @field_validator("price")
    @classmethod
    def _positive_price(cls, value: Decimal) -> Decimal:
        if value < 0:
            raise ValueError("price must be non-negative")
        return value

class ProductUpdate(BaseModel):
    category_id: int | None = None
    name: str | None = None
    description: str | None = None
    price: Decimal | None = None
    status: str | None = None  # "active" 或 "inactive"
    sort_order: int | None = None
    sold_by_weight: bool | None = None

    @field_validator("price")
    @classmethod
    def _positive_price(cls, value: Decimal | None) -> Decimal | None:
        if value is not None and value < 0:
            raise ValueError("price must be non-negative")
        return value

class ProductResponse(BaseModel):
    id: int
    category_id: int | None
    name: str
    description: str | None
    price: Decimal
    status: str
    image_path: str | None
    sort_order: int
    sold_by_weight: bool
    is_deleted: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Table ─────────────────────────────────────────────────
class TableCreate(BaseModel):
    name: str
    capacity: int = 4
    sort_order: int = 0

class TableUpdate(BaseModel):
    name: str | None = None
    capacity: int | None = None
    sort_order: int | None = None
    is_active: bool | None = None

class TableResponse(BaseModel):
    id: int
    name: str
    capacity: int
    status: str
    # The open order seated at this table, so the app can reopen it.
    current_order_id: int | None = None
    sort_order: int
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── OrderItem ─────────────────────────────────────────────
class OrderItemCreate(BaseModel):
    product_id: int
    quantity: int = 1
    weight_kg: float | None = None
    notes: str | None = None

    @field_validator("quantity")
    @classmethod
    def _positive_quantity(cls, value: int) -> int:
        if value <= 0:
            raise ValueError("quantity must be greater than zero")
        return value

    @field_validator("weight_kg")
    @classmethod
    def _positive_weight(cls, value: float | None) -> float | None:
        if value is not None and value <= 0:
            raise ValueError("weight_kg must be greater than zero")
        return value

class OrderItemUpdate(BaseModel):
    quantity: int | None = None
    weight_kg: float | None = None
    notes: str | None = None

    @field_validator("quantity")
    @classmethod
    def _positive_quantity(cls, value: int | None) -> int | None:
        if value is not None and value <= 0:
            raise ValueError("quantity must be greater than zero")
        return value

    @field_validator("weight_kg")
    @classmethod
    def _positive_weight(cls, value: float | None) -> float | None:
        if value is not None and value <= 0:
            raise ValueError("weight_kg must be greater than zero")
        return value

class OrderItemResponse(BaseModel):
    id: int
    order_id: int
    product_id: int
    product_name: str
    quantity: int
    unit_price: Decimal
    weight_kg: Decimal | None
    subtotal: Decimal
    notes: str | None
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Order ─────────────────────────────────────────────────
class OrderCreate(BaseModel):
    offline_ref: str | None = Field(default=None, max_length=100)
    table_id: int | None = None          # takeaway 或 custom table 时不传
    table_name: str | None = None        # custom table label (not saved to tables list)
    order_type: str = "dine_in"          # "dine_in" | "take_away"
    notes: str | None = None
    items: list[OrderItemCreate] = Field(default_factory=list)

    @field_validator("order_type")
    @classmethod
    def _valid_order_type(cls, value: str) -> str:
        # Accept legacy clients once, but persist the canonical API value.
        if value == "takeaway":
            value = "take_away"
        if value not in ("dine_in", "take_away"):
            raise ValueError("order_type must be 'dine_in' or 'take_away'")
        return value

class OrderUpdate(BaseModel):
    table_id: int | None = None
    table_name: str | None = None
    notes: str | None = None
    order_type: str | None = None
    items: list[OrderItemCreate] | None = None

    @field_validator("order_type")
    @classmethod
    def _valid_order_type(cls, value: str | None) -> str | None:
        if value == "takeaway":
            value = "take_away"
        if value is not None and value not in ("dine_in", "take_away"):
            raise ValueError("order_type must be 'dine_in' or 'take_away'")
        return value

class OrderResponse(BaseModel):
    id: int
    order_number: str
    table_id: int | None
    table_name: str | None
    order_type: str
    status: str
    notes: str | None
    created_by: int
    is_deleted: bool
    created_at: datetime
    updated_at: datetime
    items: list[OrderItemResponse] = Field(default_factory=list)

    model_config = ConfigDict(from_attributes=True)


class OrderSplitItem(BaseModel):
    item_id: int
    # How many to move to the new bill; None moves the whole line. Weighed
    # items always move as a whole line.
    quantity: int | None = Field(default=None, ge=1)


class OrderSplitRequest(BaseModel):
    items: list[OrderSplitItem] = Field(min_length=1)


class OrderSplitResponse(BaseModel):
    source: OrderResponse
    new_order: OrderResponse


# ── StoreSettings ─────────────────────────────────────────
class SettingsResponse(BaseModel):
    sst_enabled: bool
    sst_rate: Decimal
    service_charge_enabled: bool
    service_charge_rate: Decimal


# ── Payment ───────────────────────────────────────────────
class PaymentCreate(BaseModel):
    order_id: int
    offline_ref: str | None = Field(default=None, max_length=100)
    payment_method: str                         # "cash" | "duitnow"
    promotion_id: int | None = None             # promotion to apply (overrides manual discount)
    promo_code: str | None = None               # alternative: enter code directly
    discount_percent: Decimal = Decimal("0")    # ignored if promotion_id/promo_code given
    discount_amount: Decimal = Decimal("0")     # ignored if promotion_id/promo_code given
    cash_tendered: Decimal | None = None
    notes: str | None = None

    @field_validator("payment_method")
    @classmethod
    def _valid_method(cls, value: str) -> str:
        if value not in ("cash", "duitnow", "card"):
            raise ValueError("unsupported payment method")
        return value

    @field_validator("discount_percent")
    @classmethod
    def _valid_discount_percent(cls, value: Decimal) -> Decimal:
        if value < 0 or value > 100:
            raise ValueError("discount_percent must be between 0 and 100")
        return value

    @field_validator("discount_amount", "cash_tendered")
    @classmethod
    def _non_negative_amount(cls, value: Decimal | None) -> Decimal | None:
        if value is not None and value < 0:
            raise ValueError("amount cannot be negative")
        return value

class PaymentPreview(BaseModel):
    """结账前预览金额，不写入数据库"""
    order_id: int
    subtotal: Decimal
    discount_percent: Decimal
    discount_amount: Decimal
    service_charge_rate: Decimal
    service_charge_amount: Decimal
    sst_rate: Decimal
    sst_amount: Decimal
    grand_total: Decimal

    model_config = ConfigDict(from_attributes=True)

class PaymentResponse(BaseModel):
    id: int
    order_id: int
    offline_ref: str | None = None
    promotion_id: int | None
    payment_method: str
    status: str
    subtotal: Decimal
    discount_percent: Decimal
    discount_amount: Decimal
    service_charge_rate: Decimal
    service_charge_amount: Decimal
    sst_rate: Decimal
    sst_amount: Decimal
    grand_total: Decimal
    cash_tendered: Decimal | None
    change_amount: Decimal | None
    notes: str | None
    cash_record_id: int | None = None
    created_by: int
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class PaymentDetailResponse(PaymentResponse):
    order_number: str | None = None
    table_name: str | None = None
    order_type: str | None = None
    items: list[OrderItemResponse] = Field(default_factory=list)


# ── Audit ──────────────────────────────────────────────────
class PaymentVoidRequest(BaseModel):
    reason: str

class PaymentEditRequest(BaseModel):
    items: list[OrderItemCreate]           # 完整替换订单商品列表
    discount_percent: Decimal = Decimal("0")
    discount_amount: Decimal = Decimal("0")
    # Optional for the cashier. Audit rows keep an empty string when omitted
    # because the existing database column is intentionally non-null.
    reason: str = ""

class AuditLogResponse(BaseModel):
    id: int
    payment_id: int
    action: str
    reason: str
    snapshot_before: dict
    changed_by: int
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── CashRecord ─────────────────────────────────────────────
class CashRecordUpdate(BaseModel):
    amount: Decimal | None = None
    description: str | None = None
    category: str | None = None
    reference: str | None = None

class CashRecordCreate(BaseModel):
    type: str                   # "cash_in" | "cash_out"
    amount: Decimal
    description: str = ""
    category: str | None = None
    reference: str | None = None
    offline_ref: str | None = Field(default=None, max_length=100)

class CashRecordResponse(BaseModel):
    id: int
    offline_ref: str | None = None
    type: str
    amount: Decimal
    description: str
    category: str | None
    reference: str | None
    receipt_image_path: str | None
    created_by: int
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Reports ────────────────────────────────────────────────
class DashboardResponse(BaseModel):
    today_revenue: Decimal
    orders_today: int
    top_product_today: str | None
    active_tables: int
    total_cash_in_today: Decimal
    total_cash_out_today: Decimal

class DailySalesSummary(BaseModel):
    date: str           # "YYYY-MM-DD"
    revenue: Decimal
    orders: int

class SalesReportResponse(BaseModel):
    start_date: str
    end_date: str
    total_revenue: Decimal
    total_orders: int
    daily_breakdown: list[DailySalesSummary]

class MonthlySalesSummary(BaseModel):
    month: str          # "YYYY-MM"
    revenue: Decimal
    orders: int

class AnnualReportResponse(BaseModel):
    year: int
    total_revenue: Decimal
    total_orders: int
    monthly_breakdown: list[MonthlySalesSummary]

class ProductSalesItem(BaseModel):
    product_id: int
    product_name: str
    category_name: str | None
    total_qty: Decimal
    total_revenue: Decimal

class TopProductsResponse(BaseModel):
    start_date: str
    end_date: str
    products: list[ProductSalesItem]


# ── All Settings (Phase 4) ─────────────────────────────────
class AllSettingsUpdate(BaseModel):
    sst_enabled: bool | None = None
    sst_rate: Decimal | None = None
    service_charge_enabled: bool | None = None
    service_charge_rate: Decimal | None = None
    store_name: str | None = None
    store_address: str | None = None
    store_phone: str | None = None
    store_email: str | None = None
    store_ssm_number: str | None = None
    tax_registration_number: str | None = None
    store_logo_path: str | None = None
    theme: str | None = None               # "light" | "dark"
    receipt_header: str | None = None
    receipt_header_size: int | None = None  # 0=small 1=normal 2=large
    receipt_header_align: int | None = None # 0=left 1=center 2=right
    receipt_footer: str | None = None
    receipt_footer_size: int | None = None
    receipt_footer_align: int | None = None
    receipt_show_logo: bool | None = None
    duitnow_qr_image_url: str | None = None
    payment_to_cash_record: bool | None = None
    require_salary_signature: bool | None = None
    order_card_category_ids: list[int] | None = Field(default=None, max_length=12)

    @field_validator("sst_rate", "service_charge_rate")
    @classmethod
    def _valid_rate(cls, value: Decimal | None) -> Decimal | None:
        if value is not None and not Decimal("0") <= value <= Decimal("1"):
            raise ValueError("rate must be between 0 and 1")
        return value

    @field_validator(
        "receipt_header_size",
        "receipt_header_align",
        "receipt_footer_size",
        "receipt_footer_align",
    )
    @classmethod
    def _valid_receipt_option(cls, value: int | None) -> int | None:
        if value is not None and value not in (0, 1, 2):
            raise ValueError("receipt option must be 0, 1, or 2")
        return value

class AllSettingsResponse(BaseModel):
    sst_enabled: bool
    sst_rate: Decimal
    service_charge_enabled: bool
    service_charge_rate: Decimal
    payment_to_cash_record: bool
    require_salary_signature: bool
    store_name: str
    store_address: str
    store_phone: str
    store_email: str
    store_ssm_number: str
    tax_registration_number: str
    store_logo_path: str
    theme: str
    receipt_header: str
    receipt_header_size: int
    receipt_header_align: int
    receipt_footer: str
    receipt_footer_size: int
    receipt_footer_align: int
    receipt_show_logo: bool
    duitnow_qr_image_url: str
    order_card_category_ids: list[int] = Field(default_factory=list)


# ── Login Log ──────────────────────────────────────────────
class LoginLogResponse(BaseModel):
    id: int
    user_id: int | None
    username: str
    success: bool
    ip_address: str | None
    user_agent: str | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Offline Sync ───────────────────────────────────────────
class SyncOrderItemCreate(OrderItemCreate):
    # Trusted snapshot captured from the last server catalog while offline.
    unit_price: Decimal

    @field_validator("unit_price")
    @classmethod
    def _valid_unit_price(cls, value: Decimal) -> Decimal:
        if value < 0:
            raise ValueError("unit_price must be non-negative")
        return value


class SyncOrderCreate(BaseModel):
    offline_ref: str = Field(min_length=1, max_length=100)
    table_id: int | None = None
    table_name: str | None = None
    order_type: str = "dine_in"
    notes: str | None = None
    paid_locally: bool = False
    items: list[SyncOrderItemCreate]
    device_created_at: datetime | None = None   # actual creation time on device

    @field_validator("order_type")
    @classmethod
    def _valid_order_type(cls, value: str) -> str:
        if value == "takeaway":
            value = "take_away"
        if value not in ("dine_in", "take_away"):
            raise ValueError("order_type must be 'dine_in' or 'take_away'")
        return value

class SyncOrderResult(BaseModel):
    offline_ref: str
    order_id: int | None
    order_number: str | None
    action: str       # "created" | "skipped" | "error"
    error: str | None = None


class SyncPaymentCreate(BaseModel):
    offline_ref: str = Field(min_length=1, max_length=100)
    order_id: int
    payment_method: str
    promotion_id: int | None = None
    subtotal: Decimal
    discount_percent: Decimal = Decimal("0")
    discount_amount: Decimal = Decimal("0")
    service_charge_rate: Decimal = Decimal("0")
    service_charge_amount: Decimal = Decimal("0")
    sst_rate: Decimal = Decimal("0")
    sst_amount: Decimal = Decimal("0")
    grand_total: Decimal
    cash_tendered: Decimal | None = None
    device_created_at: datetime | None = None


class SyncPaymentResult(BaseModel):
    offline_ref: str
    payment_id: int | None = None
    action: str
    error: str | None = None


# ── Data Retention ─────────────────────────────────────────
class DataRetentionPreview(BaseModel):
    cutoff_date: str
    orders_to_delete: int
    payments_to_delete: int
    cash_records_to_delete: int
    login_logs_to_delete: int
    audit_logs_to_delete: int


# ── Promotions ─────────────────────────────────────────────
class PromotionCreate(BaseModel):
    name: str
    type: str           # "discount_pct" | "b1f1" | "happy_hour" | "promo_code"
    conditions: dict
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    is_active: bool = True

class PromotionUpdate(BaseModel):
    name: str | None = None
    conditions: dict | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    is_active: bool | None = None

class PromotionResponse(BaseModel):
    id: int
    name: str
    type: str
    conditions: dict
    starts_at: datetime | None
    ends_at: datetime | None
    usage_count: int
    is_active: bool
    is_deleted: bool
    created_by: int
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)

class PromotionApplyRequest(BaseModel):
    order_id: int
    promotion_id: int | None = None
    promo_code: str | None = None

class PromotionApplyResponse(BaseModel):
    promotion_id: int
    promotion_name: str
    discount_amount: Decimal
    discount_percent: Decimal
    message: str


# ── Worker ─────────────────────────────────────────────────
class WorkerCreate(BaseModel):
    name: str
    ic_number: str | None = None
    phone: str | None = None
    position: str | None = None

class WorkerUpdate(BaseModel):
    name: str | None = None
    ic_number: str | None = None
    phone: str | None = None
    position: str | None = None

class WorkerResponse(BaseModel):
    id: int
    name: str
    ic_number: str | None = None
    phone: str | None = None
    position: str | None = None
    is_active: bool
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── SalaryPayment ──────────────────────────────────────────
class SalaryPaymentCreate(BaseModel):
    worker_id: int
    year: int
    month: int
    amount: Decimal
    note: str | None = None

class SalaryPaymentUpdate(BaseModel):
    amount: Decimal | None = None
    note: str | None = None

class SalaryPaymentResponse(BaseModel):
    id: int
    worker_id: int
    worker_name: str
    year: int
    month: int
    amount: Decimal
    note: str | None = None
    cash_record_id: int | None = None
    signature_image_path: str | None = None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)
