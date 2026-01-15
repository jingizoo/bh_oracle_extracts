WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt FROM dual
),


hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status,
         h.vendor_id,
         h.buyer_id,
         h.currency_cd,
         h.poa_status
    FROM ps_po_hdr h
    CROSS JOIN params p
   WHERE h.po_dt <= p.asof_dt
     AND h.po_status NOT IN ('C','X')
),


recv_agg AS (
  SELECT r.business_unit_po AS business_unit,
         r.po_id,
         r.line_nbr,
         r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd_suom, 0))   AS qty_rcvd_suom,
         SUM(NVL(r.merchandise_amt_po, 0))  AS merch_amt_rcvd_po
    FROM ps_recv_ln_ship r
    JOIN hdr_candidates hc
      ON hc.business_unit = r.business_unit_po
     AND hc.po_id         = r.po_id
    CROSS JOIN params p
   WHERE r.recv_ship_status <> 'X'
     AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
   GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),

/* Schedule open/closed based on not fully received (restricted to header candidates) */
sched_open AS (
  SELECT s.business_unit,
         s.po_id,
         s.line_nbr,
         s.sched_nbr,
         s.cancel_status,
         s.due_dt,
         s.shipto_setid,
         s.shipto_id,
         s.freight_terms,
         s.ship_type_id,
         s.qty_po,
         s.merchandise_amt,
         s.liquidate_method,
         NVL(r.qty_rcvd_suom, 0)       AS qty_rcvd_suom,
         NVL(r.merch_amt_rcvd_po, 0)   AS merch_amt_rcvd_po,
         CASE
           WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
           WHEN s.liquidate_method = 'A' THEN
                CASE WHEN NVL(s.merchandise_amt,0) > NVL(r.merch_amt_rcvd_po,0) THEN 1 ELSE 0 END
           ELSE
                CASE WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0) THEN 1 ELSE 0 END
         END AS is_open
    FROM ps_po_line_ship s
    JOIN hdr_candidates hc
      ON hc.business_unit = s.business_unit
     AND hc.po_id         = s.po_id
    LEFT JOIN recv_agg r
      ON r.business_unit  = s.business_unit
     AND r.po_id          = s.po_id
     AND r.line_nbr       = s.line_nbr
     AND r.sched_nbr      = s.sched_nbr
),

open_pos AS (
  SELECT /*+ MATERIALIZE */
         hc.business_unit,
         hc.po_id
    FROM hdr_candidates hc
   WHERE EXISTS (
         SELECT 1
           FROM sched_open so
          WHERE so.business_unit = hc.business_unit
            AND so.po_id         = hc.po_id
            AND so.is_open       = 1
       )
),


first_open_sched AS (
  SELECT business_unit,
         po_id,
         MAX(shipto_setid)  KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS shipto_setid,
         MAX(shipto_id)     KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS shipto_id,
         MAX(freight_terms) KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS freight_terms,
         MAX(ship_type_id)  KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS ship_type_id
    FROM sched_open
   WHERE is_open = 1
   GROUP BY business_unit, po_id
),

/* Location (effective dated) */
loc_max AS (
  SELECT l.setid,
         l.location,
         MAX(l.effdt) AS effdt
    FROM ps_location_tbl l
    CROSS JOIN params p
   WHERE l.effdt <= p.asof_dt
     AND l.eff_status = 'A'
   GROUP BY l.setid, l.location
),
location_eff AS (
  SELECT l.setid,
         l.location,
         l.attn_to,
         l.address1, l.address2, l.address3, l.address4,
         l.city, l.state, l.postal, l.country
    FROM ps_location_tbl l
    JOIN loc_max m
      ON m.setid    = l.setid
     AND m.location = l.location
     AND m.effdt    = l.effdt
),

