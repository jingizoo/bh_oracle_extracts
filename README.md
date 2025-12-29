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

## Notes

- The tool uses UTF-8 encoding for both SQL files and CSV output
- Large result sets are processed in batches to avoid memory issues
- Database connections are properly closed even if errors occur
- Progress output can be disabled for automated scripts

