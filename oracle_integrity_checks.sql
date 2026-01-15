/*
Oracle / SQL Developer integrity checks (mirror of duckdb_integrity_checks.sql)

How to use in SQL Developer
1) Open this file in SQL Developer.
2) Replace the three CTE bodies (hdr_src / goods_src / service_src) by pasting the
   SELECT statements from:
   - bh_oracle_extracts/po_hdr_lookback12.sql
   - bh_oracle_extracts/Goods_line2.txt
   - bh_oracle_extracts/service_line2.txt
3) Run the script. Each section below is a standalone query (like the DuckDB version).

Notes
- Oracle uses FETCH FIRST N ROWS ONLY (instead of LIMIT N).
- Column names like "*No." require double-quotes in Oracle.
*/

/* ============================================================
   Define extract datasets (PASTE YOUR SELECTs inside each CTE)
   ============================================================ */

-- Header extract dataset
WITH hdr_src AS (
  /* PASTE the SELECT from bh_oracle_extracts/po_hdr_lookback12.sql here */
  SELECT 1 AS dummy FROM dual
),
-- Goods lines dataset
goods_src AS (
  /* PASTE the SELECT from bh_oracle_extracts/Goods_line2.txt here */
  SELECT 1 AS dummy FROM dual
),
-- Service lines dataset
service_src AS (
  /* PASTE the SELECT from bh_oracle_extracts/service_line2.txt here */
  SELECT 1 AS dummy FROM dual
)
SELECT
  (SELECT COUNT(*) FROM hdr_src)     AS hdr_rows,
  (SELECT COUNT(*) FROM goods_src)   AS goods_rows,
  (SELECT COUNT(*) FROM service_src) AS service_rows
FROM dual;

/* 2) Distinct PO counts + union PO count from lines */
WITH hdr_src AS (
  /* PASTE po_hdr_lookback12.sql SELECT here */ SELECT 1 AS dummy FROM dual
),
goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT
  (SELECT COUNT(DISTINCT h."*No.") FROM hdr_src h) AS hdr_pos,
  (SELECT COUNT(DISTINCT g."*No.") FROM goods_src g) AS goods_pos,
  (SELECT COUNT(DISTINCT s."*No.") FROM service_src s) AS service_pos,
  (SELECT COUNT(DISTINCT po_no)
     FROM (SELECT g."*No." AS po_no FROM goods_src g
           UNION ALL
           SELECT s."*No." AS po_no FROM service_src s)) AS line_pos_union
FROM dual;

/* 3) POs in lines but missing header */
WITH hdr_src AS (
  /* PASTE po_hdr_lookback12.sql SELECT here */ SELECT 1 AS dummy FROM dual
),
goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
line_pos AS (
  SELECT DISTINCT g."*No." AS po_no FROM goods_src g
  UNION
  SELECT DISTINCT s."*No." AS po_no FROM service_src s
),
hdr_pos AS (
  SELECT DISTINCT h."*No." AS po_no FROM hdr_src h
)
SELECT lp.po_no
FROM line_pos lp
LEFT JOIN hdr_pos hp ON hp.po_no = lp.po_no
WHERE hp.po_no IS NULL
ORDER BY lp.po_no;

/* 4) Header POs with no lines */
WITH hdr_src AS (
  /* PASTE po_hdr_lookback12.sql SELECT here */ SELECT 1 AS dummy FROM dual
),
goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
line_pos AS (
  SELECT DISTINCT g."*No." AS po_no FROM goods_src g
  UNION
  SELECT DISTINCT s."*No." AS po_no FROM service_src s
)
SELECT h."*No." AS po_no
FROM hdr_src h
LEFT JOIN line_pos lp ON lp.po_no = h."*No."
WHERE lp.po_no IS NULL
ORDER BY po_no;

/* 5) POs that appear in BOTH goods and service (should be ~0 if mutually exclusive) */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
g AS (SELECT DISTINCT "*No." AS po_no FROM goods_src),
s AS (SELECT DISTINCT "*No." AS po_no FROM service_src)
SELECT g.po_no
FROM g
JOIN s ON s.po_no = g.po_no
ORDER BY g.po_no;

