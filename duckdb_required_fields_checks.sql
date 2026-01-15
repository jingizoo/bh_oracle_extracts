
/* Required-fields checks (DuckDB) */

-- 1) Goods lines where ANY of these header fields are NULL/blank:
--    - Bill To Contact Detail
--    - Ship To Contact Worker ID
--    - Ship To Contact Detail
SELECT
  g.no AS po_no,
  g.line_number AS line_number,
  h.bill_to_contact_detail AS bill_to_contact_detail,
  h.ship_to_contact_worker_id AS ship_to_contact_worker_id,
  h.ship_to_contact_detail AS ship_to_contact_detail
FROM goods_line g
JOIN po_header h
  ON h.no = g.no
WHERE h.bill_to_contact_detail IS NULL OR h.bill_to_contact_detail = ''
   OR h.ship_to_contact_worker_id IS NULL OR h.ship_to_contact_worker_id = ''
   OR h.ship_to_contact_detail IS NULL OR h.ship_to_contact_detail = ''
ORDER BY po_no, line_number;

-- 2) Service lines where Resource Category is NULL/blank
SELECT *
FROM service_line
WHERE resource_category IS NULL OR resource_category = ''
ORDER BY no, line_number;

-- 2b) Goods lines: Resource Category is required ONLY when Item (inventory item id) is NULL/blank
--     (because goods_line sets Resource Category blank when Item is present)
SELECT
  no AS po_no,
  line_number,
  item AS inventory_item_id,
  resource_category
FROM goods_line
WHERE (item IS NULL OR item = '')
  AND (resource_category IS NULL OR resource_category = '')
ORDER BY po_no, line_number;

-- 3) PO headers where Close Status is NULL/blank
SELECT *
FROM po_header
WHERE close_status IS NULL OR close_status = ''
ORDER BY no;

