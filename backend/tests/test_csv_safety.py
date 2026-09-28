import io

from csv_utils import safe_cell, safe_csv_writer
import monthly_report


def test_formula_like_text_is_neutralised():
    assert safe_cell("=HYPERLINK(\"http://evil\")") == "'=HYPERLINK(\"http://evil\")"
    assert safe_cell("+SUM(A1)") == "'+SUM(A1)"
    assert safe_cell("@SUM(A1)") == "'@SUM(A1)"
    assert safe_cell("-free drinks") == "'-free drinks"


def test_numbers_and_plain_text_unchanged():
    assert safe_cell("-45.00") == "-45.00"
    assert safe_cell("12.50") == "12.50"
    assert safe_cell("Teh Tarik") == "Teh Tarik"
    assert safe_cell(3) == 3
    assert safe_cell(None) is None


def test_writer_applies_to_every_cell():
    out = io.StringIO()
    safe_csv_writer(out).writerow(["=1+1", "ok", "-3"])
    assert out.getvalue().strip() == "'=1+1,ok,-3"


def test_monthly_report_has_no_formula_cells(monkeypatch):
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker
    from database import Base

    db = sessionmaker(bind=create_engine("sqlite:///:memory:"))()
    Base.metadata.create_all(db.get_bind())
    text = monthly_report._build_csv(2026, 8, db)
    for line in text.splitlines():
        assert not line.startswith(("=", "+", "@")), line


def test_format_qty():
    from csv_utils import format_qty
    assert format_qty("3.000") == "3"
    assert format_qty("1.250") == "1.25"
    assert format_qty("100.000") == "100"
    assert format_qty(None) == "0"