/* 6) Duplicate header rows per PO */
WITH hdr_src AS (
  /* PASTE po_hdr_lookback12.sql SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT h."*No." AS po_no, COUNT(*) AS cnt
FROM hdr_src h
GROUP BY h."*No."
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

/* 7) Duplicate goods line keys per PO/Line Number */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT g."*No." AS po_no, g."Line Number", COUNT(*) AS cnt
FROM goods_src g
GROUP BY g."*No.", g."Line Number"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, g."Line Number";

/* 8) Duplicate service line keys per PO/Line Number */
WITH service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT s."*No." AS po_no, s."Line Number", COUNT(*) AS cnt
FROM service_src s
GROUP BY s."*No.", s."Line Number"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, s."Line Number";

/* 9) Duplicate Workday Line IDs (goods) */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT g."*No." AS po_no, g."Goods Purchase Order Line ID", COUNT(*) AS cnt
FROM goods_src g
GROUP BY g."*No.", g."Goods Purchase Order Line ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

/* 10) Duplicate Workday Line IDs (service) */
WITH service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT s."*No." AS po_no, s."Service Order Line ID", COUNT(*) AS cnt
FROM service_src s
GROUP BY s."*No.", s."Service Order Line ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

/* 11) Ensure no PO- prefix sneaked back into keys */
WITH hdr_src AS (
  /* PASTE po_hdr_lookback12.sql SELECT here */ SELECT 1 AS dummy FROM dual
),
goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM (
  SELECT h."*No." AS id, 'hdr' AS src FROM hdr_src h
  UNION ALL
  SELECT g."*No." AS id, 'goods' AS src FROM goods_src g
  UNION ALL
  SELECT s."*No." AS id, 'service' AS src FROM service_src s
)
WHERE id LIKE 'PO-%'
FETCH FIRST 50 ROWS ONLY;

/* 12) Fully paid lines should be excluded (goods) */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM goods_src
WHERE NVL("Extended Amount", 0) <= 0
FETCH FIRST 50 ROWS ONLY;

/* 13) Fully paid lines should be excluded (service) */
WITH service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM service_src
WHERE NVL("Extended Amount", 0) <= 0
FETCH FIRST 50 ROWS ONLY;

/* 14) Service item should be blank */
WITH service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM service_src
WHERE NVL(TRIM("Item"), '') <> ''
FETCH FIRST 50 ROWS ONLY;

/* 15) Required header fields null/blank (adjust list as needed) */
WITH hdr_src AS (
  /* PASTE po_hdr_lookback12.sql SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM hdr_src
WHERE NVL(TRIM("*No."), '') = ''
   OR NVL(TRIM("*Company"), '') = ''
   OR NVL(TRIM("*Supplier"), '') = ''
FETCH FIRST 50 ROWS ONLY;

/* 16) Required goods line fields null/blank (adjust list as needed) */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM goods_src
WHERE NVL(TRIM("*No."), '') = ''
   OR "Line Number" IS NULL
   OR NVL(TRIM("*Quantity"), '') = ''
   OR NVL(TRIM("*Unit of Measure"), '') = ''
FETCH FIRST 50 ROWS ONLY;

/* 17) Required service line fields null/blank (adjust list as needed) */
WITH service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM service_src
WHERE NVL(TRIM("*No."), '') = ''
   OR "Line Number" IS NULL
   OR NVL(TRIM("*Resource Category"), '') = ''
FETCH FIRST 50 ROWS ONLY;

/* 18) Total extended amount per PO (goods + service), top 50 */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
all_lines AS (
  SELECT g."*No." AS po_no, NVL(g."Extended Amount", 0) AS amt FROM goods_src g
  UNION ALL
  SELECT s."*No." AS po_no, NVL(s."Extended Amount", 0) AS amt FROM service_src s
)
SELECT po_no, SUM(amt) AS total_extended_amt, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY total_extended_amt DESC
FETCH FIRST 50 ROWS ONLY;

/* 19) POs with suspiciously high line counts */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
service_src AS (
  /* PASTE service_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
),
all_lines AS (
  SELECT g."*No." AS po_no FROM goods_src g
  UNION ALL
  SELECT s."*No." AS po_no FROM service_src s
)
SELECT po_no, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY line_cnt DESC
FETCH FIRST 50 ROWS ONLY;

/* 20) Goods lines where Item is blank (review) */
WITH goods_src AS (
  /* PASTE Goods_line2.txt SELECT here */ SELECT 1 AS dummy FROM dual
)
SELECT *
FROM goods_src
WHERE NVL(TRIM("Item"), '') = ''
FETCH FIRST 50 ROWS ONLY;

