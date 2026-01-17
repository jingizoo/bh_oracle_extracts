/*
DuckDB checks (single consolidated file)

Expected DuckDB tables:
- po_header
- goods_po_line
- service_po_line
- good_worktags_8011501
- service_worktags_8011501

Note on columns:
These queries assume the DuckDB tables were created with sanitized column names
(no asterisks, spaces converted to underscores, lowercased), e.g.:
  "*No." -> no
  "Line Number" -> line_number
  "Extended Amount" -> extended_amount
  "*Quantity" -> quantity
  "*Unit of Measure" -> unit_of_measure
  "Goods Purchase Order Line ID" -> goods_purchase_order_line_id
  "Service Order Line ID" -> service_order_line_id
*/

-- 1) Row counts (header + lines)
SELECT
  (SELECT COUNT(*) FROM po_header)    AS hdr_rows,
  (SELECT COUNT(*) FROM goods_po_line)   AS goods_rows,
  (SELECT COUNT(*) FROM service_po_line) AS service_rows;

-- 2) Distinct PO counts + union PO count from lines
SELECT
  (SELECT COUNT(DISTINCT no) FROM po_header)    AS hdr_pos,
  (SELECT COUNT(DISTINCT no) FROM goods_po_line)   AS goods_pos,
  (SELECT COUNT(DISTINCT no) FROM service_po_line) AS service_pos,
  (SELECT COUNT(DISTINCT po_no)
     FROM (
       SELECT no AS po_no FROM goods_po_line
       UNION ALL
       SELECT no AS po_no FROM service_po_line
     )) AS line_pos_union;

-- 3) POs in lines but missing header
WITH line_pos AS (
  SELECT DISTINCT no AS po_no FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_no FROM service_po_line
),
hdr_pos AS (
  SELECT DISTINCT no AS po_no FROM po_header
)
SELECT lp.po_no
FROM line_pos lp
LEFT JOIN hdr_pos hp ON hp.po_no = lp.po_no
WHERE hp.po_no IS NULL
ORDER BY lp.po_no;

-- 4) Header POs with no lines
WITH line_pos AS (
  SELECT DISTINCT no AS po_no FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_no FROM service_po_line
)
SELECT h.no AS po_no
FROM po_header h
LEFT JOIN line_pos lp ON lp.po_no = h.no
WHERE lp.po_no IS NULL
ORDER BY po_no;

-- 5) POs that appear in BOTH goods and service (should be ~0 if mutually exclusive)
WITH g AS (SELECT DISTINCT no AS po_no FROM goods_po_line),
     s AS (SELECT DISTINCT no AS po_no FROM service_po_line)
SELECT g.po_no
FROM g
JOIN s ON s.po_no = g.po_no
ORDER BY g.po_no;

-- 6) Duplicate header rows per PO
SELECT no AS po_no, COUNT(*) AS cnt
FROM po_header
GROUP BY no
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 7) Duplicate goods line keys per PO/Line Number
SELECT no AS po_no, line_number, COUNT(*) AS cnt
FROM goods_po_line
GROUP BY no, line_number
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, line_number;

-- 8) Duplicate service line keys per PO/Line Number
SELECT no AS po_no, line_number, COUNT(*) AS cnt
FROM service_po_line
GROUP BY no, line_number
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, line_number;

-- 9) Duplicate Workday Line IDs (goods)
SELECT no AS po_no, goods_purchase_order_line_id, COUNT(*) AS cnt
FROM goods_po_line
GROUP BY no, goods_purchase_order_line_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 10) Duplicate Workday Line IDs (service)
SELECT no AS po_no, service_order_line_id, COUNT(*) AS cnt
FROM service_po_line
GROUP BY no, service_order_line_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 11) Ensure no PO- prefix sneaked back into keys
SELECT *
FROM (
  SELECT no AS id, 'hdr' AS src FROM po_header
  UNION ALL
  SELECT no AS id, 'goods' AS src FROM goods_po_line
  UNION ALL
  SELECT no AS id, 'service' AS src FROM service_po_line
)
WHERE id LIKE 'PO-%'
LIMIT 50;

-- 12) Fully paid lines should be excluded (goods)
SELECT *
FROM goods_po_line
WHERE COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) <= 0.0
LIMIT 50;

-- 13) Fully paid lines should be excluded (service)
SELECT *
FROM service_po_line
WHERE COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) <= 0.0
LIMIT 50;

