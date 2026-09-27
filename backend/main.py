import logging
import os
import secrets

from fastapi import FastAPI, Depends, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from sqlalchemy import func, or_, text
from pathlib import Path
from contextlib import asynccontextmanager
from apscheduler.schedulers.background import BackgroundScheduler
from database import SessionLocal, get_db, select_restaurant_database
import models
import schemas
from auth import hash_password, verify_password
from token_utils import create_access_token
from dependencies import get_current_user, require_admin
from product_router import router as product_router
from order_router import router as order_router
from payment_router import router as payment_router
from cash_router import router as cash_router
from report_router import router as report_router
from settings_router import router as settings_router
from sync_router import router as sync_router
from admin_router import router as admin_router
from promotion_router import router as promotion_router
from user_router import router as user_router
from salary_router import router as salary_router
from auth_router import router as auth_router
import gdrive_backup
import monthly_report
import tenant_backup
import drive_connections
from drive_connections import DriveNotConnected
from tenant_database import provision_restaurant_database, select_for_user, sync_user_shadow
from web_router import router as web_router, WebLoginRequired
from time_utils import APP_TIMEZONE, local_now
from login_limiter import account_login_limiter, client_ip, login_keys, login_limiter
from payment_cash_records import sync_payment_cash_records

logger = logging.getLogger(__name__)
_scheduler = BackgroundScheduler(timezone=APP_TIMEZONE)


def _scheduled_backup():
    try:
        result = gdrive_backup.run_backup()
        print(f"[backup] {result['filename']} uploaded → {result['drive_file_id']}")
    except Exception as e:
        print(f"[backup] ERROR: {e}")
    control_db = SessionLocal()
    try:
        # Only restaurants that connected their own Google Drive are backed up.
        restaurant_ids = [row.id for row in control_db.query(models.Restaurant).join(
            models.RestaurantDriveConnection
        ).filter(
            models.Restaurant.is_active == True,
            models.Restaurant.database_ready == True,
        )]
        for restaurant_id in restaurant_ids:
            db = SessionLocal()
            try:
                restaurant = db.query(models.Restaurant).filter(models.Restaurant.id == restaurant_id).one()
                select_restaurant_database(db, restaurant)
                result = tenant_backup.run_tenant_backup(db, restaurant)
                print(f"[backup] {result['filename']} uploaded → {result['drive_file_id']}")
            except Exception as exc:
                print(f"[backup] Restaurant {restaurant_id} ERROR: {exc}")
            finally:
                db.close()
    finally:
        control_db.close()


def _scheduled_monthly_report():
    now = local_now()
    # Report covers the previous month
    if now.month == 1:
        year, month = now.year - 1, 12
    else:
        year, month = now.year, now.month - 1
    db = SessionLocal()
    try:
        restaurant_ids = [row.id for row in db.query(models.Restaurant).join(
            models.RestaurantDriveConnection
        ).filter(models.Restaurant.is_active == True)]
    finally:
        db.close()
    for restaurant_id in restaurant_ids:
        try:
            result = monthly_report.run_monthly_report(year, month, restaurant_id)
            print(f"[monthly-report] {result['filename']} uploaded → {result['drive_file_id']}")
        except Exception as e:
            print(f"[monthly-report] Restaurant {restaurant_id} ERROR: {e}")


