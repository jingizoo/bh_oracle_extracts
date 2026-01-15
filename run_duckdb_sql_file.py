#!/usr/bin/env python3
"""
Run a multi-statement SQL file against a DuckDB database (no DuckDB CLI needed).

Examples:
  python run_duckdb_sql_file.py "C:\\PT8.61.09_Client_ORA\\python\\PO\\extracts.duckdb" "C:\\PT8.61.09_Client_ORA\\python\\bh_oracle_extracts\\duckdb_integrity_checks.sql"

  # Limit printed rows per statement
  python run_duckdb_sql_file.py "C:\\path\\extracts.duckdb" "C:\\path\\checks.sql" --limit 20
"""

from __future__ import annotations

import argparse
import os
from typing import List

import duckdb


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Execute a multi-statement SQL file against DuckDB")
    parser.add_argument("duckdb_path", help="Path to DuckDB database file (.duckdb)")
    parser.add_argument("sql_file", help="Path to .sql file containing one or more statements")
    parser.add_argument("--limit", type=int, default=50, help="Max rows printed per statement (default: 50)")
    parser.add_argument("--read-only", action="store_true", help="Open DuckDB database read-only")
    args = parser.parse_args()

    duckdb_path = os.path.abspath(args.duckdb_path)
    sql_path = os.path.abspath(args.sql_file)

    with open(sql_path, "r", encoding="utf-8") as f:
        sql_text = f.read()

    statements = split_sql_statements(sql_text)
    if not statements:
        print("No SQL statements found.")
        return 0

    con = duckdb.connect(duckdb_path, read_only=args.read_only)
    try:
        for idx, stmt in enumerate(statements, 1):
            print(f"\n--- Statement {idx}/{len(statements)} ---")
            preview = " ".join(stmt.split())
            if len(preview) > 200:
                preview = preview[:200] + "..."
            print(preview)

            cur = con.execute(stmt)
            # If the statement produces a result set, print up to --limit rows
            if cur.description is not None:
                rows = cur.fetchmany(max(args.limit, 0))
                cols = [d[0] for d in cur.description]
                print(f"Columns: {cols}")
                for r in rows:
                    print(r)
                if args.limit and len(rows) == args.limit:
                    print(f"(showing first {args.limit} rows)")
            else:
                # Non-query statement; show rowcount if available
                try:
                    print(f"OK (rowcount={cur.rowcount})")
                except Exception:
                    print("OK")

        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())

