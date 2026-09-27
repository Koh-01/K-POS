import html
import os
import smtplib
from email.message import EmailMessage
from email.utils import formatdate, make_msgid, parseaddr


def email_delivery_configured() -> bool:
    return bool(os.getenv("SMTP_HOST", "").strip() and os.getenv("SMTP_FROM", "").strip())


def verification_url(token: str) -> str:
    base_url = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")
    return f"{base_url}/web/verify-email?token={token}"


def send_verification_email(recipient: str, full_name: str, restaurant_name: str, token: str) -> None:
    """Send one verification email using the deployment's SMTP account."""
    host = os.getenv("SMTP_HOST", "").strip()
    sender = os.getenv("SMTP_FROM", "").strip()
    if not host or not sender:
        raise RuntimeError("SMTP_HOST and SMTP_FROM must be configured")

    link = verification_url(token)
    message = EmailMessage()
    message["Subject"] = "Verify your K POS account"
    message["From"] = sender
    message["To"] = recipient
    # Standard headers many providers expect; missing ones hurt deliverability.
    message["Date"] = formatdate(localtime=True)
    sender_domain = parseaddr(sender)[1].rpartition("@")[2] or None
    message["Message-ID"] = make_msgid(domain=sender_domain)
    message.set_content(
        f"Hello {full_name},\n\n"
        f"Verify your K POS admin account for {restaurant_name}:\n{link}\n\n"
        "This link expires in 24 hours. If you did not create this account, ignore this email."
    )
    message.add_alternative(
        "<html><body>"
        f"<p>Hello {html.escape(full_name)},</p>"
        f"<p>Verify your K POS admin account for <strong>{html.escape(restaurant_name)}</strong>.</p>"
        f'<p><a href="{html.escape(link, quote=True)}" '
        'style="display:inline-block;padding:12px 20px;background:#2563eb;color:#fff;'
        'text-decoration:none;border-radius:8px">Verify email</a></p>'
        "<p>This link expires in 24 hours. If you did not create this account, ignore this email.</p>"
        "</body></html>",
        subtype="html",
    )

    port = int(os.getenv("SMTP_PORT", "587"))
    username = os.getenv("SMTP_USERNAME", "").strip()
    password = os.getenv("SMTP_PASSWORD", "")
    use_ssl = os.getenv("SMTP_USE_SSL", "false").lower() == "true"
    use_tls = os.getenv("SMTP_USE_TLS", "true").lower() == "true"

    smtp_class = smtplib.SMTP_SSL if use_ssl else smtplib.SMTP
    with smtp_class(host, port, timeout=20) as smtp:
        if not use_ssl and use_tls:
            smtp.starttls()
        if username:
            smtp.login(username, password)
        smtp.send_message(message)
