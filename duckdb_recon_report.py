#!/usr/bin/env python3
"""
Generate an Excel reconciliation report from a DuckDB database.

- Runs each SQL statement from one or more .sql files
- Writes ONE Excel tab per statement (plus a Summary tab)

Example:
  python bh_oracle_extracts\\duckdb_recon_report.py ^
    "C:\\PT8.61.09_Client_ORA\\python\\PO\\extracts.duckdb" ^
    --sql-file "C:\\PT8.61.09_Client_ORA\\python\\bh_oracle_extracts\\duckdb_integrity_checks.sql" ^
    --output  "C:\\PT8.61.09_Client_ORA\\python\\PO\\recon_report.xlsx" ^
    --read-only
"""

from __future__ import annotations

import argparse
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime
from typing import List, Optional, Sequence, Tuple

import duckdb
from openpyxl import Workbook
from openpyxl.styles import Alignment, Font
from openpyxl.utils import get_column_letter


def split_sql_statements(sql_text: str) -> List[str]:
    """
    Split SQL text into statements on semicolons, ignoring semicolons inside:
    - single-quoted strings
    - double-quoted identifiers
    - line comments (-- ...)
    - block comments (/* ... */)
    """
    statements: List[str] = []
    buf: List[str] = []

    in_single = False
    in_double = False
    in_line_comment = False
    in_block_comment = False

    i = 0
    n = len(sql_text)

    while i < n:
        ch = sql_text[i]
        nxt = sql_text[i + 1] if i + 1 < n else ""

        # End line comment
        if in_line_comment:
            buf.append(ch)
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue

        # End block comment
        if in_block_comment:
            buf.append(ch)
            if ch == "*" and nxt == "/":
                buf.append(nxt)
                i += 2
                in_block_comment = False
            else:
                i += 1
            continue

        # Start comments (only when not inside quotes)
        if not in_single and not in_double:
            if ch == "-" and nxt == "-":
                buf.append(ch)
                buf.append(nxt)
                i += 2
                in_line_comment = True
                continue
            if ch == "/" and nxt == "*":
                buf.append(ch)
                buf.append(nxt)
                i += 2
                in_block_comment = True
                continue

        # Toggle quotes
        if ch == "'" and not in_double:
            buf.append(ch)
            # Handle escaped single quote inside string: ''
            if in_single and nxt == "'":
                buf.append(nxt)
                i += 2
                continue
            in_single = not in_single
            i += 1
            continue

        if ch == '"' and not in_single:
            buf.append(ch)
            # Handle escaped double quote identifier: ""
            if in_double and nxt == '"':
                buf.append(nxt)
                i += 2
                continue
            in_double = not in_double
            i += 1
            continue

        # Statement delimiter
        if ch == ";" and not in_single and not in_double:
            stmt = "".join(buf).strip()
            if stmt:
                statements.append(stmt)
            buf = []
            i += 1
            continue

        buf.append(ch)
        i += 1

    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements


