#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional, Sequence, Tuple

import duckdb
from openpyxl import Workbook
from openpyxl.styles import Alignment, Font
from openpyxl.utils import get_column_letter

try:
    import oracledb
except ImportError:
    try:
        import cx_Oracle as oracledb  # type: ignore
    except ImportError:
        oracledb = None  # type: ignore


def read_text_with_fallback(path: str) -> str:
    encodings = ["utf-8", "cp1252", "latin-1", "iso-8859-1", "windows-1252"]
    last = None
    for enc in encodings:
        try:
            with open(path, "r", encoding=enc) as f:
                return f.read()
        except UnicodeDecodeError as e:
            last = e
    raise last  # type: ignore


def strip_trailing_semicolon(sql: str) -> str:
    s = sql.strip()
    if s.endswith(";"):
        s = s[:-1].rstrip()
    return s


def oracle_quote_ident(name: str) -> str:
    n = name.strip()
    if n.startswith('"') and n.endswith('"') and len(n) >= 2:
        return n
    return '"' + n.replace('"', '""') + '"'


def duckdb_quote_ident(name: str) -> str:
    n = name.strip()
    if n.startswith('"') and n.endswith('"') and len(n) >= 2:
        return n
    return '"' + n.replace('"', '""') + '"'


def sanitize_duckdb_column_name(col_name: str) -> str:
    """
    Must match oracle_extract.py logic so users can pass original Oracle column names
    and we can map to the DuckDB persisted column name.
    """
    name = (col_name or "").strip()
    if not name:
        name = "col"
    name = name.replace("*", "")
    name = re.sub(r"[^A-Za-z0-9_]", "_", name)
    name = re.sub(r"_+", "_", name).strip("_")
    if not name:
        name = "col"
    if name[0].isdigit():
        name = "col_" + name
    return name.lower()

def duckdb_table_columns(con, table_name: str) -> set:
    # PRAGMA table_info('t') returns: cid, name, type, notnull, dflt_value, pk
    rows = con.execute(f"PRAGMA table_info({duckdb_quote_ident(table_name)})").fetchall()
    return {r[1] for r in rows}

def resolve_duckdb_col(duck_cols: set, oracle_col: str, explicit_duckdb_col: Optional[str]) -> str:
    if explicit_duckdb_col:
        return explicit_duckdb_col
    # Prefer exact Oracle output column name (new oracle_extract.py keeps original names in DuckDB)
    if oracle_col in duck_cols:
        return oracle_col
    # Fallback: older runs may have sanitized names
    cand = sanitize_duckdb_column_name(oracle_col)
    if cand in duck_cols:
        return cand
    # Last resort: try without surrounding quotes if user provided quoted name
    unq = oracle_col.strip()
    if len(unq) >= 2 and unq.startswith('"') and unq.endswith('"'):
        unq = unq[1:-1]
        if unq in duck_cols:
            return unq
        cand2 = sanitize_duckdb_column_name(unq)
        if cand2 in duck_cols:
            return cand2
    return oracle_col

def _write_kv(ws, row: int, key: str, value: Any) -> int:
    ws.cell(row=row, column=1, value=key).font = Font(bold=True)
    ws.cell(row=row, column=2, value=value)
    return row + 1


def _autosize(ws, max_width: int = 60) -> None:
    for col in range(1, ws.max_column + 1):
        letter = get_column_letter(col)
        max_len = 0
        for cell in ws[letter]:
            if cell.value is None:
                continue
            max_len = max(max_len, len(str(cell.value)))
        ws.column_dimensions[letter].width = min(max(10, max_len + 2), max_width)


def _write_table(ws, start_row: int, headers: Sequence[str], rows: Sequence[Sequence[Any]]) -> None:
    header_font = Font(bold=True)
    for j, h in enumerate(headers, 1):
        c = ws.cell(row=start_row, column=j, value=h)
        c.font = header_font
        c.alignment = Alignment(wrap_text=True, vertical="top")
    for i, r in enumerate(rows, start_row + 1):
        for j, v in enumerate(r, 1):
            ws.cell(row=i, column=j, value=v)
    _autosize(ws)


@dataclass
class Metric:
    name: str
    oracle_value: Optional[float]
    duckdb_value: Optional[float]
    status: str
    note: str = ""


