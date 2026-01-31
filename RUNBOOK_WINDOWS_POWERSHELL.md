## Goal

Run the DuckDB integrity checks and the DuckDB↔Oracle “grand recon” from **PowerShell** in the environment like your screenshot:

- Working dir: `C:\PT8.61.09_Client_ORA\python`
- Python exe: `.\python` (a local `python.exe` in that folder)
- DuckDB file: `C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb`

---

## 0) One-time setup (Python packages)

From PowerShell:

```powershell
cd C:\PT8.61.09_Client_ORA\python

# Confirm Python works
.\python --version

# Install required packages (oracledb, duckdb, openpyxl)
.\python -m pip install -r .\bh_oracle_extracts\requirements.txt
```

If `pip` itself isn’t available:

```powershell
.\python -m ensurepip --upgrade
.\python -m pip install --upgrade pip
.\python -m pip install -r .\bh_oracle_extracts\requirements.txt
```

---

## 1) Sanity check: does the DuckDB have the expected tables?

This prints the table list (should include at least `po_header`, `goods_po_line`, `service_po_line`):

```powershell
.\python -c "import duckdb; con=duckdb.connect(r'C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb', read_only=True); print(con.execute('select table_name from information_schema.tables order by 1').fetchall()); con.close()"
```

If those tables are missing, the integrity checks and recon will fail — that means the extract/load step didn’t create them in this `.duckdb`.

---

## 2) Run DuckDB integrity checks (recommended)

This runs every statement in `duckdb_integrity_checks.sql` and prints up to 50 rows per statement:

```powershell
.\python .\bh_oracle_extracts\run_duckdb_sql_file.py "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb" ".\bh_oracle_extracts\duckdb_integrity_checks.sql" --read-only --limit 50
```

### Notes

- `--read-only` is safest (prevents accidental writes to the DuckDB file).
- `--limit 50` is just for printing; the queries still run fully.

---

## 3) Run *any* DuckDB SQL file / query text file

Your screenshot shows running a `.txt` query file. That’s OK: the runner just reads text and splits on semicolons.

```powershell
.\python .\bh_oracle_extracts\run_duckdb_sql_file.py "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb" ".\PO\qry6_Supp_invoice_Adjustments.txt" --read-only --limit 50
```

If the file contains multiple statements, separate them with semicolons (`;`).

---

## 4) Run “Grand Recon” (DuckDB extracts vs PeopleSoft Oracle)

### Option A (recommended): `duckdb_oracle_grand_recon_report.py`

This script **does not depend on parsing `grand_recon.sql` markers** — it reads directly from DuckDB tables and then queries Oracle for the same POs.

```powershell
.\python .\bh_oracle_extracts\duckdb_oracle_grand_recon_report.py `
  --duckdb "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb" `
  --oracle-user "<USER>" `
  --oracle-password "<PASSWORD>" `
  --oracle-connect "<HOST>:1521/<SERVICE>" `
  --asof-date 2026-01-15 `
  --output "C:\PT8.61.09_Client_ORA\python\PO\grand_recon_from_duckdb.xlsx"
```

Example Oracle connect string format:

- `vms-00-00-773.bhsi.com:1521/ERPWD1`

### Option B: `run_grand_recon.py` (uses `grand_recon.sql`)

Use this only if you specifically want the Excel tabs produced by the DuckDB section statements in `grand_recon.sql`.

```powershell
.\python .\bh_oracle_extracts\run_grand_recon.py `
  --duckdb "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb" `
  --oracle-user "<USER>" `
  --oracle-password "<PASSWORD>" `
  --oracle-connect "<HOST>:1521/<SERVICE>" `
  --asof-date 2026-01-15 `
  --sql-file ".\bh_oracle_extracts\grand_recon.sql" `
  --output "C:\PT8.61.09_Client_ORA\python\PO\grand_recon.xlsx"
```

---

## 5) If Excel writing fails (openpyxl not installed)

Both recon scripts support a CSV fallback:

- If `--output` ends with `.xlsx`, they require `openpyxl`.
- If `--output` is a **directory**, they write multiple `.csv` files instead.

Example:

```powershell
.\python .\bh_oracle_extracts\duckdb_oracle_grand_recon_report.py `
  --duckdb "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb" `
  --oracle-user "<USER>" `
  --oracle-password "<PASSWORD>" `
  --oracle-connect "<HOST>:1521/<SERVICE>" `
  --asof-date 2026-01-15 `
  --output "C:\PT8.61.09_Client_ORA\python\PO\grand_recon_csv"
```

---

## 6) Common issues & fixes

### DuckDB file not found

Error like:

- `IO Error: Cannot open file ... extracts.duckdb`

Fix: confirm the path exists:

```powershell
Test-Path "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb"
```

### Oracle connect / driver issues

If you see errors importing `oracledb`:

```powershell
.\python -m pip install oracledb
```

If your environment requires Oracle Instant Client (thick mode), install Instant Client and set `PATH` to include it. (Most setups work in thin mode, but some corporate networks/DB settings may require thick mode.)

### PowerShell line continuation

- Backtick `` ` `` is PowerShell’s line continuation (must be the last character on the line).
- If you prefer single-line commands, just remove the backticks and newlines.

