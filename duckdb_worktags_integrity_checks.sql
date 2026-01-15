
/* DuckDB integrity checks for Worktags extracts

Tables expected (created by oracle_extract.py --duckdb ...):
- good_worktags_8011501    (from Good_Worktags_8011501.txt)
- service_worktags_8011501 (from Service_worktags_8011501.txt)

These checks validate:
- No duplicate keys
- No blank worktags
- Worktags line numbers are contiguous per PO line
- Worktags reference existing goods/service line extract rows
- Goods/service lines are not missing required worktags
*/

-- 1) Row counts + distinct PO counts
SELECT
  (SELECT COUNT(*) FROM good_worktags_8011501)    AS goods_wt_rows,
  (SELECT COUNT(*) FROM service_worktags_8011501) AS service_wt_rows,
  (SELECT COUNT(DISTINCT "*No.") FROM good_worktags_8011501)    AS goods_wt_pos,
  (SELECT COUNT(DISTINCT "*No.") FROM service_worktags_8011501) AS service_wt_pos;

-- 2) Duplicate worktags keys (goods): (*No., goods line no, worktags line no)
SELECT "*No." AS po_no,
       "*Goods Line Replacement Data Line No" AS line_no,
       "*Worktags Line No" AS wt_line_no,
       COUNT(*) AS cnt
FROM good_worktags_8011501
GROUP BY "*No.", "*Goods Line Replacement Data Line No", "*Worktags Line No"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, line_no, wt_line_no;

-- 3) Duplicate worktags keys (service): (*No., service line no, worktags line no)
SELECT "*No." AS po_no,
       "*Service Line Replacement Data Line No" AS line_no,
       "*Worktags Line No" AS wt_line_no,
       COUNT(*) AS cnt
FROM service_worktags_8011501
GROUP BY "*No.", "*Service Line Replacement Data Line No", "*Worktags Line No"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no, line_no, wt_line_no;

-- 4) Blank/NULL worktags values (goods + service) (should be empty)
SELECT 'goods' AS src, *
FROM good_worktags_8011501
WHERE COALESCE(TRIM("*Worktags"), '') = ''
UNION ALL
SELECT 'service' AS src, *
FROM service_worktags_8011501
WHERE COALESCE(TRIM("*Worktags"), '') = ''
LIMIT 50;

-- 5) Worktags line numbering should be contiguous per PO line:
--     min = 1 AND max = count (no gaps) (goods)
SELECT "*No." AS po_no,
       "*Goods Line Replacement Data Line No" AS line_no,
       MIN("*Worktags Line No") AS min_wt_line_no,
       MAX("*Worktags Line No") AS max_wt_line_no,
       COUNT(*) AS cnt
FROM good_worktags_8011501
GROUP BY "*No.", "*Goods Line Replacement Data Line No"
HAVING MIN("*Worktags Line No") <> 1
    OR MAX("*Worktags Line No") <> COUNT(*)
ORDER BY po_no, line_no
LIMIT 200;

-- 6) Worktags line numbering should be contiguous per PO line (service)
SELECT "*No." AS po_no,
       "*Service Line Replacement Data Line No" AS line_no,
       MIN("*Worktags Line No") AS min_wt_line_no,
       MAX("*Worktags Line No") AS max_wt_line_no,
       COUNT(*) AS cnt
FROM service_worktags_8011501
GROUP BY "*No.", "*Service Line Replacement Data Line No"
HAVING MIN("*Worktags Line No") <> 1
    OR MAX("*Worktags Line No") <> COUNT(*)
ORDER BY po_no, line_no
LIMIT 200;

-- 7) Worktags must reference existing goods lines (by PO + Line Number)
WITH wt AS (
  SELECT DISTINCT
    "*No." AS po_no,
    "*Goods Line Replacement Data Line No" AS line_no
  FROM good_worktags_8011501
),
gl AS (
  SELECT DISTINCT
    "*No." AS po_no,
    "Line Number" AS line_no
  FROM goods_line2
)
SELECT wt.po_no, wt.line_no
FROM wt
LEFT JOIN gl ON gl.po_no = wt.po_no AND gl.line_no = wt.line_no
WHERE gl.po_no IS NULL
ORDER BY wt.po_no, wt.line_no
LIMIT 200;

