"""
Phase 3 migration — creates the cash_records table.
Run once:  python migrate_phase3.py
"""
from database import engine
from sqlalchemy import text


def migrate():
    with engine.connect() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS cash_records (
                id          INT AUTO_INCREMENT PRIMARY KEY,
                type        VARCHAR(20)     NOT NULL,
                amount      DECIMAL(10,2)   NOT NULL,
                description VARCHAR(255)    NOT NULL,
                reference   VARCHAR(100),
                created_by  INT             NOT NULL,
                created_at  DATETIME        DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (created_by) REFERENCES users(id)
            )
        """))
        conn.commit()
        print("Phase 3 migration complete: cash_records table ready.")


if __name__ == "__main__":
    migrate()
