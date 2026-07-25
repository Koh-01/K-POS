"""
Phase 4 migration — adds login_logs table and offline_ref column to orders.
Run once:  python migrate_phase4.py
"""
from database import engine
from sqlalchemy import text


def migrate():
    with engine.connect() as conn:
        # Login logs table
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS login_logs (
                id          INT AUTO_INCREMENT PRIMARY KEY,
                user_id     INT,
                username    VARCHAR(50) NOT NULL,
                success     BOOLEAN NOT NULL,
                ip_address  VARCHAR(45),
                user_agent  VARCHAR(255),
                created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
                INDEX idx_ll_username (username),
                INDEX idx_ll_created  (created_at),
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
            )
        """))
        print("login_logs table ready.")

        # offline_ref column on orders (idempotent)
        try:
            conn.execute(text("""
                ALTER TABLE orders
                ADD COLUMN offline_ref VARCHAR(100) UNIQUE NULL
            """))
            print("orders.offline_ref column added.")
        except Exception:
            print("orders.offline_ref already exists, skipping.")

        conn.commit()
        print("Phase 4 migration complete.")


if __name__ == "__main__":
    migrate()
