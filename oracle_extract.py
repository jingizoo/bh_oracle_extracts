#!/usr/bin/env python3
"""
Oracle SQL Extract to CSV
Reads a SQL query from a text file and generates a CSV extract with performance optimizations.
"""

import argparse
import csv
import sys
import os
from datetime import datetime
from typing import Optional

try:
    import oracledb
except ImportError:
    try:
        import cx_Oracle as oracledb
    except ImportError:
        print("Error: oracledb or cx_Oracle package is required.")
        print("Install with: pip install oracledb")
        sys.exit(1)


class OracleExtractor:
    """Extract data from Oracle database to CSV with performance optimizations."""
    
    def __init__(self, connection_string: str, username: str, password: str, 
                 host: str = None, port: int = 1521, service_name: str = None,
                 arraysize: int = 10000, fetch_size: int = 10000):
        """
        Initialize Oracle extractor.
        
        Args:
            connection_string: Full connection string (tnsnames format) or None
            username: Database username
            password: Database password
            host: Database host (if not using connection_string)
            port: Database port (default: 1521)
            service_name: Service name or SID (if not using connection_string)
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
            print("✓ Database connection closed")
    
    def read_sql_file(self, sql_file_path: str) -> str:
        """Read SQL query from text file."""
        try:
            with open(sql_file_path, 'r', encoding='utf-8') as f:
                sql = f.read().strip()
            
            if not sql:
                raise ValueError("SQL file is empty")
            
            print(f"✓ Read SQL from {sql_file_path}")
            return sql
        except FileNotFoundError:
            raise FileNotFoundError(f"SQL file not found: {sql_file_path}")
        except Exception as e:
            raise Exception(f"Error reading SQL file: {str(e)}")
    
    def execute_query(self, sql: str, output_file: str, delimiter: str = ',', 
                     show_progress: bool = True):
        """
        Execute SQL query and write results to CSV.
        
        Args:
            sql: SQL query to execute
            output_file: Path to output CSV file
            delimiter: CSV delimiter (default: ',')
            show_progress: Whether to show progress (default: True)
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
            
            # Get column names
            column_names = [desc[0] for desc in cursor.description]
            
            # Open CSV file for writing
            csv_file = open(output_file, 'w', newline='', encoding='utf-8')
            writer = csv.writer(csv_file, delimiter=delimiter)
            
            # Write header
            writer.writerow(column_names)
            
            # Fetch and write rows in batches (performance optimization)
            row_count = 0
            batch_count = 0
            
            while True:
                rows = cursor.fetchmany(self.fetch_size)
                if not rows:
                    break
                
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
        description='Extract data from Oracle database to CSV using SQL from a file',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Using connection string (TNS names)
  python oracle_extract.py query.sql -u username -p password -c "hostname:port/service_name"
  
  # Using host/port/service_name
  python oracle_extract.py query.sql -u username -p password --host localhost --port 1521 --service-name ORCL
  
  # With custom output file and delimiter
  python oracle_extract.py query.sql -u username -p password -c "hostname:port/service_name" -o output.csv --delimiter "|"
  
  # With performance tuning
  python oracle_extract.py query.sql -u username -p password -c "hostname:port/service_name" --arraysize 50000
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
    
    # Determine output file
    if args.output:
        output_file = args.output
    else:
        base_name = os.path.splitext(args.sql_file)[0]
        output_file = f"{base_name}.csv"
    
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
        # Connect to database
        if not extractor.connect():
            sys.exit(1)
        
        # Read SQL file
        sql = extractor.read_sql_file(args.sql_file)
        
        # Execute query and generate CSV
        extractor.execute_query(
            sql=sql,
            output_file=output_file,
            delimiter=args.delimiter,
            show_progress=not args.no_progress
        )
        
        print(f"\n✓ Extract completed successfully: {output_file}")
        
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

