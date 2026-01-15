#!/usr/bin/env python3
"""
DuckDB query helper -> CSV

Examples:
  # List tables
  python duckdb_query.py "C:\\path\\extracts.duckdb" --list-tables

  # Export a table to CSV
  python duckdb_query.py "C:\\path\\extracts.duckdb" --table service_po_line --output out.csv

  # Export an arbitrary query to CSV
  python duckdb_query.py "C:\\path\\extracts.duckdb" --sql "select * from service_po_line limit 100" --output out.csv

  # Export query from a .sql file to CSV (avoids multiline shell quoting)
  python duckdb_query.py "C:\\path\\extracts.duckdb" --sql-file query.sql --output out.csv
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Optional

import duckdb


def _sql_string_literal(value: str) -> str:
    """Return a DuckDB SQL single-quoted string literal."""
    return "'" + value.replace("'", "''") + "'"


def _build_sql(table: Optional[str], sql: Optional[str], limit: Optional[int]) -> str:
    if sql:
        q = sql.strip().rstrip(";")
    elif table:
        q = f'SELECT * FROM "{table}"'
    else:
        raise ValueError("Provide either --sql or --table")

    if limit is not None and limit > 0:
        q = f"SELECT * FROM ({q}) q LIMIT {int(limit)}"
    return q


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a DuckDB query and export results to CSV")
    parser.add_argument("duckdb_path", help="Path to DuckDB database file (.duckdb)")

    group = parser.add_mutually_exclusive_group(required=False)
    group.add_argument("--sql", help="SQL to execute (wrap in quotes)")
    group.add_argument("--sql-file", dest="sql_file", help="Path to .sql file containing a single SELECT query")
    group.add_argument("--table", help="Table name to export (SELECT * FROM <table>)")

    parser.add_argument("--output", help="Output CSV file path")
    parser.add_argument("--delimiter", default=",", help="CSV delimiter (default: ,)")
    parser.add_argument("--list-tables", action="store_true", help="List tables and exit")
    parser.add_argument("--limit", type=int, default=None, help="Optional row limit for export")
    parser.add_argument("--read-only", action="store_true", help="Open the DuckDB file as read-only")

    args = parser.parse_args()

    duckdb_path = os.path.abspath(args.duckdb_path)
    con = duckdb.connect(duckdb_path, read_only=args.read_only)
    try:
        if args.list_tables:
            tables = con.execute("SHOW TABLES").fetchall()
            if not tables:
                print("(no tables found)")
                return 0
            for (t,) in tables:
                print(t)
            return 0

        sql_text = args.sql
        if args.sql_file:
            with open(args.sql_file, "r", encoding="utf-8") as f:
                sql_text = f.read()
        query = _build_sql(args.table, sql_text, args.limit)

        if not args.output:
            # Print to stdout (first 1000 rows max to avoid accidental huge output)
            preview_sql = _build_sql(args.table, args.sql, limit=min(args.limit or 1000, 1000))
            rows = con.execute(preview_sql).fetchall()
            for row in rows:
                print(row)
            print("\n(no --output provided, printed rows to stdout)")
            return 0

        out_path = os.path.abspath(args.output)
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

        # Use DuckDB's COPY for fast CSV export.
        # Note: paths are provided as SQL string literals.
        copy_sql = (
            "COPY (" + query + ") TO " + _sql_string_literal(out_path) +
            " (HEADER, DELIMITER " + _sql_string_literal(args.delimiter) + ")"
        )
        con.execute(copy_sql)

        print(f"✓ DuckDB file: {duckdb_path}")
        print(f"✓ Exported to: {out_path}")
        print("✓ Re-run query in DuckDB:")
        print(f"  duckdb {_sql_string_literal(duckdb_path)}")
        print(f"  -- then: {query};")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())

