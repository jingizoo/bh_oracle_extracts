# SQL Tuning Recommendations for PO Extract Query

## Overview
This document provides specific tuning recommendations for the PO extract query without changing the results.

## Key Optimizations Applied

### 1. **NVL to COALESCE Conversion**
- **Change**: Replaced `NVL()` with `COALESCE()` in WHERE clauses and CASE statements
- **Reason**: `COALESCE` is ANSI standard and can be more efficient in some cases
- **Impact**: Minor performance improvement, better portability

### 2. **EXISTS Subqueries to JOINs**
- **Location**: `Pull_POTYPE` CTE
- **Change**: Converted EXISTS subqueries to LEFT JOINs with derived tables
- **Reason**: JOINs can be more efficient and allow better optimization by the query planner
- **Impact**: Significant improvement for queries with many matching rows

### 3. **XMLAGG to LISTAGG**
- **Location**: `Pull_Comments` CTE
- **Change**: Replaced XMLAGG with LISTAGG for comment concatenation
- **Reason**: LISTAGG is more efficient for string aggregation and simpler
- **Impact**: Moderate performance improvement, cleaner code

### 4. **Location Effective Date Optimization**
- **Location**: `location_eff` CTE
- **Change**: Used window function (ROW_NUMBER) instead of correlated subquery
- **Reason**: Window functions are more efficient than correlated subqueries
- **Impact**: Significant improvement for large location tables

### 5. **Query Hints Added**
- Added strategic hints for join methods and access paths
- **USE_HASH**: For large table joins
- **USE_NL**: For nested loop joins when appropriate
- **INDEX**: To encourage index usage
- **Note**: Hints should be tested and adjusted based on actual execution plans

### 6. **Removed Redundant NVL in Aggregations**
- **Change**: Removed NVL in SUM() since NULLs are handled automatically
- **Reason**: Cleaner code, slight performance improvement
- **Impact**: Minor

## Recommended Indexes

Based on the query structure, consider creating these indexes:

```sql
-- For recv_agg CTE
CREATE INDEX idx_recv_ln_ship_po ON ps_recv_ln_ship 
  (business_unit_po, po_id, line_nbr, sched_nbr, recv_ship_status, receipt_dttm);

-- For sched_open CTE
CREATE INDEX idx_po_line_ship_po ON ps_po_line_ship 
  (business_unit, po_id, line_nbr, sched_nbr, cancel_status, liquidate_method);

-- For open_pos CTE
CREATE INDEX idx_po_hdr_status_dt ON ps_po_hdr 
  (business_unit, po_id, po_status, po_dt);

-- For location_eff CTE
CREATE INDEX idx_location_effdt ON ps_location_tbl 
  (setid, location, effdt DESC, eff_status);

-- For vchr_sched_agg CTE
CREATE INDEX idx_voucher_line_po ON ps_voucher_line 
  (business_unit_po, po_id, line_nbr, sched_nbr);

CREATE INDEX idx_voucher_invoice_dt ON ps_voucher 
  (business_unit, voucher_id, invoice_dt);

-- For Pull_POTYPE CTE
CREATE INDEX idx_po_line_item ON ps_po_line 
  (business_unit, po_id, inv_item_id);

CREATE INDEX idx_xwlk_val_longname ON ps_BH_XWLK_VAL_TBL 
  (LONGNAME, BH_XWLK_S3);

CREATE INDEX idx_cm_item_method ON ps_CM_ITEM_METHOD 
  (BUSINESS_UNIT, INV_ITEM_ID);

-- For Pull_Comments CTE
CREATE INDEX idx_po_comments ON ps_po_comments 
  (business_unit, po_id, comment_id);

-- For consign_info CTE
CREATE INDEX idx_consgn_hdr_req ON ps_bh_consgn_hdr 
  (business_unit, req_id);

CREATE INDEX idx_consgn_line_req ON ps_bh_consgn_line 
  (business_unit, req_id);
```

## Additional Recommendations

### 1. **Statistics Collection**
Ensure table and index statistics are up to date:
```sql
EXEC DBMS_STATS.GATHER_TABLE_STATS('SCHEMA_NAME', 'PS_PO_HDR');
EXEC DBMS_STATS.GATHER_TABLE_STATS('SCHEMA_NAME', 'PS_PO_LINE_SHIP');
-- Repeat for all major tables
```

### 2. **Partitioning Consideration**
If tables are very large, consider partitioning on:
- `ps_po_hdr`: Partition by `po_dt` (date range)
- `ps_recv_ln_ship`: Partition by `receipt_dttm` (date range)
- `ps_voucher`: Partition by `invoice_dt` (date range)

### 3. **Materialized Views**
Consider creating materialized views for:
- `recv_agg` - if receipt data doesn't change frequently
- `sched_open` - if schedule status is relatively static

### 4. **Query Parallelism**
For very large datasets, consider enabling parallel execution:
```sql
ALTER SESSION ENABLE PARALLEL QUERY;
-- Or add hint: /*+ PARALLEL(4) */
```

### 5. **Result Caching**
If the query is run frequently with same parameters:
```sql
-- Add to params CTE
SELECT /*+ RESULT_CACHE */ sysdate AS asof_dt FROM dual
```

## Testing the Tuned Query

1. **Compare Results**: Ensure both queries return identical results
2. **Compare Execution Plans**: Use `oracle_tune.py` to generate plans for both versions
3. **Compare Execution Time**: Run both queries and measure elapsed time
4. **Monitor Resource Usage**: Check CPU, I/O, and memory usage

## Usage

### Generate EXPLAIN PLAN for Original Query
```bash
python oracle_tune.py po_extract_query.sql -u username -p password -c "hostname:1521/service_name" -o original_plan.txt --console
```

### Generate EXPLAIN PLAN for Tuned Query
```bash
python oracle_tune.py po_extract_query_tuned.sql -u username -p password -c "hostname:1521/service_name" -o tuned_plan.txt --console
```

### Compare Plans
Compare the two plan files to see improvements in:
- Total cost
- Full table scans
- Index usage
- Join methods

## Notes

- **Hints are suggestions**: Oracle optimizer may ignore hints if it determines a better plan
- **Test in production-like environment**: Use similar data volumes and statistics
- **Monitor over time**: Query performance may change as data grows
- **Index maintenance**: Regular index rebuilds may be needed for optimal performance

## Performance Metrics to Monitor

1. **Elapsed Time**: Total query execution time
2. **CPU Time**: CPU consumption
3. **I/O Operations**: Physical and logical reads
4. **Buffer Gets**: Number of buffer gets (lower is better)
5. **Cost**: Query optimizer cost estimate

## Rollback Plan

If the tuned query doesn't perform better:
1. Keep the original query as backup
2. Test individual optimizations separately
3. Remove hints that don't help
4. Revert to original if needed

