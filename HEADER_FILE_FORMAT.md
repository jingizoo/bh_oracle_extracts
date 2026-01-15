# Header File Format Guide

## Overview

Custom header files allow you to specify the exact column names for your CSV output, independent of the SQL query column aliases.

## File Naming Convention

Header files must follow this naming pattern:
```
headers_<FILE_TYPE>.txt
```
or
```
headers_<FILE_TYPE>.csv
```

Where `<FILE_TYPE>` is the value you pass to the `--file-type` parameter.

### Examples

- `--file-type PO_HEADER` → looks for `headers_PO_HEADER.txt` or `headers_PO_HEADER.csv`
- `--file-type VENDOR` → looks for `headers_VENDOR.txt` or `headers_VENDOR.csv`
- `--file-type INVOICE` → looks for `headers_INVOICE.txt` or `headers_INVOICE.csv`

## File Location

Header files are searched in the **same directory** as your SQL file.

For example:
- SQL file: `C:\Projects\queries\po_extract.sql`
- Header file: `C:\Projects\queries\headers_PO_HEADER.txt`

## Supported Formats

The tool automatically detects the format of your header file:

### Format 1: One Header Per Line (Recommended)

Each header on its own line:
```
*No.
Add Only
Purchase Orders For Updates
Purchase Order ID
Submit
Locked in Workday
```

**Advantages:**
- Easy to read and edit
- Clear structure
- Easy to add/remove headers

### Format 2: Tab-Separated (Single Line)

All headers on one line, separated by tabs:
```
*No.	Add Only	Purchase Orders For Updates	Purchase Order ID	Submit	Locked in Workday
```

**Advantages:**
- Compact
- Easy to copy from Excel

### Format 3: Comma-Separated (Single Line)

All headers on one line, separated by commas:
```
*No.,Add Only,Purchase Orders For Updates,Purchase Order ID,Submit,Locked in Workday
```

**Advantages:**
- Standard CSV format
- Easy to generate programmatically

## Validation

The tool will:
1. ✅ Validate that the header file exists
2. ✅ Validate that the number of headers matches the number of SQL columns
3. ⚠️ Warn if header file is not found (continues with SQL column names)
4. ❌ Error if header count doesn't match column count

## Example: PO_HEADER

Create `headers_PO_HEADER.txt`:

```
*No.
Add Only
Purchase Orders For Updates
Purchase Order ID
Submit
Locked in Workday
Document Number
Invoice Status
Payment Status
Receiving Status
Shipping Status
Tracking Status
*Company
*Supplier
Purchase Order Type
External PO Number
Order From Supplier Connection
*Document Date
Tax Amount
Freight Amount
Other Charges
Payment Terms
Override Payment Type
Procurement Credit Card
Shipping Terms
Shipping Method
Shipping Instruction
Due Date
Supplier Contract
Currency
Acknowledgement Expected
Default Tax Option
Default Tax Code
Issue Option
Buyer Is Employee
Buyer Worker ID
Bill To Contact Is Employee
Bill To Contact Worker ID
Bill To Contact Detail
Bill To Address
Bill To Address ID
Ship To Contact Is Employee
Ship To Contact Worker ID
Ship To Contact Detail
Ship To Address
Ship To Address ID
Document Link
Memo
Internal Memo
Prepaid
Prepayment Release Type
Expected Release Date
Frequency
Number of Prepayment Installments
Use Invoice Date
Specified Date
Use Prepaid Posting Rules for Receipt Accruals
Percent to Retain
Estimated Retention Release Date
XMLNAME 3rd Party Retention
Retention Memo
Down Payment Amount
Down Payment Percentage
Down Payment Memo
Procedure Date
Procedure
Procedure Number
Patient ID
Medical Record Number
Physician ID
Verified By
Supplier Representative
Additional Procedure Details
```

Then use it:
```bash
python oracle_extract.py po_extract_query_tuned.sql -u username -p password -c "hostname:1521/service_name" --file-type PO_HEADER
```

## Tips

1. **Keep header files in same directory as SQL files** - Makes it easier to manage related files
2. **Use descriptive file types** - Use clear, uppercase names like `PO_HEADER`, `VENDOR_MASTER`, etc.
3. **One header per line format** - Easiest to maintain and read
4. **Match SQL column order** - Headers must be in the same order as your SQL SELECT columns
5. **Version control** - Include header files in your version control system

## Troubleshooting

### Header file not found
```
⚠ Warning: Header file not found for file type 'PO_HEADER'
  Expected: headers_PO_HEADER.txt or headers_PO_HEADER.csv in C:\Projects\queries
⚠ Continuing without custom headers for file type 'PO_HEADER'
```
**Solution:** Create the header file in the same directory as your SQL file.

### Header count mismatch
```
✗ Error: Header count mismatch: 75 headers provided, but query returns 80 columns
```
**Solution:** Ensure your header file has the same number of headers as columns in your SQL SELECT statement.

### Empty header file
```
✗ Error: Header file is empty: headers_PO_HEADER.txt
```
**Solution:** Add headers to the file or remove the `--file-type` parameter.

