# Find Resource Tables Stored Procedure

This package provides stored procedures/functions to find tables containing specific `resource_id` and `business_unit`/`business_unit_pc` values.

## Files

1. **`find_resource_tables.sql`** - Two stored procedures:
   - `find_resource_tables` - Uses DBMS_OUTPUT for results
   - `find_resource_tables_cursor` - Returns results via REF CURSOR

2. **`find_resource_tables_simple.sql`** - Function-based approach:
   - `find_resource_tables_func` - Returns results as a pipelined table function

## Installation

Run the SQL file(s) in your Oracle database:

```sql
-- For procedures
@find_resource_tables.sql

-- For function (simpler, recommended)
@find_resource_tables_simple.sql
```

## Usage

### Method 1: Function (Recommended - Easiest to Use)

```sql
-- Search in current schema
SELECT * FROM TABLE(find_resource_tables_func('RESOURCE123', 'BU001'));

-- Search in specific schema
SELECT * FROM TABLE(find_resource_tables_func('RESOURCE123', 'BU001', 'SCHEMA_NAME'));

-- Search all schemas (requires privileges)
SELECT * FROM TABLE(find_resource_tables_func('RESOURCE123', 'BU001', NULL, 'Y'));
```

### Method 2: Procedure with DBMS_OUTPUT

```sql
SET SERVEROUTPUT ON;
EXEC find_resource_tables('RESOURCE123', 'BU001', USER, 'N');
```

### Method 3: Procedure with Cursor (For Applications)

```sql
DECLARE
  v_cursor SYS_REFCURSOR;
  v_schema VARCHAR2(128);
  v_table VARCHAR2(128);
  v_bu_col VARCHAR2(128);
  v_count NUMBER;
BEGIN
  find_resource_tables_cursor('RESOURCE123', 'BU001', USER, 'N', v_cursor);
  LOOP
    FETCH v_cursor INTO v_schema, v_table, v_bu_col, v_count;
    EXIT WHEN v_cursor%NOTFOUND;
    DBMS_OUTPUT.PUT_LINE(v_schema || '.' || v_table || ' - ' || v_bu_col || ' - ' || v_count);
  END LOOP;
  CLOSE v_cursor;
END;
/
```

## Parameters

- **`p_resource_id`** (required): The resource_id value to search for
- **`p_business_unit`** (required): The business_unit or business_unit_pc value to search for
- **`p_schema_name`** (optional, default: USER): Schema to search in. Ignored if `p_include_all_schemas = 'Y'`
- **`p_include_all_schemas`** (optional, default: 'N'): 
  - 'N' = Search only in specified schema
  - 'Y' = Search all schemas (requires appropriate privileges)

## What It Does

1. **Finds matching tables**: Searches for tables that have:
   - A column named `RESOURCE_ID`
   - AND either `BUSINESS_UNIT` OR `BUSINESS_UNIT_PC` column (or both)

2. **Checks for values**: For each matching table, executes:
   ```sql
   SELECT COUNT(*) FROM schema.table_name
   WHERE resource_id = :p_resource_id 
     AND (business_unit = :p_business_unit OR business_unit_pc = :p_business_unit)
   ```

3. **Returns results**: Shows which tables contain rows matching both criteria

## Output Columns

- **schema_name**: Schema containing the table
- **table_name**: Name of the table
- **business_unit_column**: Which column matched ('business_unit' or 'business_unit_pc')
- **row_count**: Number of matching rows found

## Performance Notes

- The procedure queries `ALL_TAB_COLUMNS` data dictionary view
- For each matching table, it executes a dynamic COUNT query
- Large schemas with many tables may take time to process
- Consider adding indexes on `resource_id` and `business_unit`/`business_unit_pc` columns for better performance

## Security

- Requires `SELECT` privilege on tables being searched
- To search all schemas, requires access to `ALL_TAB_COLUMNS` view
- The procedure uses dynamic SQL, so ensure proper security practices

## Example Output

```
SCHEMA_NAME    TABLE_NAME              BUSINESS_UNIT_COLUMN  ROW_COUNT
-------------- ----------------------- --------------------- ---------
HR             EMPLOYEE_ASSIGNMENT     business_unit         5
HR             RESOURCE_ALLOCATION     business_unit_pc      2
FIN            PROJECT_RESOURCES       business_unit         1
```

## Troubleshooting

**No results found:**
- Verify the resource_id and business_unit values exist
- Check that tables have the required columns
- Ensure you have SELECT privileges on the tables

**Permission errors:**
- Grant SELECT on target tables
- For all schemas search, ensure access to ALL_TAB_COLUMNS

**Performance issues:**
- Add indexes on resource_id and business_unit columns
- Consider limiting schema search scope
- Use function version for better query optimization


