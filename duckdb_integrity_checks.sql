
SELECT
  (SELECT COUNT(*) FROM po_header)  AS hdr_rows,
  (SELECT COUNT(*) FROM goods_po_line)        AS goods_rows,
  (SELECT COUNT(*) FROM service_po_line)      AS service_rows;




-- 2) Distinct PO counts + union PO count from lines
SELECT
  (SELECT COUNT(DISTINCT no) FROM po_header) AS hdr_pos,
  (SELECT COUNT(DISTINCT no) FROM goods_po_line)       AS goods_pos,
  (SELECT COUNT(DISTINCT no) FROM service_po_line)     AS service_pos,
  (SELECT COUNT(DISTINCT po_no)
     FROM (SELECT no AS po_no FROM goods_po_line
           UNION ALL
           SELECT no AS po_no FROM service_po_line))   AS line_pos_union;



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
SELECT h.no AS po_no, h.purchase_order_type
FROM po_header h
LEFT JOIN line_pos lp ON lp.po_no = h.no
WHERE lp.po_no IS NULL
ORDER BY po_no;

-- 5) POs that appear in BOTH goods and service (should be ~0 if classification is mutually exclusive)
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
--SELECT "No" AS po_no, "Line Number", COUNT(*) AS cnt
SELECT goods_purchase_order_line_id, COUNT(*) AS cnt
FROM goods_po_line
GROUP BY goods_purchase_order_line_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC, goods_purchase_order_line_id;

-- 8) Duplicate service line keys per PO/Line Number
-- SELECT "No" AS po_no, "Line Number", COUNT(*) AS cnt
SELECT service_order_line_id, COUNT(*) AS cnt
FROM service_po_line
GROUP BY service_order_line_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC, service_order_line_id; -- relevant only till 8

SELECT
  g.no AS po_no,
  g.line_number AS line_number,
  h.bill_to_contact_detail AS bill_to_contact_detail,
  h.ship_to_contact_worker_id AS ship_to_contact_worker_id,
  h.ship_to_contact_detail AS ship_to_contact_detail
FROM goods_po_line g
JOIN po_header h
  ON h.no = g.no
WHERE h.bill_to_contact_detail IS NULL OR trim(h.bill_to_contact_detail) = ''
   OR h.ship_to_contact_worker_id IS NULL OR h.ship_to_contact_worker_id = ''
   OR h.ship_to_contact_detail IS NULL OR trim(h.ship_to_contact_detail) = ''
   OR h.bill_to_contact_worker_id IS NULL OR trim(h.bill_to_contact_worker_id) = ''
ORDER BY po_no, line_number;

-- 2) Service lines where Resource Category is NULL/blank
SELECT *
FROM service_po_line
WHERE resource_category IS NULL OR resource_category = ''
ORDER BY no, line_number;

-- 2b) Goods lines: Resource Category is required ONLY when Item (inventory item id) is NULL/blank
--     (because goods_po_line sets Resource Category blank when Item is present)
SELECT
  no AS po_no,
  line_number,
  item AS inventory_item_id,
  resource_category
FROM goods_po_line
WHERE (item IS NULL OR item = '')
  AND (resource_category IS NULL OR resource_category = '')
ORDER BY po_no, line_number;

-- 3) PO headers where Close Status is NULL/blank
SELECT *
FROM po_header
WHERE close_status IS NULL OR close_status = ''
ORDER BY no;

-- 9a)Delivery_Type check. All PO marked as Inventory should have delivery type as Inventory Replenishment.
select h.no, h.purchase_order_type from po_header h 
where h.purchase_order_type='Inventory'
and h.no not in ( select distinct g.no
from goods_po_line g where g.delivery_type='Inventory_Replenishment');

--9b)--check if purchase items listed in exception are still present in extract.
 select distinct  g.item
from goods_po_line g where g.item in (
'308593',
'315953',
'314740',
'206048',
'345368',
'207782',
'25229',
'346750',
'16567',
'142460',
'101445',
'311726');

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

-- 15) Required header fields null/blank (adjust list as needed)
SELECT *
FROM po_header
WHERE COALESCE(TRIM(no), '') = ''
   OR COALESCE(TRIM(company), '') = ''
   OR COALESCE(TRIM(supplier), '') = ''
LIMIT 50;

-- 16) Required goods line fields null/blank (adjust list as needed)
SELECT *
FROM goods_po_line
WHERE COALESCE(TRIM(no), '') = ''
   OR line_number IS NULL
   OR COALESCE(TRIM(quantity), '') = ''
   OR COALESCE(TRIM(unit_of_measure), '') = ''
LIMIT 50;

-- 17) Required service line fields null/blank (adjust list as needed)
SELECT *
FROM service_po_line
WHERE COALESCE(TRIM(no), '') = ''
   OR line_number IS NULL
   OR COALESCE(TRIM(resource_category), '') = ''
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

-- 25) Worktags Service
select distinct s.no as serv_worktag from service_line_worktags s 
where not exists (select 'Y' from service_po_line w where w.no=s.no);

-- 26) Worktags Goods
select distinct s.no as goods_worktag from goods_line_worktags s 
where not exists (select 'Y' from goods_po_line w where w.no=s.no);