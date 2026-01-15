#!/usr/bin/env python3
"""
Oracle SQL Tuning Utility
Analyzes SQL queries, generates EXPLAIN PLAN, and provides tuning recommendations.
"""

import argparse
import sys
import os
import re
from datetime import datetime
from typing import List, Dict, Tuple

try:
    import oracledb
except ImportError:
    try:
        import cx_Oracle as oracledb
    except ImportError:
        print("Error: oracledb or cx_Oracle package is required.")
        print("Install with: pip install oracledb")
        sys.exit(1)


class OracleSQLTuner:
    """SQL tuning utility for Oracle databases."""
    
    def __init__(self, connection_string: str, username: str, password: str,
                 host: str = None, port: int = 1521, service_name: str = None):
        """Initialize SQL tuner."""
        self.username = username
        self.password = password
        self.connection_string = connection_string
        self.host = host
        self.port = port
        self.service_name = service_name
        self.connection = None
        
    def connect(self):
        """Establish connection to Oracle database."""
        try:
            if self.connection_string:
                self.connection = oracledb.connect(
                    user=self.username,
                    password=self.password,
                    dsn=self.connection_string
                )
            else:
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
            
            # Remove SQL*Plus commands if present
            sql = re.sub(r'^\s*spool\s+.*?$', '', sql, flags=re.IGNORECASE | re.MULTILINE)
            sql = re.sub(r'^\s*spool\s+off\s*$', '', sql, flags=re.IGNORECASE | re.MULTILINE)
            sql = sql.strip()
            
            print(f"✓ Read SQL from {sql_file_path}")
            return sql
        except FileNotFoundError:
            raise FileNotFoundError(f"SQL file not found: {sql_file_path}")
        except Exception as e:
            raise Exception(f"Error reading SQL file: {str(e)}")
    
    def generate_explain_plan(self, sql: str, plan_format: str = 'BASIC +COST +CARDINALITY') -> str:
        """
        Generate EXPLAIN PLAN for SQL query.
        
        Args:
            sql: SQL query to analyze
            plan_format: Format string for DBMS_XPLAN.DISPLAY
            
        Returns:
            EXPLAIN PLAN output as string
        """
        if not self.connection:
            raise Exception("Not connected to database. Call connect() first.")
        
        cursor = None
        try:
            cursor = self.connection.cursor()
            
            # Clear any existing plan
            cursor.execute("DELETE FROM plan_table")
            
            # Generate EXPLAIN PLAN
            explain_sql = f"EXPLAIN PLAN FOR {sql}"
            cursor.execute(explain_sql)
            
            # Get the plan
            cursor.execute(f"""
                SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, '{plan_format}'))
            """)
            
            plan_lines = []
            for row in cursor:
                plan_lines.append(row[0])
            
            return '\n'.join(plan_lines)
            
        except Exception as e:
            raise Exception(f"Error generating EXPLAIN PLAN: {str(e)}")
        finally:
            if cursor:
                cursor.close()
    
    def analyze_plan(self, plan_output: str) -> Dict:
        """
        Analyze EXPLAIN PLAN and identify potential issues.
        
        Returns:
            Dictionary with analysis results and recommendations
        """
        analysis = {
            'issues': [],
            'recommendations': [],
            'warnings': [],
            'stats': {}
        }
        
        lines = plan_output.split('\n')
        
        # Look for common performance issues
        full_table_scans = []
        high_cost_operations = []
        cartesian_joins = []
        index_usage = []
        cost_values = []
        
        for i, line in enumerate(lines):
            line_upper = line.upper()
            
            # Check for full table scans
            if 'TABLE ACCESS FULL' in line_upper:
                # Extract table name
                match = re.search(r'TABLE ACCESS FULL\s+(\S+)', line_upper)
                if match:
                    table_name = match.group(1)
                    full_table_scans.append(table_name)
            
            # Check for high cost operations
            if 'COST=' in line_upper:
                match = re.search(r'COST=(\d+)', line_upper)
                if match:
                    cost = int(match.group(1))
                    cost_values.append(cost)
                    if cost > 10000:
                        high_cost_operations.append((line.strip(), cost))
            
            # Check for cartesian joins
            if 'CARTESIAN' in line_upper or 'MERGE JOIN CARTESIAN' in line_upper:
                cartesian_joins.append(line.strip())
            
            # Check for index usage
            if 'INDEX' in line_upper and 'TABLE ACCESS' not in line_upper:
                match = re.search(r'INDEX\s+(\S+)', line_upper)
                if match:
                    index_usage.append(match.group(1))
        
        # Build analysis
        if full_table_scans:
            analysis['issues'].append({
                'type': 'Full Table Scans',
                'severity': 'HIGH',
                'details': f"Found {len(full_table_scans)} full table scan(s): {', '.join(set(full_table_scans))}",
                'recommendation': 'Consider adding indexes on frequently filtered/joined columns'
            })
        
        if high_cost_operations:
            max_cost = max(cost_values) if cost_values else 0
            analysis['issues'].append({
                'type': 'High Cost Operations',
                'severity': 'MEDIUM',
                'details': f"Maximum cost: {max_cost:,}",
                'recommendation': 'Review query structure and consider query rewrite or hints'
            })
        
        if cartesian_joins:
            analysis['issues'].append({
                'type': 'Cartesian Joins',
                'severity': 'CRITICAL',
                'details': f"Found {len(cartesian_joins)} cartesian join(s)",
                'recommendation': 'Add missing join conditions to avoid cartesian products'
            })
        
        analysis['stats'] = {
            'total_cost': max(cost_values) if cost_values else 0,
            'full_table_scans': len(set(full_table_scans)),
            'index_usage_count': len(index_usage),
            'cartesian_joins': len(cartesian_joins)
        }
        
        return analysis
    
    def suggest_optimizations(self, sql: str, analysis: Dict) -> List[str]:
        """
        Generate SQL optimization suggestions based on analysis.
        
        Returns:
            List of optimization suggestions
        """
        suggestions = []
        
        # Check for common patterns
        sql_upper = sql.upper()
        
        # Check for EXISTS subqueries that might benefit from IN or JOIN
        if re.search(r'EXISTS\s*\(', sql_upper):
            suggestions.append(
                "Consider converting EXISTS subqueries to JOINs if they return many rows"
            )
        
        # Check for multiple CTEs
        cte_count = len(re.findall(r'^\s*WITH\s+', sql, re.MULTILINE | re.IGNORECASE))
        if cte_count > 0:
            cte_names = len(re.findall(r'^\s*(\w+)\s+AS\s*\(', sql, re.MULTILINE | re.IGNORECASE))
            if cte_names > 10:
                suggestions.append(
                    f"Query has {cte_names} CTEs - consider materializing intermediate results or breaking into smaller queries"
                )
        
        # Check for CROSS JOIN with params
        if 'CROSS JOIN' in sql_upper and 'PARAMS' in sql_upper:
            suggestions.append(
                "CROSS JOIN with params CTE is efficient - keep as is"
            )
        
        # Check for LEFT JOINs that might be INNER JOINs
        left_join_count = len(re.findall(r'LEFT\s+JOIN', sql_upper))
        if left_join_count > 5:
            suggestions.append(
                f"Query has {left_join_count} LEFT JOINs - verify all are necessary (some might be INNER JOINs)"
            )
        
        # Check for NVL in WHERE clauses
        if re.search(r'WHERE.*NVL\s*\(', sql_upper):
            suggestions.append(
                "NVL in WHERE clauses prevents index usage - consider using COALESCE or restructuring"
            )
        
        # Check for functions on indexed columns
        if re.search(r'WHERE.*(UPPER|LOWER|TO_CHAR|TRUNC|SUBSTR)\s*\([^,)]+\)', sql_upper):
            suggestions.append(
                "Functions on indexed columns in WHERE clauses prevent index usage - consider function-based indexes"
            )
        
        # Add analysis-based suggestions
        for issue in analysis.get('issues', []):
            if issue['type'] == 'Full Table Scans' and issue['severity'] == 'HIGH':
                suggestions.append(
                    "Add composite indexes on frequently joined/filtered columns"
                )
        
        return suggestions
    
    def optimize_query(self, sql: str) -> str:
        """
        Apply automatic optimizations to SQL query (preserving results).
        
        Returns:
            Optimized SQL query
        """
        optimized = sql
        
        # Remove unnecessary DISTINCT if GROUP BY exists
        # (This is a simple example - be careful with more complex cases)
        
        # Ensure proper join conditions are explicit
        # (This would require more sophisticated parsing)
        
        # Add hints for known performance issues (optional, commented out by default)
        # optimized = self._add_hints(optimized)
        
        return optimized
    
    def save_plan(self, plan_output: str, analysis: Dict, suggestions: List[str], 
                  output_file: str):
        """Save EXPLAIN PLAN and analysis to file."""
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write("=" * 80 + "\n")
            f.write("ORACLE SQL EXPLAIN PLAN ANALYSIS\n")
            f.write("=" * 80 + "\n")
            f.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("\n")
            
            f.write("EXPLAIN PLAN OUTPUT\n")
            f.write("-" * 80 + "\n")
            f.write(plan_output)
            f.write("\n\n")
            
            f.write("PERFORMANCE ANALYSIS\n")
            f.write("-" * 80 + "\n")
            
            if analysis['stats']:
                f.write(f"Total Cost: {analysis['stats'].get('total_cost', 0):,}\n")
                f.write(f"Full Table Scans: {analysis['stats'].get('full_table_scans', 0)}\n")
                f.write(f"Index Usage Count: {analysis['stats'].get('index_usage_count', 0)}\n")
                f.write(f"Cartesian Joins: {analysis['stats'].get('cartesian_joins', 0)}\n")
                f.write("\n")
            
            if analysis['issues']:
                f.write("ISSUES FOUND:\n")
                for issue in analysis['issues']:
                    f.write(f"\n[{issue['severity']}] {issue['type']}\n")
                    f.write(f"  Details: {issue['details']}\n")
                    f.write(f"  Recommendation: {issue['recommendation']}\n")
                f.write("\n")
            
            if suggestions:
                f.write("OPTIMIZATION SUGGESTIONS:\n")
                for i, suggestion in enumerate(suggestions, 1):
                    f.write(f"  {i}. {suggestion}\n")
                f.write("\n")
            
            f.write("=" * 80 + "\n")
        
        print(f"✓ Analysis saved to {output_file}")


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Analyze and tune Oracle SQL queries using EXPLAIN PLAN',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic analysis
  python oracle_tune.py query.sql -u username -p password -c "hostname:1521/service_name"
  
  # Custom output file
  python oracle_tune.py query.sql -u username -p password -c "hostname:1521/service_name" -o plan.txt
  
  # Detailed plan format
  python oracle_tune.py query.sql -u username -p password -c "hostname:1521/service_name" --format "ALL"
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
    parser.add_argument('-o', '--output', help='Output file for plan and analysis (default: <sql_file>_plan.txt)')
    parser.add_argument('--format', default='BASIC +COST +CARDINALITY',
                       help='EXPLAIN PLAN format (default: BASIC +COST +CARDINALITY)')
    parser.add_argument('--console', action='store_true',
                       help='Also display plan on console')
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.host and not args.service_name:
        parser.error("--service-name is required when using --host")
    
    # Determine output file
    if args.output:
        output_file = args.output
    else:
        base_name = os.path.splitext(args.sql_file)[0]
        output_file = f"{base_name}_plan.txt"
    
    # Create tuner
    tuner = OracleSQLTuner(
        connection_string=args.connection_string,
        username=args.username,
        password=args.password,
        host=args.host,
        port=args.port,
        service_name=args.service_name
    )
    
    try:
        # Connect to database
        if not tuner.connect():
            sys.exit(1)
        
        # Read SQL file
        sql = tuner.read_sql_file(args.sql_file)
        
        # Generate EXPLAIN PLAN
        print("Generating EXPLAIN PLAN...")
        plan_output = tuner.generate_explain_plan(sql, args.format)
        
        # Analyze plan
        print("Analyzing plan...")
        analysis = tuner.analyze_plan(plan_output)
        
        # Generate suggestions
        print("Generating optimization suggestions...")
        suggestions = tuner.suggest_optimizations(sql, analysis)
        
        # Display on console if requested
        if args.console:
            print("\n" + "=" * 80)
            print("EXPLAIN PLAN OUTPUT")
            print("=" * 80)
            print(plan_output)
            print("\n" + "=" * 80)
            print("ANALYSIS SUMMARY")
            print("=" * 80)
            if analysis['stats']:
                print(f"Total Cost: {analysis['stats'].get('total_cost', 0):,}")
                print(f"Full Table Scans: {analysis['stats'].get('full_table_scans', 0)}")
                print(f"Index Usage: {analysis['stats'].get('index_usage_count', 0)}")
            if analysis['issues']:
                print(f"\nIssues Found: {len(analysis['issues'])}")
                for issue in analysis['issues']:
                    print(f"  [{issue['severity']}] {issue['type']}")
            if suggestions:
                print(f"\nSuggestions: {len(suggestions)}")
                for i, suggestion in enumerate(suggestions[:5], 1):
                    print(f"  {i}. {suggestion}")
            print("=" * 80 + "\n")
        
        # Save to file
        tuner.save_plan(plan_output, analysis, suggestions, output_file)
        
        print(f"\n✓ Analysis completed: {output_file}")
        
    except KeyboardInterrupt:
        print("\n\n✗ Operation cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Error: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    finally:
        tuner.disconnect()


if __name__ == '__main__':
    main()

