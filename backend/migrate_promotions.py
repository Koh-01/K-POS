"""
Promotions migration — creates promotions table and adds promotion_id to payments.
Run once:  python migrate_promotions.py
"""
from database import engine
from sqlalchemy import text


def migrate():
    with engine.connect() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS promotions (
                id          INT AUTO_INCREMENT PRIMARY KEY,
                name        VARCHAR(100) NOT NULL,
                type        VARCHAR(30) NOT NULL,
                conditions  JSON NOT NULL,
                starts_at   DATETIME NULL,
                ends_at     DATETIME NULL,
                usage_count INT NOT NULL DEFAULT 0,
                is_active   BOOLEAN NOT NULL DEFAULT 1,
                is_deleted  BOOLEAN NOT NULL DEFAULT 0,
                created_by  INT NOT NULL,
                created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                INDEX idx_promo_type   (type),
                INDEX idx_promo_active (is_active),
                FOREIGN KEY (created_by) REFERENCES users(id)
            )
        """))
        print("promotions table ready.")

        try:
            conn.execute(text("""
                ALTER TABLE payments
                ADD COLUMN promotion_id INT NULL,
                ADD CONSTRAINT fk_payment_promotion
                    FOREIGN KEY (promotion_id) REFERENCES promotions(id)
            """))
            print("payments.promotion_id column added.")
        except Exception:
            print("payments.promotion_id already exists, skipping.")

        conn.commit()
        print("Promotions migration complete.")


if __name__ == "__main__":
    migrate()