def _run_migrations():
    from database import engine
    # Create missing tables on a fresh installation before applying the
    # idempotent compatibility alterations used by existing deployments.
    try:
        models.Base.metadata.create_all(bind=engine)
    except Exception as exc:
        print(f"[migrate] WARNING: unable to create missing tables: {exc}")
    migrations = [
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='products' AND COLUMN_NAME='sold_by_weight'",
            "ALTER TABLE products ADD COLUMN sold_by_weight BOOLEAN NOT NULL DEFAULT FALSE",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='order_items' AND COLUMN_NAME='weight_kg'",
            "ALTER TABLE order_items ADD COLUMN weight_kg DECIMAL(8,3) NULL",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='orders' AND COLUMN_NAME='table_name'",
            "ALTER TABLE orders ADD COLUMN table_name VARCHAR(50) NULL",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='cash_records' AND COLUMN_NAME='category'",
            "ALTER TABLE cash_records ADD COLUMN category VARCHAR(100) NULL",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='cash_records' AND COLUMN_NAME='receipt_image_path'",
            "ALTER TABLE cash_records ADD COLUMN receipt_image_path VARCHAR(255) NULL",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='products' AND COLUMN_NAME='category_id' AND IS_NULLABLE='YES'",
            "ALTER TABLE products MODIFY COLUMN category_id INT NULL",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='workers'",
            """CREATE TABLE IF NOT EXISTS workers (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(100) NOT NULL,
                ic_number VARCHAR(20) NULL,
                phone VARCHAR(20) NULL,
                position VARCHAR(100) NULL,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )""",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='salary_payments'",
            """CREATE TABLE IF NOT EXISTS salary_payments (
                id INT AUTO_INCREMENT PRIMARY KEY,
                worker_id INT NOT NULL,
                year INT NOT NULL,
                month INT NOT NULL,
                amount DECIMAL(10,2) NOT NULL,
                note VARCHAR(255) NULL,
                cash_record_id INT NULL,
                created_by INT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (worker_id) REFERENCES workers(id),
                FOREIGN KEY (cash_record_id) REFERENCES cash_records(id),
                FOREIGN KEY (created_by) REFERENCES users(id)
            )""",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='users' AND COLUMN_NAME='permissions'",
            "ALTER TABLE users ADD COLUMN permissions JSON NULL",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='users' AND COLUMN_NAME='is_deleted'",
            "ALTER TABLE users ADD COLUMN is_deleted BOOLEAN NOT NULL DEFAULT FALSE",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='payments' AND COLUMN_NAME='offline_ref'",
            "ALTER TABLE payments ADD COLUMN offline_ref VARCHAR(100) NULL UNIQUE",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='cash_records' AND COLUMN_NAME='offline_ref'",
            "ALTER TABLE cash_records ADD COLUMN offline_ref VARCHAR(100) NULL UNIQUE",
        ),
        (
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='salary_payments' AND COLUMN_NAME='signature_image_path'",
            "ALTER TABLE salary_payments ADD COLUMN signature_image_path VARCHAR(255) NULL",
        ),
    ]
    for check_sql, alter_sql in migrations:
        try:
            with engine.begin() as conn:
                result = conn.execute(text(check_sql))
                if result.scalar() == 0:
                    conn.execute(text(alter_sql))
                    print(f"[migrate] {alter_sql}")
        except Exception as exc:
            print(f"[migrate] WARNING: {alter_sql}: {exc}")

    # Multi-restaurant migration. Existing installations are assigned to one
    # default restaurant before tenant columns become required.
    tenant_tables = [
        "users", "categories", "products", "tables", "orders", "order_items",
        "store_settings", "payments", "payment_audit_logs", "cash_records",
        "login_logs", "workers", "salary_payments", "promotions",
    ]
    try:
        with engine.begin() as conn:
            restaurant_count = conn.execute(text("SELECT COUNT(*) FROM restaurants")).scalar() or 0
            legacy_row_count = conn.execute(text(
                "SELECT (SELECT COUNT(*) FROM users) + "
                "(SELECT COUNT(*) FROM products) + (SELECT COUNT(*) FROM orders)"
            )).scalar() or 0
            if restaurant_count == 0 and legacy_row_count > 0:
                store_name = conn.execute(text(
                    "SELECT value FROM store_settings WHERE `key`='store_name' LIMIT 1"
                )).scalar() or "Existing Restaurant"
                conn.execute(text(
                    "INSERT INTO restaurants (id, name, slug, is_active, database_ready) "
                    "VALUES (1, :name, 'existing-restaurant', TRUE, FALSE)"
                ), {"name": store_name})

            restaurant_columns = {
                row[0] for row in conn.execute(text(
                    "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='restaurants'"
                ))
            }
            if "database_name" not in restaurant_columns:
                conn.execute(text(
                    "ALTER TABLE restaurants ADD COLUMN database_name VARCHAR(64) NULL UNIQUE"
                ))
            if "database_ready" not in restaurant_columns:
                conn.execute(text(
                    "ALTER TABLE restaurants ADD COLUMN database_ready BOOLEAN NOT NULL DEFAULT FALSE"
                ))

            user_columns = {
                row[0] for row in conn.execute(text(
                    "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='users'"
                ))
            }
            if "email" not in user_columns:
                conn.execute(text("ALTER TABLE users ADD COLUMN email VARCHAR(254) NULL UNIQUE"))
            if "email_verified" not in user_columns:
                conn.execute(text("ALTER TABLE users ADD COLUMN email_verified BOOLEAN NOT NULL DEFAULT FALSE"))
            conn.execute(text("ALTER TABLE users MODIFY COLUMN username VARCHAR(254) NOT NULL"))

            for table_name in tenant_tables:
                has_column = conn.execute(text(
                    "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=:table_name "
                    "AND COLUMN_NAME='restaurant_id'"
                ), {"table_name": table_name}).scalar()
                if not has_column:
                    nullable = "NULL" if table_name == "login_logs" else "NULL"
                    conn.execute(text(
                        f"ALTER TABLE `{table_name}` ADD COLUMN restaurant_id INT {nullable}"
                    ))
                conn.execute(text(
                    f"UPDATE `{table_name}` SET restaurant_id=1 WHERE restaurant_id IS NULL"
                ))
                if table_name != "login_logs":
                    conn.execute(text(
                        f"ALTER TABLE `{table_name}` MODIFY COLUMN restaurant_id INT NOT NULL DEFAULT 1"
                    ))
                has_restaurant_index = conn.execute(text(
                    "SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=:table_name "
                    "AND COLUMN_NAME='restaurant_id'"
                ), {"table_name": table_name}).scalar()
                if not has_restaurant_index:
                    conn.execute(text(
                        f"ALTER TABLE `{table_name}` ADD INDEX `ix_{table_name}_restaurant_id` (restaurant_id)"
                    ))
                has_restaurant_fk = conn.execute(text(
                    "SELECT COUNT(*) FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=:table_name "
                    "AND COLUMN_NAME='restaurant_id' AND REFERENCED_TABLE_NAME='restaurants'"
                ), {"table_name": table_name}).scalar()
                if not has_restaurant_fk:
                    conn.execute(text(
                        f"ALTER TABLE `{table_name}` ADD CONSTRAINT `fk_{table_name}_restaurant` "
                        "FOREIGN KEY (restaurant_id) REFERENCES restaurants(id)"
                    ))

            # Legacy accounts predate verification and must keep working.
            conn.execute(text("UPDATE users SET email_verified=TRUE WHERE email IS NULL"))

            # Replace single-store uniqueness with per-restaurant uniqueness.
            for table_name, column_name, index_name in (
                ("categories", "name", "uq_category_restaurant_name"),
                ("tables", "name", "uq_table_restaurant_name"),
                ("store_settings", "key", "uq_setting_restaurant_key"),
            ):
                old_indexes = list(conn.execute(text(
                    "SELECT INDEX_NAME FROM INFORMATION_SCHEMA.STATISTICS "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=:table_name "
                    "AND COLUMN_NAME=:column_name AND NON_UNIQUE=0 AND INDEX_NAME<>'PRIMARY'"
                ), {"table_name": table_name, "column_name": column_name}))
                for (old_index,) in old_indexes:
                    if old_index != index_name:
                        conn.execute(text(f"ALTER TABLE `{table_name}` DROP INDEX `{old_index}`"))
                has_index = conn.execute(text(
                    "SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=:table_name AND INDEX_NAME=:index_name"
                ), {"table_name": table_name, "index_name": index_name}).scalar()
                if not has_index:
                    conn.execute(text(
                        f"ALTER TABLE `{table_name}` ADD CONSTRAINT `{index_name}` "
                        f"UNIQUE (restaurant_id, `{column_name}`)"
                    ))
    except Exception as exc:
        # Do not serve requests with a partially migrated tenant schema.
        raise RuntimeError(f"Multi-restaurant database migration failed: {exc}") from exc