po_comments_clean AS (
  SELECT b.business_unit,
         b.po_id,
         b.public_flg,
         b.comment_id,
         b.random_cmmt_nbr,
         REGEXP_REPLACE(t.comments_2000, '[^[:print:]]', ' ') AS clean_comment
    FROM open_pos op
    JOIN ps_po_comments b
      ON b.business_unit = op.business_unit
     AND b.po_id         = op.po_id
    JOIN ps_comments_tbl t
      ON t.oprid           = b.oprid
     AND t.comment_id      = b.comment_id
     AND t.random_cmmt_nbr = b.random_cmmt_nbr
   WHERE t.comments_2000 IS NOT NULL
),
Pull_Comments AS (
  SELECT
      x.business_unit,
      x.po_id,
      RTRIM(
        XMLCAST(
          XMLAGG(
            CASE
              WHEN x.public_flg = 'Y' THEN
                XMLELEMENT(e, XMLCDATA(x.clean_comment || ' | '))
            END
            ORDER BY x.comment_id, x.random_cmmt_nbr
          ) AS CLOB
        ),
        ' | '
      ) AS memo,
      RTRIM(
        XMLCAST(
          XMLAGG(
            CASE
              WHEN x.public_flg <> 'Y' THEN
                XMLELEMENT(e, XMLCDATA(x.clean_comment || ' | '))
            END
            ORDER BY x.comment_id, x.random_cmmt_nbr
          ) AS CLOB
        ),
        ' | '
      ) AS internal_memo
    FROM po_comments_clean x
   GROUP BY x.business_unit, x.po_id
),

/* ===== POTYPE (fixed + aggregated to 1 row/PO) ===== */
par_cons_items AS (
  SELECT /*+ MATERIALIZE */ DISTINCT bh_xwlk_s3 AS inv_item_id
    FROM ps_bh_xwlk_val_tbl
   WHERE longname = 'WD_PAR_CONS_NONSTOCK'
     AND bh_xwlk_s3 IS NOT NULL
),
cm_items AS (
  SELECT /*+ MATERIALIZE */ DISTINCT cm.business_unit, cm.inv_item_id
    FROM ps_cm_item_method cm
    JOIN ps_bu_items_inv it
      ON it.business_unit = cm.business_unit
     AND it.inv_item_id   = cm.inv_item_id
),
po_item_flags AS (
  SELECT l.business_unit,
         l.po_id,
         MAX(CASE WHEN pci.inv_item_id IS NOT NULL THEN 1 ELSE 0 END) AS has_par_cons,
         MAX(CASE WHEN cmi.inv_item_id IS NOT NULL THEN 1 ELSE 0 END) AS has_cm_item
    FROM open_pos op
    JOIN ps_po_line l
      ON l.business_unit = op.business_unit
     AND l.po_id         = op.po_id
    LEFT JOIN par_cons_items pci
      ON pci.inv_item_id = l.inv_item_id
    LEFT JOIN cm_items cmi
      ON cmi.business_unit = l.business_unit
     AND cmi.inv_item_id   = l.inv_item_id
   GROUP BY l.business_unit, l.po_id
),
po_dist_flags AS (
  SELECT d.business_unit,
         d.po_id,
         MAX(CASE WHEN d.deptid = '20100' THEN 1 ELSE 0 END) AS has_inventory_dept,
         MAX(CASE WHEN rl.ln_type = 'DCPO' THEN 1 ELSE 0 END) AS has_dcpo
    FROM open_pos op
    JOIN ps_po_line_distrib d
      ON d.business_unit = op.business_unit
     AND d.po_id         = op.po_id
    LEFT JOIN ps_req_line rl
      ON rl.business_unit = d.business_unit
     AND rl.req_id        = d.req_id
     AND rl.line_nbr      = d.req_line_nbr   -- **CRITICAL FIX**
   GROUP BY d.business_unit, d.po_id
),
Pull_POTYPE AS (
  SELECT op.business_unit,
         op.po_id,
         CASE
           WHEN h.buyer_id = 'BILLONLY'         THEN 'Bill Only'
           WHEN h.buyer_id = 'BH_CAPITAL_BUYER' THEN 'Capital'
           WHEN df.has_inventory_dept = 1       THEN 'Inventory'
           WHEN df.has_dcpo = 1                 THEN 'Punchout'
           WHEN ifl.has_par_cons = 1            THEN 'Par Consignment'
           WHEN ifl.has_cm_item = 1             THEN 'Consignment bill and replace'
           ELSE 'Supplies'
         END AS POTYPE
    FROM open_pos op
    JOIN hdr_candidates h
      ON h.business_unit = op.business_unit
     AND h.po_id         = op.po_id
    LEFT JOIN po_dist_flags df
      ON df.business_unit = op.business_unit
     AND df.po_id         = op.po_id
    LEFT JOIN po_item_flags ifl
      ON ifl.business_unit = op.business_unit
     AND ifl.po_id         = op.po_id
),

