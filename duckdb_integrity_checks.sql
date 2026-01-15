
SELECT
  (SELECT COUNT(*) FROM po_hdr_lookback12)  AS hdr_rows,
  (SELECT COUNT(*) FROM goods_line2)        AS goods_rows,
  (SELECT COUNT(*) FROM service_line2)      AS service_rows;

-- 2) Distinct PO counts + union PO count from lines
SELECT
  (SELECT COUNT(DISTINCT "*No.") FROM po_hdr_lookback12) AS hdr_pos,
  (SELECT COUNT(DISTINCT "*No.") FROM goods_line2)       AS goods_pos,
  (SELECT COUNT(DISTINCT "*No.") FROM service_line2)     AS service_pos,
  (SELECT COUNT(DISTINCT po_no)
     FROM (SELECT "*No." AS po_no FROM goods_line2
           UNION ALL
           SELECT "*No." AS po_no FROM service_line2))   AS line_pos_union;

-- 3) POs in lines but missing header
WITH line_pos AS (
  SELECT DISTINCT "*No." AS po_no FROM goods_line2
  UNION
  SELECT DISTINCT "*No." AS po_no FROM service_line2
),
hdr_pos AS (
  SELECT DISTINCT "*No." AS po_no FROM po_hdr_lookback12
)
SELECT lp.po_no
FROM line_pos lp
LEFT JOIN hdr_pos hp ON hp.po_no = lp.po_no
WHERE hp.po_no IS NULL
ORDER BY lp.po_no;

-- 4) Header POs with no lines
WITH line_pos AS (
  SELECT DISTINCT "*No." AS po_no FROM goods_line2
  UNION
  SELECT DISTINCT "*No." AS po_no FROM service_line2
)
SELECT h."*No." AS po_no
FROM po_hdr_lookback12 h
LEFT JOIN line_pos lp ON lp.po_no = h."*No."
WHERE lp.po_no IS NULL
ORDER BY po_no;

-- 5) POs that appear in BOTH goods and service (should be ~0 if classification is mutually exclusive)
WITH g AS (SELECT DISTINCT "*No." AS po_no FROM goods_line2),
     s AS (SELECT DISTINCT "*No." AS po_no FROM service_line2)
SELECT g.po_no
FROM g
JOIN s ON s.po_no = g.po_no
ORDER BY g.po_no;

-- 6) Duplicate header rows per PO
SELECT "*No." AS po_no, COUNT(*) AS cnt
FROM po_hdr_lookback12
GROUP BY "*No."
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 7) Duplicate goods line keys per PO/Line Number
SELECT "*No." AS po_no, "Line Number", COUNT(*) AS cnt
FROM goods_line2
GROUP BY "*No.", "Line Number"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, "Line Number";

-- 8) Duplicate service line keys per PO/Line Number
SELECT "*No." AS po_no, "Line Number", COUNT(*) AS cnt
FROM service_line2
GROUP BY "*No.", "Line Number"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, "Line Number";

-- 9) Duplicate Workday Line IDs (goods)
SELECT "*No." AS po_no, "Goods Purchase Order Line ID", COUNT(*) AS cnt
FROM goods_line2
GROUP BY "*No.", "Goods Purchase Order Line ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 10) Duplicate Workday Line IDs (service)
SELECT "*No." AS po_no, "Service Order Line ID", COUNT(*) AS cnt
FROM service_line2
GROUP BY "*No.", "Service Order Line ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 11) Ensure no PO- prefix sneaked back into keys
SELECT *
FROM (
  SELECT "*No." AS id, 'hdr' AS src FROM po_hdr_lookback12
  UNION ALL
  SELECT "*No." AS id, 'goods' AS src FROM goods_line2
  UNION ALL
  SELECT "*No." AS id, 'service' AS src FROM service_line2
)
WHERE id LIKE 'PO-%'
LIMIT 50;

-- 12) Fully paid lines should be excluded (goods)
SELECT *
FROM goods_line2
WHERE COALESCE("Extended Amount", 0) <= 0
LIMIT 50;

-- 13) Fully paid lines should be excluded (service)
SELECT *
FROM service_line2
WHERE COALESCE("Extended Amount", 0) <= 0
LIMIT 50;

-- 14) Service item should be blank
SELECT *
FROM service_line2
WHERE COALESCE(TRIM("Item"), '') <> ''
LIMIT 50;

-- 15) Required header fields null/blank (adjust list as needed)
SELECT *
FROM po_hdr_lookback12
WHERE COALESCE(TRIM("*No."), '') = ''
   OR COALESCE(TRIM("*Company"), '') = ''
   OR COALESCE(TRIM("*Supplier"), '') = ''
LIMIT 50;

-- 16) Required goods line fields null/blank (adjust list as needed)
SELECT *
FROM goods_line2
WHERE COALESCE(TRIM("*No."), '') = ''
   OR "Line Number" IS NULL
   OR COALESCE(TRIM("*Quantity"), '') = ''
   OR COALESCE(TRIM("*Unit of Measure"), '') = ''
LIMIT 50;

-- 17) Required service line fields null/blank (adjust list as needed)
SELECT *
FROM service_line2
WHERE COALESCE(TRIM("*No."), '') = ''
   OR "Line Number" IS NULL
   OR COALESCE(TRIM("*Resource Category"), '') = ''
LIMIT 50;

-- 18) Total extended amount per PO (goods + service), top 50
WITH all_lines AS (
  SELECT "*No." AS po_no, COALESCE("Extended Amount",0) AS amt FROM goods_line2
  UNION ALL
  SELECT "*No." AS po_no, COALESCE("Extended Amount",0) AS amt FROM service_line2
)
SELECT po_no, SUM(amt) AS total_extended_amt, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY total_extended_amt DESC
LIMIT 50;

-- 19) POs with suspiciously high line counts
WITH all_lines AS (
  SELECT "*No." AS po_no FROM goods_line2
  UNION ALL
  SELECT "*No." AS po_no FROM service_line2
)
SELECT po_no, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY line_cnt DESC
LIMIT 50;

-- 20) Goods lines where Item is blank (review)
SELECT *
FROM goods_line2
WHERE COALESCE(TRIM("Item"), '') = ''
LIMIT 50;