-- 14) Service item should be blank
SELECT *
FROM service_po_line
WHERE COALESCE(TRIM(item), '') <> ''
LIMIT 50;

-- 15) Required header fields null/blank (light sanity)
SELECT *
FROM po_header
WHERE COALESCE(TRIM(no), '') = ''
   OR COALESCE(TRIM(company), '') = ''
   OR COALESCE(TRIM(supplier), '') = ''
LIMIT 50;

-- 16) Required goods line fields null/blank (light sanity)
SELECT *
FROM goods_po_line
WHERE COALESCE(TRIM(no), '') = ''
   OR line_number IS NULL
   OR quantity IS NULL OR TRIM(CAST(quantity AS VARCHAR)) = ''
   OR unit_of_measure IS NULL OR TRIM(unit_of_measure) = ''
LIMIT 50;

-- 17) Required service line fields null/blank (light sanity)
SELECT *
FROM service_po_line
WHERE COALESCE(TRIM(no), '') = ''
   OR line_number IS NULL
   OR resource_category IS NULL OR TRIM(resource_category) = ''
LIMIT 50;

-- 18) Total extended amount per PO (goods + service), top 50
WITH all_lines AS (
  SELECT no AS po_no, COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) AS amt FROM goods_po_line
  UNION ALL
  SELECT no AS po_no, COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) AS amt FROM service_po_line
)
SELECT po_no, SUM(amt) AS total_extended_amt, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY total_extended_amt DESC
LIMIT 50;

-- 19) POs with suspiciously high line counts
WITH all_lines AS (
  SELECT no AS po_no FROM goods_po_line
  UNION ALL
  SELECT no AS po_no FROM service_po_line
)
SELECT po_no, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY line_cnt DESC
LIMIT 50;

-- 20) Goods lines where Item is blank (review)
SELECT *
FROM goods_po_line
WHERE COALESCE(TRIM(item), '') = ''
LIMIT 50;

/* ------------------------------
   Required-fields checks
   ------------------------------ */

-- 21) Goods lines where ANY of these header fields are NULL/blank:
--     - bill_to_contact_detail
--     - ship_to_contact_worker_id
--     - ship_to_contact_detail
SELECT
  g.no AS po_no,
  g.line_number AS line_number,
  h.bill_to_contact_detail AS bill_to_contact_detail,
  h.ship_to_contact_worker_id AS ship_to_contact_worker_id,
  h.ship_to_contact_detail AS ship_to_contact_detail
FROM goods_po_line g
JOIN po_header h
  ON h.no = g.no
WHERE h.bill_to_contact_detail IS NULL OR h.bill_to_contact_detail = ''
   OR h.ship_to_contact_worker_id IS NULL OR h.ship_to_contact_worker_id = ''
   OR h.ship_to_contact_detail IS NULL OR h.ship_to_contact_detail = ''
ORDER BY po_no, line_number;

-- 22) Service lines where Resource Category is NULL/blank
SELECT *
FROM service_po_line
WHERE resource_category IS NULL OR resource_category = ''
ORDER BY no, line_number;

-- 23) Goods lines: Resource Category is required ONLY when Item (inventory item id) is NULL/blank
SELECT
  no AS po_no,
  line_number,
  item AS inventory_item_id,
  resource_category
FROM goods_po_line
WHERE (item IS NULL OR item = '')
  AND (resource_category IS NULL OR resource_category = '')
ORDER BY po_no, line_number;

-- 24) PO headers where Close Status is NULL/blank
SELECT *
FROM po_header
WHERE close_status IS NULL OR close_status = ''
ORDER BY no;

/* ------------------------------
   Worktags integrity checks
   ------------------------------ */

-- 25) Worktags row counts + distinct PO counts
SELECT
  (SELECT COUNT(*) FROM good_worktags_8011501)     AS goods_wt_rows,
  (SELECT COUNT(*) FROM service_worktags_8011501)  AS service_wt_rows,
  (SELECT COUNT(DISTINCT no) FROM good_worktags_8011501)     AS goods_wt_pos,
  (SELECT COUNT(DISTINCT no) FROM service_worktags_8011501)  AS service_wt_pos;

