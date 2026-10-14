from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from database import Base
import models
import schemas
from settings_router import get_settings, update_settings


def test_order_card_categories_round_trip():
    db = sessionmaker(bind=create_engine("sqlite:///:memory:"))()
    Base.metadata.create_all(db.get_bind())
    db.add(models.Restaurant(id=1, name="R", slug="r", is_active=True))
    db.commit()

    assert get_settings(db).order_card_category_ids == []

    update_settings(schemas.AllSettingsUpdate(order_card_category_ids=[5, 2, 5]), db)
    assert get_settings(db).order_card_category_ids == [5, 2]

    update_settings(schemas.AllSettingsUpdate(store_name="Shop"), db)
    assert get_settings(db).order_card_category_ids == [5, 2]  # untouched

    update_settings(schemas.AllSettingsUpdate(order_card_category_ids=[]), db)
    assert get_settings(db).order_card_category_ids == []
