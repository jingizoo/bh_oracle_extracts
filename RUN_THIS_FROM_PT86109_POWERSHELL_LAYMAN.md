## What this guide is for

This is a **step-by-step, beginner-friendly** guide to run the Python extraction program from:

- `C:\PT8.61.09_Client_ORA\python`

Primary goal: run **one SQL file** and generate **one CSV extract**.

This guide also shows how to run **all SQL files** from a folder (one-by-one) and optionally load into DuckDB.

---

## The folder you showed in the screenshot

Your SQL files are in:

- `C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls`

Example files (from your screenshot):

- `PO_Header.sql`
- `Goods_PO_Line.sql`
- `Service_PO_Line.sql`
- `Service_Line_WorkTags.sql`
- `Goods_Line_Worktag.sql` (name in screenshot looks like this; adjust if different)

---

## Output: where the extract CSV goes

By default, `oracle_extract.py` writes the CSV **next to the SQL file**.

Example:

- SQL: `C:\...\PO\Final_copy_Sqls\PO_Header.sql`
- CSV: `C:\...\PO\Final_copy_Sqls\PO_Header.csv`

You can override the output filename/location with `-o "C:\path\file.csv"`.

---

## Step 1 — Open PowerShell

1) Click **Start**
2) Type **PowerShell**
3) Click **Windows PowerShell**

---

## Step 2 — Go to the correct folder

Copy/paste this into PowerShell:

```powershell
cd C:\PT8.61.09_Client_ORA\python
```

To confirm you are in the right place:

```powershell
pwd
```

You should see:

- `Path`
- `----`
- `C:\PT8.61.09_Client_ORA\python`

---

## Step 3 — Confirm Python runs (your environment uses `.\python`)

Run:

```powershell
.\python --version
```

You should see a Python version (example: `Python 3.11.x`).

If you get “file not found”, you are not in the right folder (go back to Step 2).

---

## Step 4 — Install required Python packages (one-time)

Run:

```powershell
.\python -m pip install -r .\bh_oracle_extracts\requirements.txt
```

If you get an error about pip not existing, run this once:

```powershell
.\python -m ensurepip --upgrade
.\python -m pip install --upgrade pip
.\python -m pip install -r .\bh_oracle_extracts\requirements.txt
```

---

## Step 5 — Run ONE SQL file (generates ONE CSV)

Pick one file from `C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls` and run it like this.

Replace:

- `<USER>` with your Oracle username
- `<PASSWORD>` with your Oracle password

### Example: `PO_Header.sql`

```powershell
.\python .\oracle_extract.py `
  "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\PO_Header.sql" `
  -u "<USER>" `
  -p "<PASSWORD>" `
  -c "vms-00-00-773.bhsi.com:1521/ERPWD1" `
  --quote-all `
  --excel-bom
```

After it finishes, check that this file exists:

- `C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\PO_Header.csv`

---

## Step 6 — Run EACH SQL file in `PO\Final_copy_Sqls` (one-by-one)

Use these commands (same pattern, different SQL path).

### `PO_Header.sql`

```powershell
.\python .\oracle_extract.py "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\PO_Header.sql" -u "<USER>" -p "<PASSWORD>" -c "vms-00-00-773.bhsi.com:1521/ERPWD1" --quote-all --excel-bom
```

### `Goods_PO_Line.sql`

```powershell
.\python .\oracle_extract.py "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\Goods_PO_Line.sql" -u "<USER>" -p "<PASSWORD>" -c "vms-00-00-773.bhsi.com:1521/ERPWD1" --quote-all --excel-bom
```

### `Service_PO_Line.sql`

```powershell
.\python .\oracle_extract.py "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\Service_PO_Line.sql" -u "<USER>" -p "<PASSWORD>" -c "vms-00-00-773.bhsi.com:1521/ERPWD1" --quote-all --excel-bom
```

### `Service_Line_WorkTags.sql`

```powershell
.\python .\oracle_extract.py "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\Service_Line_WorkTags.sql" -u "<USER>" -p "<PASSWORD>" -c "vms-00-00-773.bhsi.com:1521/ERPWD1" --quote-all --excel-bom
```

### `Goods_Line_Worktag.sql` (adjust filename if yours is different)

```powershell
.\python .\oracle_extract.py "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\Goods_Line_Worktag.sql" -u "<USER>" -p "<PASSWORD>" -c "vms-00-00-773.bhsi.com:1521/ERPWD1" --quote-all --excel-bom
```

---

## Optional — Also load into DuckDB at the same time

Add these flags to any command:

- `--duckdb "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb"`
- `--duckdb-table "<table_name>"`

Example (header → DuckDB table `po_header`):

```powershell
.\python .\oracle_extract.py `
  "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\PO_Header.sql" `
  -u "<USER>" `
  -p "<PASSWORD>" `
  -c "vms-00-00-773.bhsi.com:1521/ERPWD1" `
  --duckdb "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb" `
  --duckdb-table "po_header" `
  --quote-all `
  --excel-bom
```

---

## Optional — Use `--file-type` (custom header files)

Only use `--file-type` if you have header files present like:

- `headers_PO_HEADER.txt`
- `headers_GOODS_PO_LINE.txt`

These header files must be in the **same folder as the SQL file** (here: `PO\Final_copy_Sqls`).

If you do not have header files there, you can skip `--file-type` (it will still extract fine).

Example:

