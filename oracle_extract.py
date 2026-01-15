#!/usr/bin/env python3
"""
Oracle SQL Extract to CSV and Database Tables
Reads a SQL query from a text file and generates a CSV extract with performance optimizations.
Optionally writes data to a DuckDB table for local persistence.
"""

import argparse
import csv
import sys
import os
import re
from datetime import datetime
from typing import Optional, List, Tuple

try:
    import oracledb
except ImportError:
    try:
        import cx_Oracle as oracledb
    except ImportError:
        print("Error: oracledb or cx_Oracle package is required.")
        print("Install with: pip install oracledb")
        sys.exit(1)

try:
    import duckdb
except ImportError:
    duckdb = None


class OracleExtractor:
    """Extract data from Oracle database to CSV and optionally persist results to DuckDB."""
    
    def __init__(self, connection_string: str, username: str, password: str, 
                 host: str = None, port: int = 1521, service_name: str = None,
                 arraysize: int = 10000, fetch_size: int = 10000):
        """
        Initialize Oracle extractor.
        
        Args:
            connection_string: Full connection string (tnsnames format) or None for source DB
            username: Source database username
            password: Source database password
            host: Source database host (if not using connection_string)
            port: Source database port (default: 1521)
            service_name: Source service name or SID (if not using connection_string)
            arraysize: Number of rows to fetch at once (default: 10000)
            fetch_size: Buffer size for fetching (default: 10000)
        """
        self.username = username
        self.password = password
        self.connection_string = connection_string
        self.host = host
        self.port = port
        self.service_name = service_name
        self.arraysize = arraysize
        self.fetch_size = fetch_size
        self.connection = None
        
    def connect(self):
        """Establish connection to Oracle database."""
        try:
            if self.connection_string:
                # Use connection string (TNS names format)
                self.connection = oracledb.connect(
                    user=self.username,
                    password=self.password,
                    dsn=self.connection_string
                )
            else:
                # Use host/port/service_name
                dsn = oracledb.makedsn(
                    host=self.host,
                    port=self.port,
                    service_name=self.service_name
                )
                self.connection = oracledb.connect(
                    user=self.username,
                    password=self.password,
                    dsn=dsn
                )
            
            print(f"✓ Connected to Oracle database as {self.username}")
            return True
        except Exception as e:
            print(f"✗ Connection error: {str(e)}")
            return False
    
    def disconnect(self):
        """Close database connection."""
        if self.connection:
            self.connection.close()
            print("✓ Source database connection closed")

    def _sanitize_duckdb_table_name(self, name: str) -> str:
        """Convert a name to a safe DuckDB table identifier."""
        name = os.path.splitext(os.path.basename(name))[0]
        name = re.sub(r'[^A-Za-z0-9_]', '_', name)
        if not name:
            name = "extract"
        if name[0].isdigit():
            name = "t_" + name
        # DuckDB supports longer identifiers, but keep it reasonable
        return name.lower()

    def persist_csv_to_duckdb(self, duckdb_path: str, table_name: str, csv_path: str,
                              delimiter: str = ',', skip_rows: int = 0) -> tuple[str, int]:
        """
        Create/replace a DuckDB table from the generated CSV.

        Notes:
        - If your CSV contains multiple header rows, pass skip_rows = (header_rows_count - 1)
          so the last header row becomes the CSV header.
        """
        if duckdb is None:
            raise Exception("duckdb package is not installed. Install with: pip install duckdb")

        safe_table = self._sanitize_duckdb_table_name(table_name)
        con = None
        try:
            con = duckdb.connect(duckdb_path)
            # Use read_csv_auto so DuckDB infers types. header=true reads column names.
            # skip skips the initial non-header rows (e.g., title rows).
            con.execute(
                f'CREATE OR REPLACE TABLE "{safe_table}" AS '
                f"SELECT * FROM read_csv_auto(?, delim=?, header=true, skip=?)",
                [csv_path, delimiter, skip_rows],
            )
            loaded_rows = con.execute(f'SELECT COUNT(*) FROM "{safe_table}"').fetchone()[0]
        finally:
            if con is not None:
                con.close()

        return safe_table, int(loaded_rows)
    
    def _read_file_with_encoding_fallback(self, file_path: str) -> Tuple[str, str]:
        """
        Read a file trying multiple encodings.
        
        Args:
            file_path: Path to the file to read
            
        Returns:
            Tuple of (file_content, encoding_used)
            
        Raises:
            FileNotFoundError: If file doesn't exist
            UnicodeDecodeError: If all encodings fail
        """
        # Try encodings in order of preference
        encodings = ['utf-8', 'cp1252', 'latin-1', 'iso-8859-1', 'windows-1252']
        
        last_error = None
        for encoding in encodings:
            try:
                with open(file_path, 'r', encoding=encoding) as f:
                    content = f.read()
                    if encoding != 'utf-8':
                        print(f"  Note: File read using {encoding} encoding (not UTF-8)")
                    return content, encoding
            except UnicodeDecodeError as e:
                last_error = e
                continue
            except Exception as e:
                # For other errors (like FileNotFoundError), re-raise immediately
                raise
        
        # If we get here, all encodings failed
        raise UnicodeDecodeError(
            last_error.encoding,
            last_error.object,
            last_error.start,
            last_error.end,
            f"Unable to decode file with any of the tried encodings: {', '.join(encodings)}"
        )
    
    def read_sql_file(self, sql_file_path: str) -> str:
        """Read SQL query from text file with automatic encoding detection."""
        try:
            sql, encoding = self._read_file_with_encoding_fallback(sql_file_path)
            sql = sql.strip()
            
            if not sql:
                raise ValueError("SQL file is empty")
            
            print(f"✓ Read SQL from {sql_file_path}")
            return sql
        except FileNotFoundError:
            raise FileNotFoundError(f"SQL file not found: {sql_file_path}")
        except Exception as e:
            raise Exception(f"Error reading SQL file: {str(e)}")
    
    def read_header_file(self, file_type: str, sql_file_dir: str = None) -> Optional[List[List[str]]]:
        """
        Read custom headers from file based on file type.
        Supports multiple header rows (e.g., title rows, data type rows).
        
        Naming convention: headers_<FILE_TYPE>.txt or headers_<FILE_TYPE>.csv
        
        File format: Each line represents one header row.
        - If a line contains tabs, it's treated as tab-separated columns
        - If a line contains commas (and no tabs), it's treated as comma-separated columns
        - Empty lines are skipped
        - Lines starting with '#' are treated as comments and skipped
        
        Args:
            file_type: File type identifier (e.g., 'PO_HEADER')
            sql_file_dir: Directory to look for header file (default: current directory)
            
        Returns:
            List of header rows, where each row is a list of strings, or None if file not found
        """
        if not file_type:
            return None
        
        # Determine search directory
        if sql_file_dir:
            search_dir = sql_file_dir
        else:
            search_dir = os.getcwd()
        
        # Try .txt first, then .csv
        header_file = None
        for ext in ['.txt', '.csv']:
            candidate = os.path.join(search_dir, f"headers_{file_type}{ext}")
            if os.path.exists(candidate):
                header_file = candidate
                break
        
        if not header_file:
            print(f"⚠ Warning: Header file not found for file type '{file_type}'")
            print(f"  Expected: headers_{file_type}.txt or headers_{file_type}.csv in {search_dir}")
            return None
        
        try:
            content, encoding = self._read_file_with_encoding_fallback(header_file)
            lines = content.splitlines(keepends=True)
            
            if not lines:
                raise ValueError(f"Header file is empty: {header_file}")
            
            header_rows = []
            for line_num, line in enumerate(lines, 1):
                line = line.strip()
                
                # Skip empty lines and comments
                if not line or line.startswith('#'):
                    continue
                
                # Parse the line
                # First, try tab-separated
                if '\t' in line:
                    row = [h.strip() for h in line.split('\t')]
                # Then try comma-separated
                elif ',' in line:
                    row = [h.strip() for h in line.split(',')]
                # Otherwise, single column
                else:
                    row = [line]
                
                # Remove empty columns at the end
                while row and not row[-1]:
                    row.pop()
                
                if row:
                    header_rows.append(row)
            
            if not header_rows:
                raise ValueError(f"No valid header rows found in {header_file}")
            
            print(f"✓ Read {len(header_rows)} header row(s) from {header_file}")
            return header_rows
            
        except FileNotFoundError:
            print(f"⚠ Warning: Header file not found: {header_file}")
            return None
        except Exception as e:
            raise Exception(f"Error reading header file {header_file}: {str(e)}")
    
    def execute_query(self, sql: str, output_file: str, delimiter: str = ',', 
                     show_progress: bool = True, custom_header_rows: Optional[List[List[str]]] = None,
                     duckdb_path: str = None, duckdb_table_name: str = None):
        """
        Execute SQL query and write results to CSV and optionally persist to DuckDB.
        
        Args:
            sql: SQL query to execute
            output_file: Path to output CSV file
            delimiter: CSV delimiter (default: ',')
            show_progress: Whether to show progress (default: True)
            custom_header_rows: Optional list of header rows (each row is a list of strings).
                               The last row must match the number of SQL columns.
            duckdb_path: Optional DuckDB database file to persist results into
            duckdb_table_name: Optional table name (default: derived from SQL file name)
        """
        if not self.connection:
            raise Exception("Not connected to database. Call connect() first.")
        
        cursor = None
        csv_file = None
        writer = None
        
        try:
            # Create cursor with optimized settings
            cursor = self.connection.cursor()
            
            # Set arraysize for batch fetching (performance optimization)
            cursor.arraysize = self.arraysize
            
            print(f"Executing query...")
            start_time = datetime.now()
            
            # Execute query
            cursor.execute(sql)
            
            # Get column names and descriptions
            column_names = [desc[0] for desc in cursor.description]
            num_columns = len(column_names)
            
            # Open CSV file for writing
            csv_file = open(output_file, 'w', newline='', encoding='utf-8')
            writer = csv.writer(csv_file, delimiter=delimiter)
            
            # Write custom header rows if provided
            if custom_header_rows:
                # Validate that the last header row matches column count
                if not custom_header_rows:
                    raise ValueError("custom_header_rows is empty")
                
                last_header_row = custom_header_rows[-1]
                if len(last_header_row) != num_columns:
                    raise ValueError(
                        f"Header count mismatch: Last header row has {len(last_header_row)} columns, "
                        f"but query returns {num_columns} columns"
                    )
                
                # Write all header rows
                for row_num, header_row in enumerate(custom_header_rows, 1):
                    # Pad or truncate rows to match column count (except for the last row which should match exactly)
                    if row_num < len(custom_header_rows):
                        # Pad shorter rows with empty strings, truncate longer rows
                        padded_row = (header_row + [''] * num_columns)[:num_columns]
                        writer.writerow(padded_row)
                    else:
                        # Last row must match exactly (already validated above)
                        writer.writerow(header_row)
                
                print(f"✓ Using custom headers ({len(custom_header_rows)} header row(s), {num_columns} columns)")
            else:
                # Use SQL column names as single header row
                writer.writerow(column_names)
            
            # Fetch and write rows in batches (performance optimization)
            row_count = 0
            batch_count = 0
            
            while True:
                rows = cursor.fetchmany(self.fetch_size)
                if not rows:
                    break
                
                # Write to CSV
                writer.writerows(rows)
                
                row_count += len(rows)
                batch_count += 1
                
                if show_progress and batch_count % 10 == 0:
                    elapsed = (datetime.now() - start_time).total_seconds()
                    print(f"  Processed {row_count:,} rows (batch {batch_count}) - {elapsed:.1f}s", 
                          end='\r', flush=True)
            
            elapsed_time = (datetime.now() - start_time).total_seconds()
            
            if show_progress:
                print()  # New line after progress
            
            print(f"✓ Query executed successfully")
            print(f"✓ Extracted {row_count:,} rows to {output_file}")
            if duckdb_path:
                table = duckdb_table_name or output_file
                skip_rows = 0
                if custom_header_rows:
                    # Skip all but the last header row (which is the real column header row)
                    skip_rows = max(len(custom_header_rows) - 1, 0)
                duck_table, loaded_rows = self.persist_csv_to_duckdb(
                    duckdb_path=duckdb_path,
                    table_name=table,
                    csv_path=output_file,
                    delimiter=delimiter,
                    skip_rows=skip_rows,
                )
                print(f"✓ DuckDB table created/updated: {duck_table}")
                print(f"  DuckDB file: {duckdb_path}")
                print(f"  Access (CLI): duckdb \"{duckdb_path}\"")
                print(f"  Query: SELECT * FROM \"{duck_table}\" LIMIT 10;")
                if loaded_rows != row_count:
                    print(
                        f"⚠ Row count mismatch: Oracle extracted {row_count:,} rows, "
                        f"but DuckDB loaded {loaded_rows:,} rows."
                    )
                    print(
                        "  Note: If you're comparing to a CSV line count, it can be misleading "
                        "because CSV may contain multiple header rows and/or quoted newlines."
                    )
            print(f"✓ Total time: {elapsed_time:.2f} seconds")
            
            if row_count > 0:
                print(f"✓ Average speed: {row_count/elapsed_time:,.0f} rows/second")
            
        except Exception as e:
            print(f"✗ Error executing query: {str(e)}")
            raise
        finally:
            # Cleanup
            if cursor:
                cursor.close()
            if csv_file:
                csv_file.close()


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Extract data from Oracle database to CSV and optionally persist results to DuckDB',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Using connection string (TNS names) - CSV only
  python oracle_extract.py query.sql -u username -p password -c "hostname:port/service_name"
  
  # CSV + DuckDB persistence
  python oracle_extract.py query.sql -u username -p password -c "hostname:port/service_name" \\
    --duckdb extracts.duckdb

  # CSV + DuckDB persistence with custom table name
  python oracle_extract.py query.sql -u username -p password -c "hostname:port/service_name" \\
    --duckdb extracts.duckdb --duckdb-table po_hdr
        """
    )
    
    parser.add_argument('sql_file', help='Path to SQL file containing the query')
    parser.add_argument('-u', '--username', required=True, help='Oracle database username')
    parser.add_argument('-p', '--password', required=True, help='Oracle database password')
    
    # Connection options
    connection_group = parser.add_mutually_exclusive_group(required=True)
    connection_group.add_argument('-c', '--connection-string', 
                                  help='Full connection string (hostname:port/service_name)')
    connection_group.add_argument('--host', help='Database hostname')
    
    parser.add_argument('--port', type=int, default=1521, help='Database port (default: 1521)')
    parser.add_argument('--service-name', help='Service name or SID (required if using --host)')
    
    # Output options
    parser.add_argument('-o', '--output', help='Output CSV file path (default: <sql_file>.csv)')
    parser.add_argument('--delimiter', default=',', help='CSV delimiter (default: ,)')
    parser.add_argument('--file-type', help='File type identifier for custom headers (e.g., PO_HEADER). Looks for headers_<FILE_TYPE>.txt or headers_<FILE_TYPE>.csv in same directory as SQL file')

    # DuckDB options (optional)
    parser.add_argument('--duckdb', dest='duckdb_path',
                        help='DuckDB database file path. If set, a table will be created/replaced for each extract.')
    parser.add_argument('--duckdb-table', dest='duckdb_table',
                        help='DuckDB table name (default: derived from SQL file name)')
    
    # Performance options
    parser.add_argument('--arraysize', type=int, default=10000, 
                       help='Number of rows to fetch at once (default: 10000)')
    parser.add_argument('--fetch-size', type=int, default=10000,
                       help='Batch size for fetching rows (default: 10000)')
    
    # Other options
    parser.add_argument('--no-progress', action='store_true', 
                       help='Disable progress output')
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.host and not args.service_name:
        parser.error("--service-name is required when using --host")
    
    if args.duckdb_path and duckdb is None:
        parser.error("duckdb package is not installed. Install with: pip install duckdb")
    
    # Determine output file
    if args.output:
        output_file = args.output
    else:
        sql_dir = os.path.dirname(os.path.abspath(args.sql_file)) if os.path.dirname(args.sql_file) else os.getcwd()
        base_name = os.path.splitext(os.path.basename(args.sql_file))[0]
        output_file = os.path.join(sql_dir, f"{base_name}.csv")
    
    # Determine DuckDB table name
    duckdb_table_name = args.duckdb_table
    if not duckdb_table_name and args.duckdb_path:
        duckdb_table_name = os.path.splitext(os.path.basename(args.sql_file))[0]
    
    # Create extractor
    extractor = OracleExtractor(
        connection_string=args.connection_string,
        username=args.username,
        password=args.password,
        host=args.host,
        port=args.port,
        service_name=args.service_name,
        arraysize=args.arraysize,
        fetch_size=args.fetch_size
    )
    
    try:
        # Connect to source database
        if not extractor.connect():
            sys.exit(1)
        
        # Read SQL file
        sql = extractor.read_sql_file(args.sql_file)
        
        # Read custom headers if file type specified
        custom_header_rows = None
        if args.file_type:
            sql_file_dir = os.path.dirname(os.path.abspath(args.sql_file)) or os.getcwd()
            custom_header_rows = extractor.read_header_file(args.file_type, sql_file_dir)
            if custom_header_rows is None:
                print(f"⚠ Continuing without custom headers for file type '{args.file_type}'")
        
        # Execute query and generate CSV (and optionally target table)
        extractor.execute_query(
            sql=sql,
            output_file=output_file,
            delimiter=args.delimiter,
            show_progress=not args.no_progress,
            custom_header_rows=custom_header_rows,
            duckdb_path=args.duckdb_path,
            duckdb_table_name=duckdb_table_name
        )
        
        print(f"\n✓ Extract completed successfully: {output_file}")
        if args.duckdb_path:
            print(f"✓ Data also written to DuckDB: {args.duckdb_path}")
        
    except KeyboardInterrupt:
        print("\n\n✗ Operation cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Error: {str(e)}")
        sys.exit(1)
    finally:
        extractor.disconnect()


if __name__ == '__main__':
    main()