-- 26) Duplicate worktags keys (goods): (no, goods line no, worktags line no)
SELECT
  no AS po_no,
  goods_po_line_replacement_data_line_no AS line_no,
  worktags_line_no AS wt_line_no,
  COUNT(*) AS cnt
FROM good_worktags_8011501
GROUP BY no, goods_po_line_replacement_data_line_no, worktags_line_no
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, line_no, wt_line_no;

-- 27) Duplicate worktags keys (service): (no, service line no, worktags line no)
SELECT
  no AS po_no,
  service_po_line_replacement_data_line_no AS line_no,
  worktags_line_no AS wt_line_no,
  COUNT(*) AS cnt
FROM service_worktags_8011501
GROUP BY no, service_po_line_replacement_data_line_no, worktags_line_no
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, line_no, wt_line_no;

-- 28) Blank/NULL worktags values (goods + service) (should be empty)
SELECT 'goods' AS src, *
FROM good_worktags_8011501
WHERE COALESCE(TRIM(worktags), '') = ''
UNION ALL
SELECT 'service' AS src, *
FROM service_worktags_8011501
WHERE COALESCE(TRIM(worktags), '') = ''
LIMIT 50;

-- 29) Worktags line numbering should be contiguous per PO line (goods)
SELECT
  no AS po_no,
  goods_po_line_replacement_data_line_no AS line_no,
  MIN(worktags_line_no) AS min_wt_line_no,
  MAX(worktags_line_no) AS max_wt_line_no,
  COUNT(*) AS cnt
FROM good_worktags_8011501
GROUP BY no, goods_po_line_replacement_data_line_no
HAVING MIN(worktags_line_no) <> 1
    OR MAX(worktags_line_no) <> COUNT(*)
ORDER BY po_no, line_no
LIMIT 200;

-- 30) Worktags line numbering should be contiguous per PO line (service)
SELECT
  no AS po_no,
  service_po_line_replacement_data_line_no AS line_no,
  MIN(worktags_line_no) AS min_wt_line_no,
  MAX(worktags_line_no) AS max_wt_line_no,
  COUNT(*) AS cnt
FROM service_worktags_8011501
GROUP BY no, service_po_line_replacement_data_line_no
HAVING MIN(worktags_line_no) <> 1
    OR MAX(worktags_line_no) <> COUNT(*)
ORDER BY po_no, line_no
LIMIT 200;

-- 31) Worktags must reference existing goods lines (by PO + Line Number)
WITH wt AS (
  SELECT DISTINCT
    no AS po_no,
    goods_po_line_replacement_data_line_no AS line_no
  FROM good_worktags_8011501
),
gl AS (
  SELECT DISTINCT
    no AS po_no,
    line_number AS line_no
  FROM goods_po_line
)
SELECT wt.po_no, wt.line_no
FROM wt
LEFT JOIN gl ON gl.po_no = wt.po_no AND gl.line_no = wt.line_no
WHERE gl.po_no IS NULL
ORDER BY wt.po_no, wt.line_no
LIMIT 200;

-- 32) Worktags must reference existing service lines (by PO + Line Number)
WITH wt AS (
  SELECT DISTINCT
    no AS po_no,
    service_po_line_replacement_data_line_no AS line_no
  FROM service_worktags_8011501
),
sl AS (
  SELECT DISTINCT
    no AS po_no,
    line_number AS line_no
  FROM service_po_line
)
SELECT wt.po_no, wt.line_no
FROM wt
LEFT JOIN sl ON sl.po_no = wt.po_no AND sl.line_no = wt.line_no
WHERE sl.po_no IS NULL
ORDER BY wt.po_no, wt.line_no
LIMIT 200;

-- 33) Lines missing ANY worktags (goods)
WITH gl AS (
  SELECT DISTINCT no AS po_no, line_number AS line_no
  FROM goods_po_line
),
wt AS (
  SELECT DISTINCT no AS po_no, goods_po_line_replacement_data_line_no AS line_no
  FROM good_worktags_8011501
)
SELECT gl.po_no, gl.line_no
FROM gl
LEFT JOIN wt ON wt.po_no = gl.po_no AND wt.line_no = gl.line_no
WHERE wt.po_no IS NULL
ORDER BY gl.po_no, gl.line_no
LIMIT 200;

