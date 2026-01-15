# Oracle SQL Extract to CSV

A high-performance Python tool to extract data from Oracle databases to CSV files using SQL queries stored in text files.

## Features

- **Performance Optimized**: Uses batch fetching and optimized cursor settings for large datasets
- **Flexible Connection**: Supports both connection strings and host/port/service_name
- **Progress Tracking**: Shows real-time progress for long-running queries
- **Robust Error Handling**: Comprehensive error handling and cleanup
- **Configurable**: Customizable batch sizes, delimiters, and output options

## Installation

1. Install Python 3.7 or higher
2. Install required packages:
```bash
pip install -r requirements.txt
```

## Usage

### Basic Usage

```bash
# Using connection string
python oracle_extract.py query.sql -u username -p password -c "hostname:1521/service_name"

# Using host/port/service_name
python oracle_extract.py query.sql -u username -p password --host localhost --port 1521 --service-name ORCL
```

### Advanced Options

```bash
# Custom output file
python oracle_extract.py query.sql -u username -p password -c "hostname:1521/service_name" -o my_output.csv

# Custom delimiter (pipe-delimited)
python oracle_extract.py query.sql -u username -p password -c "hostname:1521/service_name" --delimiter "|"

# Performance tuning for very large datasets
python oracle_extract.py query.sql -u username -p password -c "hostname:1521/service_name" --arraysize 50000 --fetch-size 50000

# Disable progress output
python oracle_extract.py query.sql -u username -p password -c "hostname:1521/service_name" --no-progress

# With custom headers for specific file type
python oracle_extract.py query.sql -u username -p password -c "hostname:1521/service_name" --file-type PO_HEADER
```

## Command Line Arguments

### Required Arguments
- `sql_file`: Path to SQL file containing the query
- `-u, --username`: Oracle database username
- `-p, --password`: Oracle database password
- Connection method (one of):
  - `-c, --connection-string`: Full connection string (hostname:port/service_name)
  - `--host`: Database hostname (requires --service-name)

### Optional Arguments
- `-o, --output`: Output CSV file path (default: `<sql_file>.csv`)
- `--delimiter`: CSV delimiter (default: `,`)
- `--port`: Database port (default: `1521`)
- `--service-name`: Service name or SID (required if using --host)
- `--arraysize`: Number of rows to fetch at once (default: `10000`)
- `--fetch-size`: Batch size for fetching rows (default: `10000`)
- `--file-type`: File type identifier for custom headers (e.g., `PO_HEADER`). Looks for `headers_<FILE_TYPE>.txt` or `headers_<FILE_TYPE>.csv` in same directory as SQL file
- `--no-progress`: Disable progress output

## Performance Considerations

The tool includes several performance optimizations:

1. **Batch Fetching**: Uses `arraysize` and `fetchmany()` to fetch rows in batches, reducing memory usage and network round trips
2. **Optimized Cursor Settings**: Sets appropriate cursor arraysize for efficient data retrieval
3. **Streaming Output**: Writes CSV rows as they're fetched, avoiding loading entire result set into memory
4. **Configurable Batch Sizes**: Adjust `--arraysize` and `--fetch-size` based on your dataset size and network conditions

### Recommended Settings

- **Small datasets (< 100K rows)**: Default settings (arraysize=10000)
- **Medium datasets (100K - 1M rows)**: `--arraysize 20000 --fetch-size 20000`
- **Large datasets (> 1M rows)**: `--arraysize 50000 --fetch-size 50000`

## Example SQL File

Create a file `sample_query.sql`:

```sql
SELECT 
    employee_id,
    first_name,
    last_name,
    email,
    hire_date,
    salary
FROM employees
WHERE department_id = 50
ORDER BY salary DESC
```

Then run:
```bash
python oracle_extract.py sample_query.sql -u hr -p password -c "localhost:1521/XEPDB1"
```

This will create `sample_query.csv` with the results.

## Error Handling

The tool handles common errors gracefully:
- Connection failures
- SQL syntax errors
- File I/O errors
- Empty result sets

All errors are reported with clear messages to help diagnose issues.

## SQL Tuning Utility

The package includes `oracle_tune.py` for analyzing and tuning SQL queries using EXPLAIN PLAN.

### Basic Usage

```bash
# Generate EXPLAIN PLAN and analysis
python oracle_tune.py query.sql -u username -p password -c "hostname:1521/service_name"

# Custom output file
python oracle_tune.py query.sql -u username -p password -c "hostname:1521/service_name" -o plan.txt

# Display plan on console
python oracle_tune.py query.sql -u username -p password -c "hostname:1521/service_name" --console

# Detailed plan format
python oracle_tune.py query.sql -u username -p password -c "hostname:1521/service_name" --format "ALL"
```

### Features

- **EXPLAIN PLAN Generation**: Automatically generates Oracle EXPLAIN PLAN
- **Performance Analysis**: Identifies full table scans, high-cost operations, cartesian joins
- **Optimization Suggestions**: Provides specific recommendations for query improvement
- **Plan Format Options**: Supports all DBMS_XPLAN.DISPLAY format options

### Output

The tool generates a comprehensive analysis file containing:
- Complete EXPLAIN PLAN output
- Performance statistics (cost, table scans, index usage)
- Identified issues with severity levels
- Specific optimization recommendations

See `TUNING_RECOMMENDATIONS.md` for detailed tuning guidance and examples.

## Custom Headers

You can specify custom CSV headers by using the `--file-type` parameter. The tool will look for a header file in the same directory as your SQL file.

### Header File Naming Convention

Header files should be named: `headers_<FILE_TYPE>.txt` or `headers_<FILE_TYPE>.csv`

For example, if you use `--file-type PO_HEADER`, the tool will look for:
- `headers_PO_HEADER.txt` (preferred)
- `headers_PO_HEADER.csv` (fallback)

### Header File Format

Header files can be in one of three formats:

1. **One header per line** (recommended):
```
*No.
Add Only
Purchase Order ID
Submit
...
```

2. **Tab-separated on single line**:
```
*No.	Add Only	Purchase Order ID	Submit	...
```

3. **Comma-separated on single line**:
```
*No.,Add Only,Purchase Order ID,Submit,...
```

### Example

```bash
# Create headers_PO_HEADER.txt with your custom headers
# Then run:
python oracle_extract.py po_extract_query_tuned.sql -u username -p password -c "hostname:1521/service_name" --file-type PO_HEADER
```

The tool will validate that the number of custom headers matches the number of columns returned by your SQL query.

## Notes

- The tool uses UTF-8 encoding for both SQL files and CSV output
- Large result sets are processed in batches to avoid memory issues
- Database connections are properly closed even if errors occur
- Progress output can be disabled for automated scripts
- Custom headers must match the number of columns in your SQL query

