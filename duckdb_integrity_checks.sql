
SELECT
  (SELECT COUNT(*) FROM po_header)  AS hdr_rows,
  (SELECT COUNT(*) FROM goods_po_line)        AS goods_rows,
  (SELECT COUNT(*) FROM service_po_line)      AS service_rows;




-- 2) Distinct PO counts + union PO count from lines
SELECT
  (SELECT COUNT(DISTINCT "No") FROM po_header) AS hdr_pos,
  (SELECT COUNT(DISTINCT "No") FROM goods_po_line)       AS goods_pos,
  (SELECT COUNT(DISTINCT "No") FROM service_po_line)     AS service_pos,
  (SELECT COUNT(DISTINCT po_no)
     FROM (SELECT "No" AS po_no FROM goods_po_line
           UNION ALL
           SELECT "No" AS po_no FROM service_po_line))   AS line_pos_union;



-- 3) POs in lines but missing header
WITH line_pos AS (
  SELECT DISTINCT "No" AS po_no FROM goods_po_line
  UNION
  SELECT DISTINCT "No" AS po_no FROM service_po_line
),
hdr_pos AS (
  SELECT DISTINCT "No" AS po_no FROM po_header
)
SELECT lp.po_no
FROM line_pos lp
LEFT JOIN hdr_pos hp ON hp.po_no = lp.po_no
WHERE hp.po_no IS NULL
ORDER BY lp.po_no;

-- 4) Header POs with no lines
WITH line_pos AS (
  SELECT DISTINCT "No" AS po_no FROM goods_po_line
  UNION
  SELECT DISTINCT "No" AS po_no FROM service_po_line
)
SELECT h."No", h."Purchase_Order_Type" AS po_no
FROM po_header h
JOIN Service_flag_Po_list S ON h."No" = s."po_id"
LEFT JOIN line_pos lp ON lp.po_no = h."No"
WHERE lp.po_no IS NULL
ORDER BY po_no;

-- 5) POs that appear in BOTH goods and service (should be ~0 if classification is mutually exclusive)
WITH g AS (SELECT DISTINCT "No" AS po_no FROM goods_po_line),
     s AS (SELECT DISTINCT "No" AS po_no FROM service_po_line)
SELECT g.po_no
FROM g
JOIN s ON s.po_no = g.po_no
ORDER BY g.po_no;

-- 6) Duplicate header rows per PO
SELECT "No" AS po_no, COUNT(*) AS cnt
FROM po_header
GROUP BY "No"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 7) Duplicate goods line keys per PO/Line Number
--SELECT "No" AS po_no, "Line Number", COUNT(*) AS cnt
SELECT "Goods_Purchase_Order_Line_ID" , COUNT(*) AS cnt
FROM goods_po_line
GROUP BY "Goods_Purchase_Order_Line_ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, "Goods_Purchase_Order_Line_ID";

-- 8) Duplicate service line keys per PO/Line Number
-- SELECT "No" AS po_no, "Line Number", COUNT(*) AS cnt
SELECT "Service_Order_Line_ID" , COUNT(*) AS cnt
FROM service_po_line
GROUP BY "Service_Order_Line_ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, "Service_Order_Line_ID"; -- relevant only till 8

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
or h.Bill_To_Contact_Worker_ID is null or h.Bill_To_Contact_Worker_ID=''
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
FROM goods_po_line
WHERE close_status IS NULL OR close_status = ''
ORDER BY no;

-- 9a)Delivery_Type check. All PO marked as Inventory should have delivery type as Inventory Replenishment.
select h.no, h.Purchase_Order_Type from po_header h 
where h.Purchase_Order_Type='Inventory'
and h.no not in ( select distinct g.no
from goods_po_line g where g.Delivery_Type='Inventory_Replenishment');

--9b)--check if purchase items listed in exception are still present in extract.
 select distinct  g.Item
from goods_po_line g where g.Item in (
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
SELECT "No" AS po_no, "Goods Purchase Order Line ID", COUNT(*) AS cnt
FROM goods_po_line
GROUP BY "No", "Goods Purchase Order Line ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 10) Duplicate Workday Line IDs (service)
SELECT "No" AS po_no, "Service Order Line ID", COUNT(*) AS cnt
FROM service_po_line
GROUP BY "No", "Service Order Line ID"
HAVING COUNT(*) > 1
ORDER BY cnt DESC, po_no;

-- 11) Ensure no PO- prefix sneaked back into keys
SELECT *
FROM (
  SELECT "No" AS id, 'hdr' AS src FROM po_header
  UNION ALL
  SELECT "No" AS id, 'goods' AS src FROM goods_po_line
  UNION ALL
  SELECT "No" AS id, 'service' AS src FROM service_po_line
)
WHERE id LIKE 'PO-%'
LIMIT 50;

-- 12) Fully paid lines should be excluded (goods)
SELECT *
FROM goods_po_line
WHERE COALESCE("Extended Amount", 0) <= 1
LIMIT 50;

-- 13) Fully paid lines should be excluded (service)
SELECT *
FROM service_po_line
WHERE COALESCE("Extended Amount", 0) <= 1
LIMIT 50;

-- 14) Service item should be blank
SELECT *
FROM service_po_line
WHERE COALESCE(TRIM("Item"), '') <> ''
LIMIT 50;

-- 15) Required header fields null/blank (adjust list as needed)
SELECT *
FROM po_header
WHERE COALESCE(TRIM("No"), '') = ''
   OR COALESCE(TRIM("*Company"), '') = ''
   OR COALESCE(TRIM("*Supplier"), '') = ''
LIMIT 50;

-- 16) Required goods line fields null/blank (adjust list as needed)
SELECT *
FROM goods_po_line
WHERE COALESCE(TRIM("No"), '') = ''
   OR "Line Number" IS NULL
   OR COALESCE(TRIM("*Quantity"), '') = ''
   OR COALESCE(TRIM("*Unit of Measure"), '') = ''
LIMIT 50;

-- 17) Required service line fields null/blank (adjust list as needed)
SELECT *
FROM service_po_line
WHERE COALESCE(TRIM("No"), '') = ''
   OR "Line Number" IS NULL
   OR COALESCE(TRIM("*Resource Category"), '') = ''
LIMIT 50;

-- 18) Total extended amount per PO (goods + service), top 50
WITH all_lines AS (
  SELECT "No" AS po_no, COALESCE("Extended Amount",0) AS amt FROM goods_po_line
  UNION ALL
  SELECT "No" AS po_no, COALESCE("Extended Amount",0) AS amt FROM service_po_line
)
SELECT po_no, SUM(amt) AS total_extended_amt, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY total_extended_amt DESC
LIMIT 50;

-- 19) POs with suspiciously high line counts
WITH all_lines AS (
  SELECT "No" AS po_no FROM goods_po_line
  UNION ALL
  SELECT "No" AS po_no FROM service_po_line
)
SELECT po_no, COUNT(*) AS line_cnt
FROM all_lines
GROUP BY po_no
ORDER BY line_cnt DESC
LIMIT 50;

-- 20) Goods lines where Item is blank (review)
SELECT *
FROM goods_po_line
WHERE COALESCE(TRIM("Item"), '') = ''
LIMIT 50;

-- 25) Worktags Service
select distinct s.no as serv_worktag from service_line_worktags s 
where not exists (select 'Y' from service_po_line w where w.no=s.no);

-- 26) Worktags Goods
select distinct s.no as goods_worktag from goods_line_worktags s 
where not exists (select 'Y' from goods_po_line w where w.no=s.no);