```powershell
.\python .\oracle_extract.py `
  "C:\PT8.61.09_Client_ORA\python\PO\Final_copy_Sqls\PO_Header.sql" `
  -u "<USER>" `
  -p "<PASSWORD>" `
  -c "vms-00-00-773.bhsi.com:1521/ERPWD1" `
  --file-type "PO_HEADER" `
  --quote-all `
  --excel-bom
```

---

## (Advanced) Run ALL SQLs using a manifest (batch / unattended)

If you later want unattended batch runs, keep reading below.

It will run **many Oracle SQL extract files** and load them into:

- `C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb`

It uses these files from this repo:

- `oracle_extract.py` (runs 1 SQL file)
- `bh_oracle_extracts\run_all_oracle_extracts.ps1` (runs ALL SQL files listed in a manifest)

---

## Before you start (you need these)

- **Oracle username**
- **Oracle password**
- **Oracle connect string**, example:
  - `vms-00-00-773.bhsi.com:1521/ERPWD1`
- A DuckDB file path (we use this one):
  - `C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb`

---

## Step 1 — Open PowerShell

1) Click **Start**
2) Type **PowerShell**
3) Click **Windows PowerShell**

---

## Step 2 — Go to the correct folder

Copy/paste this into PowerShell:

```powershell
cd C:\PT8.61.09_Client_ORA\python
```

To confirm you are in the right place:

```powershell
pwd
```

You should see:

- `Path`
- `----`
- `C:\PT8.61.09_Client_ORA\python`

---

## Step 3 — Confirm Python runs (your environment uses `.\python`)

Run:

```powershell
.\python --version
```

You should see a Python version (example: `Python 3.11.x`).

If you get “file not found”, you are not in the right folder (go back to Step 2).

---

## Step 4 — Install required Python packages (one-time)

Run:

```powershell
.\python -m pip install -r .\bh_oracle_extracts\requirements.txt
```

If you get an error about pip not existing, run this once:

```powershell
.\python -m ensurepip --upgrade
.\python -m pip install --upgrade pip
.\python -m pip install -r .\bh_oracle_extracts\requirements.txt
```

---

## Step 5 — Create the “manifest” file (list of SQLs to run)

The batch runner reads a CSV file that lists:

- which SQL files to run
- what `--file-type` to use (for headers)
- optional DuckDB table name

### 5A) Copy the example manifest

Run:

```powershell
Copy-Item ".\bh_oracle_extracts\extract_manifest_example.csv" ".\PO\extract_manifest.csv"
```

### 5B) Edit the manifest

Open it in Notepad:

```powershell
notepad ".\PO\extract_manifest.csv"
```

In that file, edit the rows:

- **sql_path**: full path to your `.sql` file
- **file_type**: the header type name (must match `headers_<FILE_TYPE>.txt` next to that SQL)
- **duckdb_table**: the DuckDB table name you want (recommended to keep stable)

Save and close Notepad.

---

## Step 6 — Run ALL SQL extracts into DuckDB (the main command)

Copy/paste this command, then replace:

- `<USER>` with your Oracle username
- `<PASSWORD>` with your Oracle password

```powershell
cd C:\PT8.61.09_Client_ORA\python

.\bh_oracle_extracts\run_all_oracle_extracts.ps1 `
  -PythonExe ".\python" `
  -OracleExtractPy ".\oracle_extract.py" `
  -OracleUser "<USER>" `
  -OraclePassword "<PASSWORD>" `
  -OracleConnect "vms-00-00-773.bhsi.com:1521/ERPWD1" `
  -DuckDB "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb" `
  -ManifestCsv ".\PO\extract_manifest.csv" `
  -ArraySize 50000 `
  -FetchSize 50000 `
  -ExcelBom `
  -QuoteAll `
  -StopOnError
```

### What you should see

For each file, you should see:

- `RUN: <file_type>`
- `✓ Connected to Oracle database as ...`
- `✓ Read SQL from ...`
- `✓ Extracted ... rows to ...csv`
- `✓ DuckDB table created/updated: <table>`
- `✓ OK`

If any extract fails, the script stops (because of `-StopOnError`).

---

## Step 7 — Quick checks (confirm DuckDB tables exist)

Run this to list tables inside the DuckDB file:

```powershell
.\python -c "import duckdb; con=duckdb.connect(r'C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb', read_only=True); print(con.execute('select table_name from information_schema.tables order by 1').fetchall()); con.close()"
```

Run this to check rowcounts for a table (example table name):

```powershell
.\python -c "import duckdb; con=duckdb.connect(r'C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb', read_only=True); print(con.execute('select count(*) from po_header').fetchone()); con.close()"
```

---

## Common problems (and what to do)

### “Header file not found for file type …”

This warning means the program did not find:

- `headers_<FILE_TYPE>.txt` or `headers_<FILE_TYPE>.csv`

…in the **same folder as the SQL file** you are running.

It will still run, but your CSV headers may not match your Workday/EIB expectation.

### “Cannot open file … extracts.duckdb”

Confirm the DuckDB file exists:

```powershell
Test-Path "C:\PT8.61.09_Client_ORA\python\PO\extracts.duckdb"
```

If it returns `False`, create the folder `C:\PT8.61.09_Client_ORA\python\PO\` and re-run (DuckDB file will be created automatically).

### “Access is denied” running the `.ps1`

Allow PowerShell scripts for the current session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Then re-run Step 6.