def _status_equal(a: Optional[float], b: Optional[float], tol: float = 0.0) -> str:
    if a is None or b is None:
        return "INFO"
    if tol == 0.0:
        return "PASS" if a == b else "FAIL"
    return "PASS" if abs(a - b) <= tol else "FAIL"


def _oracle_num_expr(col_ident: str) -> str:
    # Robust conversion for numeric-looking strings; otherwise NULL.
    return (
        "CASE "
        f"WHEN {col_ident} IS NULL THEN NULL "
        f"WHEN REGEXP_LIKE(TRIM({col_ident}), '^-?[0-9]+(\\.[0-9]+)?$') THEN TO_NUMBER(TRIM({col_ident})) "
        f"WHEN REGEXP_LIKE(TRIM({col_ident}), '^-?[0-9,]+(\\.[0-9]+)?$') THEN TO_NUMBER(REPLACE(TRIM({col_ident}), ',', '')) "
        "ELSE NULL END"
    )


def _duckdb_num_expr(col_ident: str) -> str:
    # DuckDB: try_cast handles failures to NULL; strip commas first.
    return f"try_cast(replace(trim({col_ident}), ',', '') AS DOUBLE)"


def oracle_connect_from_args(args) -> Any:
    if oracledb is None:
        raise RuntimeError("oracledb (or cx_Oracle) is required. Install with: pip install oracledb")

    if args.connection_string:
        return oracledb.connect(user=args.username, password=args.password, dsn=args.connection_string)

    if not args.host or not args.service_name:
        raise RuntimeError("Provide either -c/--connection-string OR (--host and --service-name).")
    dsn = oracledb.makedsn(host=args.host, port=args.port, service_name=args.service_name)
    return oracledb.connect(user=args.username, password=args.password, dsn=dsn)


def fetch_one_row(con, sql: str) -> Tuple[List[str], Tuple[Any, ...]]:
    cur = con.cursor()
    try:
        cur.execute(sql)
        row = cur.fetchone()
        cols = [d[0] for d in cur.description] if cur.description else []
        return cols, row if row is not None else tuple()
    finally:
        cur.close()


