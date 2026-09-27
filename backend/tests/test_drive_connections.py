import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from database import Base
import drive_connections
import models
import tenant_backup


def _session():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)()


def _admin(db):
    restaurant = models.Restaurant(name="Noodle House", slug="noodle-house", is_active=True)
    db.add(restaurant)
    db.flush()
    user = models.User(
        restaurant_id=restaurant.id, username="owner@example.com",
        password_hash="x", role="admin",
    )
    db.add(user)
    db.commit()
    return restaurant, user


def test_refresh_token_is_encrypted_at_rest():
    encrypted = drive_connections.encrypt_token("1//refresh-token")
    assert "refresh-token" not in encrypted
    assert drive_connections.decrypt_token(encrypted) == "1//refresh-token"


def test_undecryptable_token_requires_reconnect():
    with pytest.raises(drive_connections.DriveNotConnected):
        drive_connections.decrypt_token("not-a-fernet-token")


def test_oauth_state_is_bound_to_admin_restaurant_and_browser(monkeypatch):
    monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_ID", "client-id")
    monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_SECRET", "client-secret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://pos.example.com/")
    db = _session()
    _restaurant, user = _admin(db)

    url, nonce = drive_connections.build_authorization_url(user)
    assert "access_type=offline" in url
    assert "drive.file" in url
    assert "redirect_uri=https%3A%2F%2Fpos.example.com%2Fweb%2Fsettings%2Fgoogle-drive%2Fcallback" in url
    state = url.split("state=", 1)[1]

    assert drive_connections.verify_state(state, nonce, user)
    assert not drive_connections.verify_state(state, "other-browser", user)
    assert not drive_connections.verify_state(state, None, user)

    other = models.User(
        restaurant_id=user.restaurant_id, username="other@example.com",
        password_hash="x", role="admin",
    )
    db.add(other)
    db.commit()
    assert not drive_connections.verify_state(state, nonce, other)


def test_backup_without_connection_is_refused_and_not_sent_to_operator_drive(monkeypatch):
    db = _session()
    restaurant, _user = _admin(db)
    monkeypatch.setattr(
        "gdrive_backup._upload",
        lambda *_args, **_kw: pytest.fail("tenant data must not go to the operator Drive"),
    )
    with pytest.raises(drive_connections.DriveNotConnected):
        tenant_backup.run_tenant_backup(db, restaurant)


def test_backup_uploads_to_restaurants_own_folder(monkeypatch):
    monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_ID", "client-id")
    monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_SECRET", "client-secret")
    db = _session()
    restaurant, user = _admin(db)
    db.add(models.RestaurantDriveConnection(
        restaurant_id=restaurant.id,
        google_email="owner@gmail.com",
        refresh_token_encrypted=drive_connections.encrypt_token("refresh"),
        folder_id="folder-123",
        connected_by_user_id=user.id,
    ))
    db.commit()

    seen = {}
    monkeypatch.setattr(drive_connections, "_service", lambda creds: seen.setdefault("creds", creds))

    def _fake_upload(service, local_path, filename, folder_id, prune_prefix):
        seen.update(folder_id=folder_id, filename=filename, prune_prefix=prune_prefix)
        return "file-1"

    monkeypatch.setattr(drive_connections, "upload_with_service", _fake_upload)

    result = tenant_backup.run_tenant_backup(db, restaurant)

    assert result["drive_file_id"] == "file-1"
    assert seen["folder_id"] == "folder-123"
    assert seen["creds"].refresh_token == "refresh"
    assert seen["filename"].startswith("kpos_backup_noodle-house_")
    conn = db.query(models.RestaurantDriveConnection).one()
    assert conn.last_upload_at is not None
    assert conn.last_error is None