-- 34) Lines missing ANY worktags (service)
WITH sl AS (
  SELECT DISTINCT no AS po_no, line_number AS line_no
  FROM service_po_line
),
wt AS (
  SELECT DISTINCT no AS po_no, service_po_line_replacement_data_line_no AS line_no
  FROM service_worktags_8011501
)
SELECT sl.po_no, sl.line_no
FROM sl
LEFT JOIN wt ON wt.po_no = sl.po_no AND wt.line_no = sl.line_no
WHERE wt.po_no IS NULL
ORDER BY sl.po_no, sl.line_no
LIMIT 200;

-- 35) Excessive number of worktags per line (goods) (heuristic: expected <= 2)
SELECT
  no AS po_no,
  goods_po_line_replacement_data_line_no AS line_no,
  COUNT(*) AS wt_cnt
FROM good_worktags_8011501
GROUP BY no, goods_po_line_replacement_data_line_no
HAVING COUNT(*) > 2
ORDER BY wt_cnt DESC, po_no, line_no
LIMIT 200;

-- 36) Excessive number of worktags per line (service) (heuristic: expected <= 3)
SELECT
  no AS po_no,
  service_po_line_replacement_data_line_no AS line_no,
  COUNT(*) AS wt_cnt
FROM service_worktags_8011501
GROUP BY no, service_po_line_replacement_data_line_no
HAVING COUNT(*) > 3
ORDER BY wt_cnt DESC, po_no, line_no
LIMIT 200;

-- 37) Basic format sanity: cost center worktags should look like CC_<OU>-<DEPTID> (goods)
SELECT *
FROM good_worktags_8011501
WHERE worktags LIKE 'CC_%'
  AND worktags NOT LIKE 'CC_%-%'
LIMIT 200;

-- 38) Basic format sanity: cost center worktags should look like CC_<OU>-<DEPTID> (service)
SELECT *
FROM service_worktags_8011501
WHERE worktags LIKE 'CC_%'
  AND worktags NOT LIKE 'CC_%-%'
LIMIT 200;

-- 39) Ensure no PO- prefix sneaked into worktags extracts
SELECT 'goods' AS src, no AS po_no
FROM good_worktags_8011501
WHERE no LIKE 'PO-%'
UNION ALL
SELECT 'service' AS src, no AS po_no
FROM service_worktags_8011501
WHERE no LIKE 'PO-%'
LIMIT 200;

/* ------------------------------
   Additional reconciliation summaries (requested)
   ------------------------------ */

-- 40) PO set reconciliation metrics (Header vs Goods UNION Service)
WITH
hdr_pos AS (
  SELECT DISTINCT no AS po_id
  FROM po_header
),
line_pos AS (
  SELECT DISTINCT no AS po_id FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_id FROM service_po_line
)
SELECT metric, val
FROM (
  SELECT 'HDR_DISTINCT_PO' AS metric, COUNT(*)::BIGINT AS val FROM hdr_pos
  UNION ALL
  SELECT 'LINES_DISTINCT_PO(goods∪service)', COUNT(*)::BIGINT FROM line_pos
  UNION ALL
  SELECT 'LINES_MINUS_HDR (must be 0)',
         (SELECT COUNT(*)::BIGINT FROM (SELECT po_id FROM line_pos EXCEPT SELECT po_id FROM hdr_pos))
  UNION ALL
  SELECT 'HDR_MINUS_LINES (must be 0)',
         (SELECT COUNT(*)::BIGINT FROM (SELECT po_id FROM hdr_pos EXCEPT SELECT po_id FROM line_pos))
)
ORDER BY metric;

-- 41) List POs in lines but missing in header (must be empty)
WITH
hdr_pos AS (SELECT DISTINCT no AS po_id FROM po_header),
line_pos AS (
  SELECT DISTINCT no AS po_id FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_id FROM service_po_line
)
SELECT po_id
FROM (SELECT po_id FROM line_pos EXCEPT SELECT po_id FROM hdr_pos)
ORDER BY po_id
LIMIT 200;

-- 42) List POs in header but missing in lines (must be empty)
WITH
hdr_pos AS (SELECT DISTINCT no AS po_id FROM po_header),
line_pos AS (
  SELECT DISTINCT no AS po_id FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_id FROM service_po_line
)
SELECT po_id
FROM (SELECT po_id FROM hdr_pos EXCEPT SELECT po_id FROM line_pos)
ORDER BY po_id
LIMIT 200;