def _sanitize_sheet_name(name: str) -> str:
    # Excel sheet name rules: <= 31 chars, cannot contain: []:*?/\
    name = re.sub(r"[\[\]:\*\?\/\\]+", "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    if not name:
        name = "sheet"
    return name[:31]


def _unique_sheet_name(existing: set, base: str) -> str:
    base = _sanitize_sheet_name(base)
    if base not in existing:
        existing.add(base)
        return base
    for i in range(2, 10_000):
        suffix = f"_{i}"
        cand = (base[: (31 - len(suffix))] + suffix) if len(base) + len(suffix) > 31 else (base + suffix)
        if cand not in existing:
            existing.add(cand)
            return cand
    raise RuntimeError("Unable to generate unique sheet name (too many collisions).")


def _statement_label(stmt: str, idx: int) -> str:
    # Prefer numbered comment labels like: -- 12) Something
    m = re.search(r"(?m)^\s*--\s*(\d+)\)\s*(.+?)\s*$", stmt)
    if m:
        return f"{m.group(1)}_{m.group(2)}"
    # Otherwise use first non-empty line
    for line in stmt.splitlines():
        s = line.strip()
        if s and not s.startswith("--"):
            s = re.sub(r"\s+", " ", s)
            return f"{idx}_{s[:60]}"
    return f"{idx}_check"


def _statement_preview(stmt: str, max_len: int = 300) -> str:
    s = " ".join([ln.strip() for ln in stmt.splitlines() if ln.strip()])
    s = re.sub(r"\s+", " ", s).strip()
    return s if len(s) <= max_len else (s[:max_len] + " ...")


@dataclass
class CheckResult:
    sheet_name: str
    label: str
    sql_preview: str
    status: str  # PASS / FAIL / INFO / ERROR
    rows_written: int
    runtime_ms: int
    error: Optional[str] = None


def _infer_status(cols: Sequence[str], rows: Sequence[Sequence[object]]) -> str:
    """
    Very small heuristic:
    - If empty result set => PASS for "exception" checks (missing/duplicates) else INFO
    - If any column named cnt/cnt_* and value > 0 => FAIL
    - If any rows returned for checks that look like missing/duplicate lists => FAIL
    - Otherwise INFO
    """
    if not rows:
        return "PASS"

    lc = [c.lower() for c in cols]
    cnt_cols = [i for i, c in enumerate(lc) if c == "cnt" or c.endswith("_cnt") or c.endswith("count")]
    for i in cnt_cols:
        for r in rows:
            v = r[i]
            try:
                if v is not None and float(v) > 0:
                    return "FAIL"
            except Exception:
                continue

    # If result contains key-like columns and has rows, it's usually a list of exceptions
    keyish = any(c in lc for c in ["po_no", "po_id", "*no.", "no", "po_no"])
    if keyish:
        return "FAIL"

    return "INFO"


def _write_table(ws, start_row: int, start_col: int, headers: Sequence[str], rows: Sequence[Sequence[object]]) -> None:
    header_font = Font(bold=True)
    for j, h in enumerate(headers, start_col):
        cell = ws.cell(row=start_row, column=j, value=h)
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    for i, r in enumerate(rows, start_row + 1):
        for j, v in enumerate(r, start_col):
            ws.cell(row=i, column=j, value=v)

    # Basic autosize (cap to a reasonable width)
    for j in range(start_col, start_col + len(headers)):
        max_len = 0
        col_letter = get_column_letter(j)
        for cell in ws[col_letter]:
            if cell.value is None:
                continue
            max_len = max(max_len, len(str(cell.value)))
        ws.column_dimensions[col_letter].width = min(max(10, max_len + 2), 60)


def main() -> int:
    parser = argparse.ArgumentParser(description="Create an Excel reconciliation report from DuckDB + SQL checks")
    parser.add_argument("duckdb_path", help="Path to DuckDB database file (.duckdb)")
    parser.add_argument("--sql-file", action="append", dest="sql_files", required=True,
                        help="Path to a .sql file (can be specified multiple times)")
    parser.add_argument("--output", required=True, help="Output .xlsx path")
    parser.add_argument("--read-only", action="store_true", help="Open DuckDB in read-only mode")
    parser.add_argument("--limit", type=int, default=5000, help="Max rows written per statement (default: 5000)")
    args = parser.parse_args()

    duckdb_path = os.path.abspath(args.duckdb_path)
    out_path = os.path.abspath(args.output)
    sql_files = [os.path.abspath(p) for p in (args.sql_files or [])]

    all_statements: List[Tuple[str, str]] = []  # (source_file, statement)
    for sf in sql_files:
        with open(sf, "r", encoding="utf-8") as f:
            sql_text = f.read()
        for stmt in split_sql_statements(sql_text):
            all_statements.append((sf, stmt))

    if not all_statements:
        raise SystemExit("No SQL statements found in the provided --sql-file inputs.")

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

    wb = Workbook()
    # remove default sheet
    wb.remove(wb.active)

    summary = wb.create_sheet("Summary")
    summary.append(["Generated at", datetime.now().strftime("%Y-%m-%d %H:%M:%S")])
    summary.append(["DuckDB", duckdb_path])
    summary.append(["SQL files", ", ".join(sql_files)])
    summary.append([])
    summary.append(["Sheet", "Status", "Rows (written)", "Runtime (ms)", "Source SQL", "Error", "SQL preview"])
    for cell in summary[5]:
        cell.font = Font(bold=True)

    con = duckdb.connect(duckdb_path, read_only=args.read_only)
    results: List[CheckResult] = []
    used_sheet_names: set = {"Summary"}

    try:
        for idx, (src_file, stmt) in enumerate(all_statements, 1):
            label = _statement_label(stmt, idx)
            sheet_name = _unique_sheet_name(used_sheet_names, label)
            ws = wb.create_sheet(sheet_name)

            ws["A1"] = "Check"
            ws["B1"] = label
            ws["A2"] = "Source SQL"
            ws["B2"] = src_file
            ws["A3"] = "SQL preview"
            ws["B3"] = _statement_preview(stmt)
            for a in ("A1", "A2", "A3"):
                ws[a].font = Font(bold=True)
                ws[a].alignment = Alignment(vertical="top")
            ws["B3"].alignment = Alignment(wrap_text=True, vertical="top")
            ws.row_dimensions[3].height = 45

            started = time.time()
            try:
                cur = con.execute(stmt)
                runtime_ms = int((time.time() - started) * 1000)

                if cur.description is None:
                    status = "INFO"
                    rows = []
                    cols = []
                else:
                    cols = [d[0] for d in cur.description]
                    fetched = cur.fetchmany(args.limit + 1)
                    truncated = len(fetched) > args.limit
                    rows = fetched[: args.limit]
                    status = _infer_status(cols, rows)

                    if truncated:
                        ws["A4"] = "NOTE"
                        ws["B4"] = f"Result truncated to first {args.limit} rows."
                        ws["A4"].font = Font(bold=True)

                ws["A5"] = "Status"
                ws["B5"] = status
                ws["A6"] = "Runtime (ms)"
                ws["B6"] = runtime_ms
                ws["A5"].font = Font(bold=True)
                ws["A6"].font = Font(bold=True)

                # Data table
                if cols:
                    _write_table(ws, start_row=8, start_col=1, headers=cols, rows=rows)
                    rows_written = len(rows)
                else:
                    ws["A8"] = "No result set returned (statement executed)."
                    rows_written = 0

                res = CheckResult(
                    sheet_name=sheet_name,
                    label=label,
                    sql_preview=_statement_preview(stmt),
                    status=status,
                    rows_written=rows_written,
                    runtime_ms=runtime_ms,
                )
            except Exception as e:
                runtime_ms = int((time.time() - started) * 1000)
                ws["A5"] = "Status"
                ws["B5"] = "ERROR"
                ws["A6"] = "Runtime (ms)"
                ws["B6"] = runtime_ms
                ws["A8"] = "Error"
                ws["B8"] = str(e)
                ws["A5"].font = Font(bold=True)
                ws["A6"].font = Font(bold=True)
                ws["A8"].font = Font(bold=True)
                ws["B8"].alignment = Alignment(wrap_text=True)
                res = CheckResult(
                    sheet_name=sheet_name,
                    label=label,
                    sql_preview=_statement_preview(stmt),
                    status="ERROR",
                    rows_written=0,
                    runtime_ms=runtime_ms,
                    error=str(e),
                )

            results.append(res)
            summary.append([res.sheet_name, res.status, res.rows_written, res.runtime_ms, src_file, res.error or "", res.sql_preview])

        # Make summary columns readable
        for col in range(1, 8):
            letter = get_column_letter(col)
            summary.column_dimensions[letter].width = [22, 10, 14, 12, 40, 40, 70][col - 1]
        summary["G6"].alignment = Alignment(wrap_text=True)

        wb.save(out_path)
        print(f"✓ Wrote Excel report: {out_path}")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())