/* ===== Procedure info (restricted + aggregated to 1 row/PO) ===== */
consign_info AS (
  SELECT /*+ MATERIALIZE */
         a.business_unit,
         a.req_id,
         a.bh_medrec_no,
         a.bh_har_num,
         a.bh_procede_dt
    FROM ps_bh_consgn_hdr a
   WHERE EXISTS (
         SELECT 1
           FROM ps_bh_consgn_line b
          WHERE b.business_unit = a.business_unit
            AND b.req_id        = a.req_id
       )
),
Pull_ProcedureInfo AS (
  SELECT op.business_unit,
         op.po_id,
         MIN(ci.bh_medrec_no) KEEP (DENSE_RANK FIRST ORDER BY ci.bh_procede_dt NULLS LAST) AS MRN,
         MIN(ci.bh_procede_dt) KEEP (DENSE_RANK FIRST ORDER BY ci.bh_procede_dt NULLS LAST) AS PHDATE,
         MIN(ci.bh_har_num)   KEEP (DENSE_RANK FIRST ORDER BY ci.bh_procede_dt NULLS LAST) AS HAR
    FROM open_pos op
    JOIN ps_po_line_distrib d
      ON d.business_unit = op.business_unit
     AND d.po_id         = op.po_id
    LEFT JOIN consign_info ci
      ON ci.business_unit = d.business_unit
     AND ci.req_id        = d.req_id
   GROUP BY op.business_unit, op.po_id
)

