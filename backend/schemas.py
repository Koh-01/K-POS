from pydantic import BaseModel, field_validator
from decimal import Decimal
from datetime import datetime

class UserCreate(BaseModel):
    username: str
    password: str
    role: str  # "admin" 或 "cashier"
    full_name: str | None = None

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
    role: str
    full_name: str | None = None
    is_active: bool
    permissions: dict = {}

    @field_validator("permissions", mode="before")
    @classmethod
    def _norm_permissions(cls, v):
        return v if isinstance(v, dict) else {}

    class Config:
        from_attributes = True

class LoginRequest(BaseModel):
    username: str
    password: str

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

    class Config:
        from_attributes = True


# ── Product ───────────────────────────────────────────────
class ProductCreate(BaseModel):
    category_id: int | None = None
    name: str
    description: str | None = None
    price: Decimal
    status: str = "active"
    sort_order: int = 0
    sold_by_weight: bool = False

class ProductUpdate(BaseModel):
    category_id: int | None = None
    name: str | None = None
    description: str | None = None
    price: Decimal | None = None
    status: str | None = None  # "active" 或 "inactive"
    sort_order: int | None = None
    sold_by_weight: bool | None = None

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

    class Config:
        from_attributes = True


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
    sort_order: int
    is_active: bool
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


# ── OrderItem ─────────────────────────────────────────────
class OrderItemCreate(BaseModel):
    product_id: int
    quantity: int = 1
    weight_kg: float | None = None
    notes: str | None = None

class OrderItemUpdate(BaseModel):
    quantity: int | None = None
    weight_kg: float | None = None
    notes: str | None = None

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

    class Config:
        from_attributes = True


# ── Order ─────────────────────────────────────────────────
class OrderCreate(BaseModel):
    table_id: int | None = None          # takeaway 或 custom table 时不传
    table_name: str | None = None        # custom table label (not saved to tables list)
    order_type: str = "dine_in"          # "dine_in" | "take_away"
    notes: str | None = None
    items: list[OrderItemCreate] = []

class OrderUpdate(BaseModel):
    notes: str | None = None
    order_type: str | None = None
    items: list[OrderItemCreate] | None = None

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
    items: list[OrderItemResponse] = []

    class Config:
        from_attributes = True


# ── StoreSettings ─────────────────────────────────────────
class SettingsResponse(BaseModel):
    sst_enabled: bool
    sst_rate: Decimal
    service_charge_enabled: bool
    service_charge_rate: Decimal


# ── Payment ───────────────────────────────────────────────
class PaymentCreate(BaseModel):
    order_id: int
    payment_method: str                         # "cash" | "duitnow"
    promotion_id: int | None = None             # promotion to apply (overrides manual discount)
    promo_code: str | None = None               # alternative: enter code directly
    discount_percent: Decimal = Decimal("0")    # ignored if promotion_id/promo_code given
    discount_amount: Decimal = Decimal("0")     # ignored if promotion_id/promo_code given
    cash_tendered: Decimal | None = None
    notes: str | None = None

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

    class Config:
        from_attributes = True

class PaymentResponse(BaseModel):
    id: int
    order_id: int
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

    class Config:
        from_attributes = True


class PaymentDetailResponse(PaymentResponse):
    order_number: str | None = None
    table_name: str | None = None
    order_type: str | None = None
    items: list[OrderItemResponse] = []


# ── Audit ──────────────────────────────────────────────────
class PaymentVoidRequest(BaseModel):
    reason: str

class PaymentEditRequest(BaseModel):
    items: list[OrderItemCreate]           # 完整替换订单商品列表
    discount_percent: Decimal = Decimal("0")
    discount_amount: Decimal = Decimal("0")
    reason: str                            # 必填，写入审计日志

class AuditLogResponse(BaseModel):
    id: int
    payment_id: int
    action: str
    reason: str
    snapshot_before: dict
    changed_by: int
    created_at: datetime

    class Config:
        from_attributes = True


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

class CashRecordResponse(BaseModel):
    id: int
    type: str
    amount: Decimal
    description: str
    category: str | None
    reference: str | None
    receipt_image_path: str | None
    created_by: int
    created_at: datetime

    class Config:
        from_attributes = True


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
    category_name: str
    total_qty: int
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

class AllSettingsResponse(BaseModel):
    sst_enabled: bool
    sst_rate: Decimal
    service_charge_enabled: bool
    service_charge_rate: Decimal
    payment_to_cash_record: bool
    store_name: str
    store_address: str
    store_phone: str
    store_email: str
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


# ── Login Log ──────────────────────────────────────────────
class LoginLogResponse(BaseModel):
    id: int
    user_id: int | None
    username: str
    success: bool
    ip_address: str | None
    user_agent: str | None
    created_at: datetime

    class Config:
        from_attributes = True


# ── Offline Sync ───────────────────────────────────────────
class SyncOrderCreate(BaseModel):
    offline_ref: str
    table_id: int | None = None
    order_type: str = "dine_in"
    notes: str | None = None
    items: list[OrderItemCreate]
    device_created_at: datetime | None = None   # actual creation time on device

class SyncOrderResult(BaseModel):
    offline_ref: str
    order_id: int | None
    order_number: str | None
    action: str       # "created" | "skipped" | "error"
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

    class Config:
        from_attributes = True

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

    class Config:
        from_attributes = True


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
    created_at: datetime

    class Config:
        from_attributes = True