-- 8) Worktags must reference existing service lines (by PO + Line Number)
WITH wt AS (
  SELECT DISTINCT
    "*No." AS po_no,
    "*Service Line Replacement Data Line No" AS line_no
  FROM service_worktags_8011501
),
sl AS (
  SELECT DISTINCT
    "*No." AS po_no,
    "Line Number" AS line_no
  FROM service_line2
)
SELECT wt.po_no, wt.line_no
FROM wt
LEFT JOIN sl ON sl.po_no = wt.po_no AND sl.line_no = wt.line_no
WHERE sl.po_no IS NULL
ORDER BY wt.po_no, wt.line_no
LIMIT 200;

-- 9) Lines missing ANY worktags (goods)
WITH gl AS (
  SELECT DISTINCT "*No." AS po_no, "Line Number" AS line_no
  FROM goods_line2
),
wt AS (
  SELECT DISTINCT "*No." AS po_no, "*Goods Line Replacement Data Line No" AS line_no
  FROM good_worktags_8011501
)
SELECT gl.po_no, gl.line_no
FROM gl
LEFT JOIN wt ON wt.po_no = gl.po_no AND wt.line_no = gl.line_no
WHERE wt.po_no IS NULL
ORDER BY gl.po_no, gl.line_no
LIMIT 200;

-- 10) Lines missing ANY worktags (service)
WITH sl AS (
  SELECT DISTINCT "*No." AS po_no, "Line Number" AS line_no
  FROM service_line2
),
wt AS (
  SELECT DISTINCT "*No." AS po_no, "*Service Line Replacement Data Line No" AS line_no
  FROM service_worktags_8011501
)
SELECT sl.po_no, sl.line_no
FROM sl
LEFT JOIN wt ON wt.po_no = sl.po_no AND wt.line_no = sl.line_no
WHERE wt.po_no IS NULL
ORDER BY sl.po_no, sl.line_no
LIMIT 200;

-- 11) Excessive number of worktags per line (heuristic)
-- Goods: expected <= 2 (DEPTID + PROJECT_ID)
SELECT "*No." AS po_no,
       "*Goods Line Replacement Data Line No" AS line_no,
       COUNT(*) AS wt_cnt
FROM good_worktags_8011501
GROUP BY "*No.", "*Goods Line Replacement Data Line No"
HAVING COUNT(*) > 2
ORDER BY wt_cnt DESC, po_no, line_no
LIMIT 200;

-- Service: expected <= 3 (DEPTID + PROJECT_ID + FUND_CODE)
SELECT "*No." AS po_no,
       "*Service Line Replacement Data Line No" AS line_no,
       COUNT(*) AS wt_cnt
FROM service_worktags_8011501
GROUP BY "*No.", "*Service Line Replacement Data Line No"
HAVING COUNT(*) > 3
ORDER BY wt_cnt DESC, po_no, line_no
LIMIT 200;

-- 12) Basic format sanity:
-- Dept worktags are expected to look like CC_<OU>-<DEPTID> (based on the SQL generation)
SELECT *
FROM good_worktags_8011501
WHERE "*Worktags" LIKE 'CC_%'
  AND "*Worktags" NOT LIKE 'CC_%-%'
LIMIT 200;

SELECT *
FROM service_worktags_8011501
WHERE "*Worktags" LIKE 'CC_%'
  AND "*Worktags" NOT LIKE 'CC_%-%'
LIMIT 200;

-- 13) Ensure no PO- prefix sneaked into worktags extracts
SELECT 'goods' AS src, "*No." AS po_no
FROM good_worktags_8011501
WHERE "*No." LIKE 'PO-%'
UNION ALL
SELECT 'service' AS src, "*No." AS po_no
FROM service_worktags_8011501
WHERE "*No." LIKE 'PO-%'
LIMIT 200;