def _provision_existing_restaurant_databases():
    db = SessionLocal()
    try:
        restaurants = db.query(models.Restaurant).all()
        for restaurant in restaurants:
            if not restaurant.database_ready:
                provision_restaurant_database(db, restaurant)
    finally:
        db.close()


def _sync_configured_payment_cash_records():
    """Apply the persisted toggle to historical payments after startup."""

    control_db = SessionLocal()
    try:
        restaurant_ids = [row.id for row in control_db.query(models.Restaurant).filter(models.Restaurant.is_active == True)]
        for restaurant_id in restaurant_ids:
            db = SessionLocal()
            try:
                restaurant = db.query(models.Restaurant).filter(models.Restaurant.id == restaurant_id).one()
                select_restaurant_database(db, restaurant)
                row = (
                    db.query(models.StoreSettings)
                    .filter(models.StoreSettings.key == "payment_to_cash_record")
                    .first()
                )
                enabled = row is not None and row.value == "1"
                created, removed = sync_payment_cash_records(db, enabled=enabled)
                db.commit()
                if created or removed:
                    print(
                        f"[cash-records] Restaurant {restaurant.id}: "
                        f"created={created}, removed={removed}"
                    )
            finally:
                db.close()
    except Exception as exc:
        control_db.rollback()
        print(f"[cash-records] WARNING: unable to reconcile payments: {exc}")
    finally:
        control_db.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    _run_migrations()
    _provision_existing_restaurant_databases()
    _sync_configured_payment_cash_records()
    scheduler_enabled = os.getenv("ENABLE_SCHEDULER", "true").lower() != "false"
    if scheduler_enabled:
        _scheduler.add_job(_scheduled_backup, "cron", hour=12, minute=0, id="daily_backup")
        _scheduler.add_job(_scheduled_monthly_report, "cron", day=1, hour=1, minute=0, id="monthly_report")
        _scheduler.start()
    yield
    if scheduler_enabled:
        _scheduler.shutdown()


