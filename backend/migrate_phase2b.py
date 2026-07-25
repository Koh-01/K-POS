from database import engine
from sqlalchemy import text

with engine.connect() as conn:
    # 1. 找 payments.order_id 上的 FK 约束名
    fk_result = conn.execute(text(
        "SELECT CONSTRAINT_NAME FROM information_schema.KEY_COLUMN_USAGE "
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'payments' "
        "AND COLUMN_NAME = 'order_id' AND REFERENCED_TABLE_NAME = 'orders'"
    ))
    fk_names = [row[0] for row in fk_result]
    print(f"FK constraints on order_id: {fk_names}")

    # 2. 删 FK
    for fk in fk_names:
        conn.execute(text(f"ALTER TABLE payments DROP FOREIGN KEY `{fk}`"))
        conn.commit()
        print(f"Dropped FK {fk}")

    # 3. 删 unique index（现在没有 FK 保护了）
    conn.execute(text("ALTER TABLE payments DROP INDEX `order_id`"))
    conn.commit()
    print("Dropped unique index on order_id")

    # 4. 建普通索引（FK 需要索引支持）
    conn.execute(text("CREATE INDEX idx_payments_order_id ON payments (order_id)"))
    conn.commit()
    print("Created regular index on order_id")

    # 5. 重建 FK
    conn.execute(text(
        "ALTER TABLE payments ADD CONSTRAINT fk_payments_order_id "
        "FOREIGN KEY (order_id) REFERENCES orders(id)"
    ))
    conn.commit()
    print("Re-added FK constraint")

print("Migration done — payments.order_id is now non-unique")
