from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session
from sqlalchemy import text
from pathlib import Path
from contextlib import asynccontextmanager
from apscheduler.schedulers.background import BackgroundScheduler
from database import get_db
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
import gdrive_backup
import monthly_report
from web_router import router as web_router, WebLoginRequired

_scheduler = BackgroundScheduler()


def _scheduled_backup():
    try:
        result = gdrive_backup.run_backup()
        print(f"[backup] {result['filename']} uploaded → {result['drive_file_id']}")
    except Exception as e:
        print(f"[backup] ERROR: {e}")


def _scheduled_monthly_report():
    from datetime import datetime
    now = datetime.now()
    # Report covers the previous month
    if now.month == 1:
        year, month = now.year - 1, 12
    else:
        year, month = now.year, now.month - 1
    try:
        result = monthly_report.run_monthly_report(year, month)
        print(f"[monthly-report] {result['filename']} uploaded → {result['drive_file_id']}")
    except Exception as e:
        print(f"[monthly-report] ERROR: {e}")


def _run_migrations():
    from database import engine
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
    ]
    try:
        with engine.connect() as conn:
            for check_sql, alter_sql in migrations:
                result = conn.execute(text(check_sql))
                if result.scalar() == 0:
                    conn.execute(text(alter_sql))
                    conn.commit()
                    print(f"[migrate] {alter_sql}")
    except Exception as e:
        print(f"[migrate] WARNING: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _run_migrations()
    _scheduler.add_job(_scheduled_backup, "cron", hour=12, minute=0, id="daily_backup")
    _scheduler.add_job(_scheduled_monthly_report, "cron", day=1, hour=1, minute=0, id="monthly_report")
    _scheduler.start()
    yield
    _scheduler.shutdown()


app = FastAPI(title="POS System API", lifespan=lifespan)

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
app.include_router(web_router)

@app.exception_handler(WebLoginRequired)
async def _web_login_required(request: Request, exc: WebLoginRequired):
    return RedirectResponse(url="/web/login", status_code=303)

@app.get("/")
def read_root():
    return {"message": "POS System API is running"}

@app.get("/db-check")
def db_check(db: Session = Depends(get_db)):
    result = db.execute(text("SELECT 1"))
    return {"database": "connected", "result": result.scalar()}

# 注册第一个admin账号（仅用于系统初始化，之后这个接口应该关掉或加保护）
@app.post("/setup/first-admin", response_model=schemas.UserResponse)
def create_first_admin(user: schemas.UserCreate, db: Session = Depends(get_db)):
    existing_admin = db.query(models.User).filter(models.User.role == "admin").first()
    if existing_admin:
        raise HTTPException(status_code=400, detail="Admin already exists. Use /users to add more accounts.")

    new_user = models.User(
        username=user.username,
        password_hash=hash_password(user.password),
        role="admin",
        full_name=user.full_name
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    return new_user

# Admin新增账号(cashier或其他admin)，必须登录且是admin身份
@app.post("/users", response_model=schemas.UserResponse)
def create_user(user: schemas.UserCreate, db: Session = Depends(get_db), current_admin: models.User = Depends(require_admin)):
    existing = db.query(models.User).filter(models.User.username == user.username).first()
    if existing:
        raise HTTPException(status_code=400, detail="Username already exists")

    new_user = models.User(
        username=user.username,
        password_hash=hash_password(user.password),
        role=user.role,
        full_name=user.full_name
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    return new_user

@app.post("/login")
def login(request: Request, credentials: schemas.LoginRequest, db: Session = Depends(get_db)):
    user = db.query(models.User).filter(models.User.username == credentials.username).first()
    success = (
        user is not None
        and user.is_active
        and verify_password(credentials.password, user.password_hash)
    )

    db.add(models.LoginLog(
        user_id=user.id if user else None,
        username=credentials.username,
        success=success,
        ip_address=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    ))
    db.commit()

    if not success:
        raise HTTPException(status_code=401, detail="Invalid username or password")

    access_token = create_access_token(data={"sub": user.username, "role": user.role})
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
    }


@app.post("/admin/backup", tags=["Admin"])
def trigger_backup(_=Depends(require_admin)):
    """手动触发一次 Google Drive 备份（Admin only）"""
    try:
        result = gdrive_backup.run_backup()
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/monthly-report", tags=["Admin"])
def trigger_monthly_report(
    year: int,
    month: int,
    _=Depends(require_admin),
):
    """手动触发月报生成并上传 Google Drive（Admin only）"""
    if not (1 <= month <= 12):
        raise HTTPException(status_code=400, detail="month must be 1–12")
    try:
        result = monthly_report.run_monthly_report(year, month)
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))