# Interactive API docs list every endpoint; keep them off in production.
_api_docs = os.getenv("ENABLE_API_DOCS", "false").lower() == "true"
app = FastAPI(
    title="POS System API",
    lifespan=lifespan,
    docs_url="/docs" if _api_docs else None,
    redoc_url="/redoc" if _api_docs else None,
    openapi_url="/openapi.json" if _api_docs else None,
)


@app.middleware("http")
async def _security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    return response

# Disabled by default. Local Flutter Web development can opt in with a
# comma-separated allow-list, without opening production CORS globally.
cors_origins = [
    origin.strip()
    for origin in os.getenv("CORS_ORIGINS", "").split(",")
    if origin.strip()
]
if cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

# 商品图片静态文件服务
static_dir = Path(__file__).parent / "static"
static_dir.mkdir(exist_ok=True)
app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

app.include_router(product_router, tags=["Products"])
app.include_router(order_router, tags=["Orders"])
app.include_router(payment_router, tags=["Payments"])
app.include_router(cash_router)
app.include_router(report_router)
app.include_router(settings_router)
app.include_router(sync_router)
app.include_router(admin_router)
app.include_router(promotion_router)
app.include_router(user_router)
app.include_router(salary_router)
app.include_router(auth_router)
app.include_router(web_router)

@app.exception_handler(WebLoginRequired)
async def _web_login_required(request: Request, exc: WebLoginRequired):
    return RedirectResponse(url="/web/login", status_code=303)

@app.get("/")
def read_root():
    return {"message": "POS System API is running"}


# Public pages required by the Google OAuth consent screen.
def _legal_page(request: Request, page: str, title: str):
    from web_router import TEMPLATES
    return TEMPLATES.TemplateResponse(request, "legal.html", {
        "page": page,
        "title": title,
        "updated": "25 September 2026",
        "contact": os.getenv("SUPPORT_EMAIL", "kohtisun01@gmail.com"),
    })


@app.get("/privacy", response_class=HTMLResponse, include_in_schema=False)
def privacy_policy(request: Request):
    return _legal_page(request, "privacy", "Privacy Policy")


@app.get("/terms", response_class=HTMLResponse, include_in_schema=False)
def terms_of_service(request: Request):
    return _legal_page(request, "terms", "Terms of Service")

