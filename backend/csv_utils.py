"""CSV writing that is safe to open in Excel / Google Sheets.

Spreadsheet apps treat a cell starting with = + - @ as a formula. That
breaks plain labels (shown as #ERROR!) and lets text typed into K POS
(product names, cash notes) run as a formula on the Admin's computer
("CSV injection"). Such cells are prefixed with ' so they stay text.
"""
import csv

_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")


def safe_cell(value):
    if not isinstance(value, str) or not value.startswith(_FORMULA_PREFIXES):
        return value
    try:
        float(value)          # "-45.00" is a number, keep it numeric
        return value
    except ValueError:
        return "'" + value


class _SafeWriter:
    def __init__(self, writer):
        self._writer = writer

    def writerow(self, row):
        return self._writer.writerow([safe_cell(cell) for cell in row])

    def writerows(self, rows):
        for row in rows:
            self.writerow(row)


def safe_csv_writer(fileobj, **kwargs):
    return _SafeWriter(csv.writer(fileobj, **kwargs))


def format_qty(value) -> str:
    """Quantity without trailing zeros: 3.000 -> "3", 1.250 -> "1.25"."""
    from decimal import Decimal
    return "{:f}".format(Decimal(str(value or 0)).normalize())