SELECT
    h.po_id                                                                                   AS "*No.",
    'Y'                                                                                       AS "Add Only",
    NULL                                                                                      AS "Purchase Orders For Updates",
    h.po_id                                                                                   AS "Purchase Order ID",
    'Y'                                                                                       AS "Submit",
    'N'                                                                                       AS "Locked in Workday",
    h.po_id                                                                                   AS "Document Number",

    NULL                                                                                      AS "Invoice Status",
    NULL                                                                                      AS "Payment Status",
    NULL                                                                                      AS "Receiving Status",
    NULL                                                                                      AS "Shipping Status",
    NULL                                                                                      AS "Tracking Status",

    'CO_80800'                                                                                AS "*Company",
    'WD Supplier Id'                                                                          AS "*Supplier",

    ppt.POTYPE                                                                                AS "Purchase Order Type",
    NULL                                                                                      AS "External PO Number",
    NULL                                                                                      AS "Order From Supplier Connection",

    TO_CHAR(h.po_dt,'YYYY-MM-DD')                                                             AS "*Document Date",

    NULL                                                                                      AS "Tax Amount",
    NULL                                                                                      AS "Freight Amount",
    NULL                                                                                      AS "Other Charges",

    NULL                                                                                      AS "Payment Terms",
    NULL                                                                                      AS "Override Payment Type",
    NULL                                                                                      AS "Procurement Credit Card",

    NULL                                                                                      AS "Shipping Terms",
    NULL                                                                                      AS "Shipping Method",
    NULL                                                                                      AS "Shipping Instruction",

    NULL                                                                                      AS "Due Date",

    NULL                                                                                      AS "Supplier Contract",
    h.currency_cd                                                                             AS "Currency",
    CASE h.poa_status
      WHEN 'AC' THEN 'Y'
      WHEN 'AK' THEN 'Y'
      ELSE 'N'
    END                                                                                       AS "Acknowledgement Expected",

    NULL                                                                                      AS "Default Tax Option",
    NULL                                                                                      AS "Default Tax Code",
    'Phone'                                                                                   AS "Issue Option",

    'Y'                                                                                       AS "Buyer Is Employee",
    'Sourcing Rule'                                                                           AS "Buyer Worker ID",

    'Y'                                                                                       AS "Bill To Contact Is Employee",
    'Sourcing Rule'                                                                           AS "Bill To Contact Worker ID",
    'User name based on Sourcing Rule'                                                        AS "Bill To Contact Detail",
    'PwC to provide mapping for bill to address'                                              AS "Bill To Address",
    NULL                                                                                      AS "Bill To Address ID",

    'TBD'                                                                                     AS "Ship To Contact Is Employee",
    'TBD'                                                                                     AS "Ship To Contact Worker ID",
    'User name based on Sourcing Rule'                                                        AS "Ship To Contact Detail",

    ' '                                                                                       AS "Ship To Address",
    INITCAP(
      'SHIP_TO_' ||
      REPLACE(
        SUBSTR(sh_loc.address1,1,11) || '_' ||
        SUBSTR(sh_loc.city,1,5)      ||
        sh_loc.state                 ||
        SUBSTR(sh_loc.postal,1,5),
        ' ',''
      )
    ) || fos.shipto_id                                                                         AS "Ship To Address ID",

    NULL                                                                                      AS "Document Link",
    pc.memo                                                                                   AS "Memo",
    pc.internal_memo                                                                          AS "Internal Memo",

    NULL                                                                                      AS "Prepaid",
    NULL                                                                                      AS "Prepayment Release Type",
    NULL                                                                                      AS "Expected Release Date",
    NULL                                                                                      AS "Frequency",
    NULL                                                                                      AS "Number of Prepayment Installments",
    NULL                                                                                      AS "Use Invoice Date",
    NULL                                                                                      AS "Specified Date",
    NULL                                                                                      AS "Use Prepaid Posting Rules for Receipt Accruals",
    NULL                                                                                      AS "Percent to Retain",
    NULL                                                                                      AS "Estimated Retention Release Date",
    NULL                                                                                      AS "XMLNAME 3rd Party Retention",
    NULL                                                                                      AS "Retention Memo",
    NULL                                                                                      AS "Down Payment Amount",
    NULL                                                                                      AS "Down Payment Percentage",
    NULL                                                                                      AS "Down Payment Memo",

    TO_CHAR(ph.PHDATE,'YYYY-MM-DD')                                                           AS "Procedure Date",
    NULL                                                                                      AS "Procedure",
    ph.HAR                                                                                    AS "Procedure Number",
    NULL                                                                                      AS "Patient ID",
    ph.MRN                                                                                    AS "Medical Record Number",
    NULL                                                                                      AS "Physician ID",
    NULL                                                                                      AS "Verified By",
    NULL                                                                                      AS "Supplier Representative",
    NULL                                                                                      AS "Additional Procedure Details"

FROM open_pos op
JOIN hdr_candidates h
  ON h.business_unit = op.business_unit
 AND h.po_id         = op.po_id

JOIN ps_bus_unit_tbl_pm bu
  ON bu.business_unit = h.business_unit

LEFT JOIN first_open_sched fos
  ON fos.business_unit = h.business_unit
 AND fos.po_id         = h.po_id

LEFT JOIN location_eff sh_loc
  ON sh_loc.setid    = fos.shipto_setid
 AND sh_loc.location = fos.shipto_id

LEFT JOIN Pull_Comments pc
  ON pc.business_unit = h.business_unit
 AND pc.po_id         = h.po_id

LEFT JOIN Pull_POTYPE ppt
  ON ppt.business_unit = h.business_unit
 AND ppt.po_id         = h.po_id

LEFT JOIN Pull_ProcedureInfo ph
  ON ph.business_unit = h.business_unit
 AND ph.po_id         = h.po_id

ORDER BY h.business_unit, h.po_id;
