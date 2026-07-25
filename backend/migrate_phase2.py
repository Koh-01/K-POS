from database import engine, Base
from sqlalchemy import text
import models

Base.metadata.create_all(bind=engine)
print("New tables created OK")

with engine.connect() as conn:
    try:
        conn.execute(text(
            "ALTER TABLE payments ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'completed' AFTER payment_method"
        ))
        conn.commit()
        print("Added status column to payments")
    except Exception as e:
        if "Duplicate column" in str(e):
            print("status column already exists, skipping")
        else:
            raise