-- 43) Overlap: same PO appears in both goods and service (count; should be 0 if PO-level split)
WITH
g AS (SELECT DISTINCT no AS po_id FROM goods_po_line),
s AS (SELECT DISTINCT no AS po_id FROM service_po_line)
SELECT COUNT(*)::BIGINT AS overlap_po_cnt
FROM (SELECT po_id FROM g INTERSECT SELECT po_id FROM s);

-- 44) Overlap: same PO+Line appears in both goods and service (must be 0 always)
WITH
g AS (SELECT no AS po_id, line_number AS line_nbr FROM goods_po_line),
s AS (SELECT no AS po_id, line_number AS line_nbr FROM service_po_line)
SELECT COUNT(*)::BIGINT AS overlap_po_line_cnt
FROM (SELECT po_id, line_nbr FROM g INTERSECT SELECT po_id, line_nbr FROM s);

-- 45) Worktags PO-set reconciliation vs Lines PO-set
WITH
line_pos AS (
  SELECT DISTINCT no AS po_id FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_id FROM service_po_line
),
wt_pos AS (
  SELECT DISTINCT no AS po_id FROM good_worktags_8011501
  UNION
  SELECT DISTINCT no AS po_id FROM service_worktags_8011501
)
SELECT metric, val
FROM (
  SELECT 'WT_DISTINCT_PO' AS metric, COUNT(*)::BIGINT AS val FROM wt_pos
  UNION ALL
  SELECT 'WT_MINUS_LINES (should be 0 or explainable)',
         (SELECT COUNT(*)::BIGINT FROM (SELECT po_id FROM wt_pos EXCEPT SELECT po_id FROM line_pos))
  UNION ALL
  SELECT 'LINES_MINUS_WT (should be 0 if every line has a worktag row)',
         (SELECT COUNT(*)::BIGINT FROM (SELECT po_id FROM line_pos EXCEPT SELECT po_id FROM wt_pos))
)
ORDER BY metric;

-- 46) Goods: Item present but Resource Category populated (should be 0 per rule)
SELECT
  no AS po_no,
  line_number,
  item AS inventory_item_id,
  resource_category
FROM goods_po_line
WHERE COALESCE(TRIM(item), '') <> ''
  AND COALESCE(TRIM(resource_category), '') <> ''
ORDER BY po_no, line_number
LIMIT 200;

-- 47) Service buyer override: Service POs not assigned to Doug by Bill To Contact Detail (should be 0)
SELECT
  no AS po_no,
  purchase_order_type,
  buyer_worker_id,
  bill_to_contact_worker_id,
  bill_to_contact_detail
FROM po_header
WHERE purchase_order_type = 'Service'
  AND COALESCE(TRIM(bill_to_contact_detail), '') <> 'Doug Kolpak'
ORDER BY po_no
LIMIT 200;

-- 48) Service buyer override: Buyer/Bill-to worker ids should match (should be 0)
SELECT
  no AS po_no,
  purchase_order_type,
  buyer_worker_id,
  bill_to_contact_worker_id,
  bill_to_contact_detail
FROM po_header
WHERE purchase_order_type = 'Service'
  AND COALESCE(TRIM(buyer_worker_id), '') <> COALESCE(TRIM(bill_to_contact_worker_id), '')
ORDER BY po_no
LIMIT 200;

-- 49) Amount tolerance sanity: goods lines with Extended Amount between 0 and 1 (review list)
SELECT
  no AS po_no,
  line_number AS line_nbr,
  COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) AS extended_amount_num,
  extended_amount AS extended_amount_raw
FROM goods_po_line
WHERE COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) > 0.0
  AND COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) <= 1.0
ORDER BY extended_amount_num ASC
LIMIT 200;

-- 50) Amount tolerance sanity: service lines with Extended Amount between 0 and 1 (review list)
SELECT
  no AS po_no,
  line_number AS line_nbr,
  COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) AS extended_amount_num,
  extended_amount AS extended_amount_raw
FROM service_po_line
WHERE COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) > 0.0
  AND COALESCE(try_cast(extended_amount AS DOUBLE), 0.0) <= 1.0
  COALESCE(try_cast(quantity AS DOUBLE), 0.0) > 0.0
  AND COALESCE(try_cast(quantity AS DOUBLE), 0.0) <= 1.0
ORDER BY extended_amount_num ASC
LIMIT 200;