def fetch_rows(con, sql: str, limit: int) -> Tuple[List[str], List[Tuple[Any, ...]]]:
    cur = con.cursor()
    try:
        cur.execute(sql)
        cols = [d[0] for d in cur.description] if cur.description else []
        rows = cur.fetchmany(limit)
        return cols, rows
    finally:
        cur.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Reconcile Oracle extract SQL vs DuckDB table (amounts/qty/duplicates)")

    # DuckDB
    parser.add_argument("--duckdb", dest="duckdb_path", required=True, help="Path to DuckDB .duckdb file")
    parser.add_argument("--duckdb-table", required=True, help="DuckDB table name to reconcile against")
    parser.add_argument("--read-only", action="store_true", help="Open DuckDB read-only")

    # Oracle
    parser.add_argument("--oracle-sql", required=True, help="Path to the Oracle extract SQL file used to produce the table")
    parser.add_argument("-u", "--username", required=True, help="Oracle username")
    parser.add_argument("-p", "--password", required=True, help="Oracle password")
    conn_group = parser.add_mutually_exclusive_group(required=True)
    conn_group.add_argument("-c", "--connection-string", dest="connection_string", help="Oracle DSN, e.g. host:1521/service")
    conn_group.add_argument("--host", help="Oracle host (if not using -c)")
    parser.add_argument("--port", type=int, default=1521, help="Oracle port (default: 1521)")
    parser.add_argument("--service-name", dest="service_name", help="Oracle service name/SID (required if using --host)")

    # Column mappings (Oracle names are the output aliases in your extract SQL)
    parser.add_argument("--oracle-po-col", default="*No.", help='Oracle output column for PO number (default: "*No.")')
    parser.add_argument("--oracle-line-col", default="Line Number", help='Oracle output column for line number (default: "Line Number")')
    parser.add_argument("--oracle-amount-col", default="Extended Amount", help='Oracle output column for extended amount (default: "Extended Amount")')
    parser.add_argument("--oracle-qty-col", default="*Quantity", help='Oracle output column for quantity (default: "*Quantity")')

    # DuckDB columns (defaults match sanitized names created by oracle_extract.py)
    parser.add_argument("--duckdb-po-col", default=None, help='DuckDB PO column (default: sanitized from oracle-po-col)')
    parser.add_argument("--duckdb-line-col", default=None, help='DuckDB line column (default: sanitized from oracle-line-col)')
    parser.add_argument("--duckdb-amount-col", default=None, help='DuckDB amount column (default: sanitized from oracle-amount-col)')
    parser.add_argument("--duckdb-qty-col", default=None, help='DuckDB qty column (default: sanitized from oracle-qty-col)')

    # Rules / thresholds
    parser.add_argument("--max-qty", type=float, default=1_000_000, help="Flag qty greater than this (default: 1,000,000)")
    parser.add_argument("--max-amount", type=float, default=1_000_000_000, help="Flag amount greater than this (default: 1,000,000,000)")
    parser.add_argument("--sample", type=int, default=200, help="Max exception rows to sample per tab (default: 200)")

    # Output
    parser.add_argument("--output", required=True, help="Output Excel .xlsx path")

    args = parser.parse_args()

    duckdb_path = os.path.abspath(args.duckdb_path)
    duckdb_table = args.duckdb_table
    out_path = os.path.abspath(args.output)
    oracle_sql_path = os.path.abspath(args.oracle_sql)

    oracle_sql = strip_trailing_semicolon(read_text_with_fallback(oracle_sql_path))

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

    # Connect
    duck_con = duckdb.connect(duckdb_path, read_only=args.read_only)
    ora_con = oracle_connect_from_args(args)

    # Resolve DuckDB columns by introspecting the table
    duck_cols = duckdb_table_columns(duck_con, duckdb_table)
    duck_po = resolve_duckdb_col(duck_cols, args.oracle_po_col, args.duckdb_po_col)
    duck_line = resolve_duckdb_col(duck_cols, args.oracle_line_col, args.duckdb_line_col)
    duck_amt = resolve_duckdb_col(duck_cols, args.oracle_amount_col, args.duckdb_amount_col)
    duck_qty = resolve_duckdb_col(duck_cols, args.oracle_qty_col, args.duckdb_qty_col)

    wb = Workbook()
    wb.remove(wb.active)
    summary = wb.create_sheet("Summary")
    summary.append(["Generated at", datetime.now().strftime("%Y-%m-%d %H:%M:%S")])
    summary.append(["DuckDB", duckdb_path])
    summary.append(["DuckDB table", duckdb_table])
    summary.append(["Oracle SQL", oracle_sql_path])
    summary.append([])
    summary.append(["Metric", "Oracle", "DuckDB", "Status", "Note"])
    for c in summary[6]:
        c.font = Font(bold=True)

    metrics: List[Metric] = []

    def run_oracle_scalar(sql_body: str) -> Dict[str, Any]:
        cols, row = fetch_one_row(ora_con, sql_body)
        if not cols or not row:
            return {}
        return {cols[i]: row[i] for i in range(len(cols))}

    def run_duckdb_scalar(sql_body: str) -> Dict[str, Any]:
        cur = duck_con.execute(sql_body)
        row = cur.fetchone()
        cols = [d[0] for d in cur.description] if cur.description else []
        if not cols or row is None:
            return {}
        return {cols[i]: row[i] for i in range(len(cols))}

    # Build common idents
    o_po = oracle_quote_ident(args.oracle_po_col)
    o_line = oracle_quote_ident(args.oracle_line_col)
    o_amt = oracle_quote_ident(args.oracle_amount_col)
    o_qty = oracle_quote_ident(args.oracle_qty_col)

    d_po = duckdb_quote_ident(duck_po)
    d_line = duckdb_quote_ident(duck_line)
    d_amt = duckdb_quote_ident(duck_amt)
    d_qty = duckdb_quote_ident(duck_qty)

    # 1) Counts + sums
    ora_counts_sql = f"""
WITH src AS (
{oracle_sql}
)
SELECT
  COUNT(*) AS rows_cnt,
  COUNT(DISTINCT {o_po}) AS distinct_po_cnt,
  SUM({_oracle_num_expr(o_amt)}) AS sum_extended_amt,
  SUM({_oracle_num_expr(o_qty)}) AS sum_qty
FROM src
"""

    d_counts_sql = f"""
SELECT
  COUNT(*) AS rows_cnt,
  COUNT(DISTINCT {d_po}) AS distinct_po_cnt,
  SUM({_duckdb_num_expr(d_amt)}) AS sum_extended_amt,
  SUM({_duckdb_num_expr(d_qty)}) AS sum_qty
FROM {duckdb_quote_ident(duckdb_table)}
"""

    ora_vals = run_oracle_scalar(ora_counts_sql)
    d_vals = run_duckdb_scalar(d_counts_sql)

    def _as_float(v) -> Optional[float]:
        if v is None:
            return None
        try:
            return float(v)
        except Exception:
            return None

    for k in ["rows_cnt", "distinct_po_cnt", "sum_extended_amt", "sum_qty"]:
        a = _as_float(ora_vals.get(k))
        b = _as_float(d_vals.get(k))
        tol = 0.01 if k.startswith("sum_") else 0.0
        metrics.append(Metric(k, a, b, _status_equal(a, b, tol=tol)))

    # 2) Duplicates by (PO, line)
    ora_dups_cnt_sql = f"""
WITH src AS (
{oracle_sql}
)
SELECT COUNT(*) AS dup_groups
FROM (
  SELECT {o_po} AS po_no, {o_line} AS line_no, COUNT(*) AS cnt
  FROM src
  GROUP BY {o_po}, {o_line}
  HAVING COUNT(*) > 1
)
"""
    d_dups_cnt_sql = f"""
SELECT COUNT(*) AS dup_groups
FROM (
  SELECT {d_po} AS po_no, {d_line} AS line_no, COUNT(*) AS cnt
  FROM {duckdb_quote_ident(duckdb_table)}
  GROUP BY {d_po}, {d_line}
  HAVING COUNT(*) > 1
)
"""
    ora_dups = _as_float(run_oracle_scalar(ora_dups_cnt_sql).get("DUP_GROUPS"))
    d_dups = _as_float(run_duckdb_scalar(d_dups_cnt_sql).get("dup_groups"))
    metrics.append(Metric("dup_groups_po_line", ora_dups, d_dups, _status_equal(ora_dups, d_dups)))

    # 3) Rule checks (counts of “bad” rows)
    ora_bad_amt_sql = f"""
WITH src AS (
{oracle_sql}
)
SELECT
  SUM(CASE WHEN {_oracle_num_expr(o_amt)} <= 0 THEN 1 ELSE 0 END) AS amt_le_zero,
  SUM(CASE WHEN {_oracle_num_expr(o_amt)} > {args.max_amount} THEN 1 ELSE 0 END) AS amt_gt_max,
  SUM(CASE WHEN {_oracle_num_expr(o_qty)} < 0 THEN 1 ELSE 0 END) AS qty_lt_zero,
  SUM(CASE WHEN {_oracle_num_expr(o_qty)} > {args.max_qty} THEN 1 ELSE 0 END) AS qty_gt_max
FROM src
"""
    d_bad_amt_sql = f"""
SELECT
  SUM(CASE WHEN {_duckdb_num_expr(d_amt)} <= 0 THEN 1 ELSE 0 END) AS amt_le_zero,
  SUM(CASE WHEN {_duckdb_num_expr(d_amt)} > {args.max_amount} THEN 1 ELSE 0 END) AS amt_gt_max,
  SUM(CASE WHEN {_duckdb_num_expr(d_qty)} < 0 THEN 1 ELSE 0 END) AS qty_lt_zero,
  SUM(CASE WHEN {_duckdb_num_expr(d_qty)} > {args.max_qty} THEN 1 ELSE 0 END) AS qty_gt_max
FROM {duckdb_quote_ident(duckdb_table)}
"""
    ora_bad = run_oracle_scalar(ora_bad_amt_sql)
    d_bad = run_duckdb_scalar(d_bad_amt_sql)
    for k in ["amt_le_zero", "amt_gt_max", "qty_lt_zero", "qty_gt_max"]:
        a = _as_float(ora_bad.get(k.upper()))
        b = _as_float(d_bad.get(k))
        metrics.append(Metric(k, a, b, _status_equal(a, b)))

    # Write summary metrics
    for m in metrics:
        summary.append([m.name, m.oracle_value, m.duckdb_value, m.status, m.note])
    _autosize(summary, max_width=80)

    # Detail sheets with samples
    def add_sheet_with_query(sheet_name: str, description: str, oracle_sql_q: str, duckdb_sql_q: str) -> None:
        ws = wb.create_sheet(sheet_name[:31])
        r = 1
        r = _write_kv(ws, r, "Description", description)
        r = _write_kv(ws, r, "Oracle SQL", oracle_sql_path)
        r = _write_kv(ws, r, "DuckDB", duckdb_path)
        r = _write_kv(ws, r, "DuckDB table", duckdb_table)
        r += 1

        ws.cell(row=r, column=1, value="Oracle sample").font = Font(bold=True)
        r += 1
        o_cols, o_rows = fetch_rows(ora_con, oracle_sql_q, args.sample)
        if o_cols:
            _write_table(ws, r, o_cols, o_rows)
            r = ws.max_row + 2
        else:
            ws.cell(row=r, column=1, value="(no rows)")
            r += 2

        ws.cell(row=r, column=1, value="DuckDB sample").font = Font(bold=True)
        r += 1
        d_cur = duck_con.execute(duckdb_sql_q)
        d_cols = [d[0] for d in d_cur.description] if d_cur.description else []
        d_rows = d_cur.fetchmany(args.sample)
        if d_cols:
            _write_table(ws, r, d_cols, d_rows)
        else:
            ws.cell(row=r, column=1, value="(no rows)")
        _autosize(ws, max_width=80)

    # Duplicates sample
    add_sheet_with_query(
        "Duplicates",
        "Duplicate groups by (PO, Line Number) where COUNT(*) > 1",
        oracle_sql_q=f"""
WITH src AS (
{oracle_sql}
)
SELECT {o_po} AS po_no, {o_line} AS line_no, COUNT(*) AS cnt
FROM src
GROUP BY {o_po}, {o_line}
HAVING COUNT(*) > 1
ORDER BY cnt DESC
""",
        duckdb_sql_q=f"""
SELECT {d_po} AS po_no, {d_line} AS line_no, COUNT(*) AS cnt
FROM {duckdb_quote_ident(duckdb_table)}
GROUP BY {d_po}, {d_line}
HAVING COUNT(*) > 1
ORDER BY cnt DESC
""",
    )

    # Amount outliers sample
    add_sheet_with_query(
        "AmountOutliers",
        f'Rows with "{args.oracle_amount_col}" <= 0 OR > max ({args.max_amount})',
        oracle_sql_q=f"""
WITH src AS (
{oracle_sql}
)
SELECT {o_po} AS po_no, {o_line} AS line_no, {o_amt} AS extended_amount
FROM src
WHERE {_oracle_num_expr(o_amt)} <= 0 OR {_oracle_num_expr(o_amt)} > {args.max_amount}
""",
        duckdb_sql_q=f"""
SELECT {d_po} AS po_no, {d_line} AS line_no, {d_amt} AS extended_amount
FROM {duckdb_quote_ident(duckdb_table)}
WHERE {_duckdb_num_expr(d_amt)} <= 0 OR {_duckdb_num_expr(d_amt)} > {args.max_amount}
""",
    )

    # Qty outliers sample
    add_sheet_with_query(
        "QtyOutliers",
        f'Rows with "{args.oracle_qty_col}" < 0 OR > max ({args.max_qty})',
        oracle_sql_q=f"""
WITH src AS (
{oracle_sql}
)
SELECT {o_po} AS po_no, {o_line} AS line_no, {o_qty} AS qty
FROM src
WHERE {_oracle_num_expr(o_qty)} < 0 OR {_oracle_num_expr(o_qty)} > {args.max_qty}
""",
        duckdb_sql_q=f"""
SELECT {d_po} AS po_no, {d_line} AS line_no, {d_qty} AS qty
FROM {duckdb_quote_ident(duckdb_table)}
WHERE {_duckdb_num_expr(d_qty)} < 0 OR {_duckdb_num_expr(d_qty)} > {args.max_qty}
""",
    )

    wb.save(out_path)
    print(f"✓ Wrote reconciliation report: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