# 注册第一个admin账号（仅用于系统初始化，之后这个接口应该关掉或加保护）
@app.post("/setup/first-admin", response_model=schemas.UserResponse)
def create_first_admin(
    user: schemas.UserCreate,
    x_setup_token: str | None = Header(None),
    db: Session = Depends(get_db),
):
    existing_admin = db.query(models.User).filter(models.User.role == "admin").first()
    if existing_admin:
        raise HTTPException(status_code=400, detail="Admin already exists. Use /users to add more accounts.")
    setup_token = os.getenv("SETUP_TOKEN")
    if not setup_token:
        raise HTTPException(status_code=503, detail="Initial setup is disabled")
    if not x_setup_token or not secrets.compare_digest(x_setup_token, setup_token):
        raise HTTPException(status_code=401, detail="Invalid setup token")

    restaurant = models.Restaurant(name="Default Restaurant", slug="default-restaurant", is_active=True)
    db.add(restaurant)
    db.flush()
    new_user = models.User(
        restaurant_id=restaurant.id,
        username=user.username,
        password_hash=hash_password(user.password),
        role="admin",
        full_name=user.full_name,
        email_verified=True,
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    provision_restaurant_database(db, restaurant)
    return new_user

# Admin新增账号(cashier或其他admin)，必须登录且是admin身份
@app.post("/users", response_model=schemas.UserResponse)
def create_user(user: schemas.UserCreate, db: Session = Depends(get_db), current_admin: models.User = Depends(require_admin)):
    if user.role != "cashier":
        raise HTTPException(status_code=400, detail="Admins must register and verify their own email")
    username = user.username.strip()
    existing = db.query(models.User).execution_options(skip_tenant_scope=True).filter(
        func.lower(models.User.username) == username.lower()
    ).first()
    if existing:
        raise HTTPException(status_code=400, detail="Username already exists")

    new_user = models.User(
        restaurant_id=current_admin.restaurant_id,
        username=username,
        password_hash=hash_password(user.password),
        role=user.role,
        full_name=user.full_name
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    sync_user_shadow(db, new_user)
    return new_user

@app.post("/login")
def login(request: Request, credentials: schemas.LoginRequest, db: Session = Depends(get_db)):
    ip_key, account_key = login_keys(request, credentials.username)
    if not (login_limiter.allowed(ip_key) and account_login_limiter.allowed(account_key)):
        raise HTTPException(status_code=429, detail="Too many failed attempts. Try again in 15 minutes.")
    identifier = credentials.username.strip().lower()
    user = db.query(models.User).filter(or_(
        func.lower(models.User.username) == identifier,
        func.lower(models.User.email) == identifier,
    )).first()
    password_matches = (
        user is not None
        and verify_password(credentials.password, user.password_hash)
    )
    success = password_matches and user.is_active and not user.is_deleted

    db.add(models.LoginLog(
        user_id=user.id if user else None,
        restaurant_id=user.restaurant_id if user else None,
        username=credentials.username,
        success=success,
        ip_address=client_ip(request),
        user_agent=request.headers.get("user-agent"),
    ))
    db.commit()

    if password_matches and user.role == "admin" and user.email and not user.email_verified:
        login_limiter.record_failure(ip_key)
        account_login_limiter.record_failure(account_key)
        raise HTTPException(status_code=403, detail="Please verify your email before signing in")
    if not success:
        login_limiter.record_failure(ip_key)
        account_login_limiter.record_failure(account_key)
        raise HTTPException(status_code=401, detail="Invalid username or password")

    select_for_user(db, user)

    login_limiter.clear(ip_key)
    account_login_limiter.clear(account_key)
    access_token = create_access_token(data={
        "sub": user.username,
        "uid": user.id,
        "restaurant_id": user.restaurant_id,
        "role": user.role,
    })
    return {
        "access_token": access_token,
        "token_type": "bearer",
        "username": user.username,
        "role": user.role
    }

# 测试用：确认token和权限机制有没有生效
@app.get("/me")
def read_current_user(current_user: models.User = Depends(get_current_user)):
    return {
        "id": current_user.id,
        "username": current_user.username,
        "full_name": current_user.full_name,
        "role": current_user.role,
        "is_active": current_user.is_active,
        "permissions": current_user.permissions or {},
        "restaurant_id": current_user.restaurant_id,
        "restaurant_name": current_user.restaurant.name,
        "email": current_user.email,
        "email_verified": current_user.email_verified,
    }


@app.post("/admin/backup", tags=["Admin"])
def trigger_backup(
    db: Session = Depends(get_db),
    current_admin: models.User = Depends(require_admin),
):
    """Upload a backup of this admin's restaurant to its own Google Drive."""
    try:
        result = tenant_backup.run_tenant_backup(db, current_admin.restaurant)
        return result
    except DriveNotConnected as e:
        raise HTTPException(status_code=409, detail=str(e))
    except Exception:
        logger.exception("Google Drive upload failed for restaurant %s", current_admin.restaurant_id)
        raise HTTPException(status_code=500, detail="Upload to Google Drive failed. Please try again later.")


@app.post("/admin/monthly-report", tags=["Admin"])
def trigger_monthly_report(
    year: int,
    month: int,
    current_admin: models.User = Depends(require_admin),
):
    """手动触发月报生成并上传到本餐厅自己的 Google Drive（Admin only）"""
    if not (1 <= month <= 12):
        raise HTTPException(status_code=400, detail="month must be 1–12")
    try:
        result = monthly_report.run_monthly_report(year, month, current_admin.restaurant_id)
        return result
    except DriveNotConnected as e:
        raise HTTPException(status_code=409, detail=str(e))
    except Exception:
        logger.exception("Google Drive upload failed for restaurant %s", current_admin.restaurant_id)
        raise HTTPException(status_code=500, detail="Upload to Google Drive failed. Please try again later.")


@app.get("/admin/google-drive/status", tags=["Admin"])
def google_drive_status(current_admin: models.User = Depends(require_admin)):
    """Which Google account this restaurant's backups and reports go to."""
    return drive_connections.status(current_admin.restaurant)
