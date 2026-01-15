WITH
params AS (
  SELECT sysdate AS asof_dt FROM dual
),
setids AS (
    SELECT setcntrlvalue AS business_unit,
           MAX(CASE WHEN recname = 'VENDOR'       THEN setid END) AS setid_vendor,
           MAX(CASE WHEN recname = 'LOCATION_TBL' THEN setid END) AS setid_location
      FROM ps_set_cntrl_rec
     WHERE recname IN ('VENDOR','LOCATION_TBL')
     GROUP BY setcntrlvalue
),

/* Receipts aggregated by PO schedule as-of */
recv_agg AS (
    SELECT r.business_unit_po AS business_unit,
           r.po_id,
           r.line_nbr,
           r.sched_nbr,
           SUM(NVL(r.qty_sh_recvd_suom, 0))   AS qty_rcvd_suom,
           SUM(NVL(r.merchandise_amt_po, 0))  AS merch_amt_rcvd_po
      FROM ps_recv_ln_ship r
      CROSS JOIN params p
     WHERE r.recv_ship_status <> 'X'
       AND r.receipt_dttm < (CAST(p.asof_dt AS TIMESTAMP) + INTERVAL '1' DAY)
     GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),

/* Schedule open/closed based on not fully received */
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
      LEFT JOIN recv_agg r
        ON r.business_unit = s.business_unit
       AND r.po_id         = s.po_id
       AND r.line_nbr      = s.line_nbr
       AND r.sched_nbr     = s.sched_nbr
),

/* POs with at least one open schedule */
open_pos AS (
    SELECT DISTINCT h.business_unit, h.po_id
      FROM ps_po_hdr h
      JOIN sched_open so
        ON so.business_unit = h.business_unit
       AND so.po_id         = h.po_id
       AND so.is_open       = 1
      CROSS JOIN params p
     WHERE h.po_dt <= p.asof_dt
       AND h.po_status NOT IN ('C','X')   -- FIXED
),

/* Pick ONE open schedule per PO for header-level ShipTo + shipping terms/method */
first_open_sched AS (
    SELECT business_unit,
           po_id,
           shipto_setid,
           shipto_id,
           freight_terms,
           ship_type_id
      FROM (
            SELECT so.*,
                   ROW_NUMBER() OVER
                     (PARTITION BY so.business_unit, so.po_id
                      ORDER BY so.line_nbr, so.sched_nbr) rn
              FROM sched_open so
             WHERE so.is_open = 1
           )
     WHERE rn = 1
),

/* Earliest due date among open schedules */
min_due AS (
    SELECT business_unit, po_id, MIN(due_dt) AS min_due_dt
      FROM sched_open
     WHERE is_open = 1
     GROUP BY business_unit, po_id
),

/* Location (effective dated) */
location_eff AS (
    SELECT l.setid,
           l.location,
           l.attn_to,
           l.address1, l.address2, l.address3, l.address4,
           l.city, l.state, l.postal, l.country
      FROM ps_location_tbl l
      CROSS JOIN params p
     WHERE l.effdt = (
           SELECT MAX(l2.effdt)
             FROM ps_location_tbl l2
            WHERE l2.setid    = l.setid
              AND l2.location = l.location
              AND l2.effdt   <= p.asof_dt
     )
       AND l.eff_status = 'A'
),

/* Receiving status at PO header */
recv_status_po AS (
    SELECT so.business_unit,
           so.po_id,
           CASE
             WHEN SUM(
                    CASE
                      WHEN NVL(so.cancel_status,' ') IN ('C','X') THEN 0
                      WHEN so.liquidate_method = 'A' AND NVL(so.merch_amt_rcvd_po,0) > 0 THEN 1
                      WHEN so.liquidate_method <> 'A' AND NVL(so.qty_rcvd_suom,0) > 0 THEN 1
                      ELSE 0
                    END
                  ) = 0
                  THEN 'Not Received'
             WHEN SUM(CASE WHEN NVL(so.cancel_status,' ') IN ('C','X') THEN 0 ELSE so.is_open END) = 0
                  THEN 'Fully Received'
             ELSE 'Partially Received'
           END AS receiving_status
      FROM sched_open so
     GROUP BY so.business_unit, so.po_id
),

/* Voucher aggregation by PO schedule (Invoice status) */
vchr_sched_agg AS (
    SELECT vl.business_unit_po AS business_unit,
           vl.po_id,
           vl.line_nbr,
           vl.sched_nbr,
           SUM(NVL(vl.qty_vchr,0))         AS qty_invoiced,
           SUM(NVL(vl.merchandise_amt,0))  AS amt_invoiced,
           COUNT(DISTINCT vl.business_unit || ':' || vl.voucher_id) AS voucher_cnt
      FROM ps_voucher_line vl
      JOIN ps_voucher v
        ON v.business_unit = vl.business_unit
       AND v.voucher_id    = vl.voucher_id
      JOIN open_pos op
        ON op.business_unit = vl.business_unit_po
       AND op.po_id         = vl.po_id
      CROSS JOIN params p
     WHERE vl.po_id IS NOT NULL
       AND vl.business_unit_po IS NOT NULL
       AND v.invoice_dt <= p.asof_dt
     GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, vl.sched_nbr
),

invoice_status_po AS (
    SELECT so.business_unit,
           so.po_id,
           CASE
             WHEN SUM(NVL(vs.voucher_cnt,0)) = 0 THEN 'Not Invoiced'
             WHEN SUM(
                    CASE
                      WHEN NVL(so.cancel_status,' ') IN ('C','X') THEN 0
                      WHEN so.liquidate_method = 'A'
                           AND NVL(vs.amt_invoiced,0) >= NVL(so.merchandise_amt,0) THEN 0
                      WHEN so.liquidate_method <> 'A'
                           AND NVL(vs.qty_invoiced,0) >= NVL(so.qty_po,0) THEN 0
                      ELSE 1
                    END
                  ) > 0 THEN 'Partially Invoiced'
             ELSE 'Fully Invoiced'
           END AS invoice_status
      FROM sched_open so
      LEFT JOIN vchr_sched_agg vs
        ON vs.business_unit = so.business_unit
       AND vs.po_id         = so.po_id
       AND vs.line_nbr      = so.line_nbr
       AND vs.sched_nbr     = so.sched_nbr
     GROUP BY so.business_unit, so.po_id
),

Pull_POTYPE AS ( SELECT DISTINCT
           h.business_unit,
           h.po_id,
           CASE
             WHEN h.buyer_id = 'BILLONLY'         THEN 'Bill Only'
             WHEN h.buyer_id = 'BH_CAPITAL_BUYER' THEN 'Capital'
             WHEN d.deptid   = '20100'            THEN 'Inventory'
             WHEN rl.ln_type = 'DCPO'              THEN 'Punchout'
		 WHEN EXISTS (select DISTINCT 'Y' from ps_po_line l WHERE l.inv_item_id IN (select BH_XWLK_S3 from ps_BH_XWLK_VAL_TBL where LONGNAME = 'WD_PAR_CONS_NONSTOCK' )
AND l.PO_ID=h.po_id and l.business_unit = h.business_unit) then 'Par Consignment'
             WHEN EXISTS (select DISTINCT 'Y' from ps_po_line l WHERE l.inv_item_id IN ( select cm.inv_item_id from ps_CM_ITEM_METHOD CM, ps_BU_ITEMS_INV IT WHERE 
             CM.BUSINESS_UNIT=IT.BUSINESS_UNIT AND CM.INV_ITEM_ID=IT.INV_ITEM_ID and CM.BUSINESS_UNIT =h.business_unit) 
             AND l.PO_ID=h.po_id and l.business_unit = h.business_unit) THEN 'Consignment bill and replace'	
             
             ELSE 'Supplies'
           END AS POTYPE
      FROM ps_po_hdr h
     /* JOIN ps_po_line pl
        ON pl.business_unit = h.business_unit
       AND pl.po_id         = h.po_id*/
      JOIN ps_po_line_distrib d
        ON d.business_unit = h.business_unit
       AND d.po_id         = h.po_id
     --  AND d.line_nbr      = pl.line_nbr
       JOIN ps_req_line rl
        ON rl.business_unit = d.business_unit
       AND rl.req_id        = d.req_id
    --   AND rl.line_nbr  = d.req_line_nbr 
),
	
po_comments_base AS (
  SELECT
    b.business_unit,
    b.po_id,
    b.public_flg,
    regexp_replace(t.comments_2000, '[^[:print:]]', ' ') AS cmmt
  FROM ps_po_comments b
  JOIN ps_comments_tbl t
    ON t.oprid           = b.oprid
   AND t.comment_id      = b.comment_id
   AND t.random_cmmt_nbr = b.random_cmmt_nbr
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
          ) AS CLOB
        ),
        ' | '
      ) AS internal_memo
  FROM (
      SELECT
          b.business_unit,
          b.po_id,
          b.public_flg,
          b.comment_id,
          b.random_cmmt_nbr,
          CASE
            WHEN t.comments_2000 IS NULL THEN NULL
            WHEN REGEXP_LIKE(t.comments_2000, '[^[:print:]]')
              THEN REGEXP_REPLACE(t.comments_2000, '[^[:print:]]', ' ')
            ELSE t.comments_2000
          END AS clean_comment
      FROM ps_po_comments b
      JOIN ps_PO_HDR p
        ON p.business_unit = b.business_unit
       AND p.po_id         = b.po_id
      LEFT JOIN ps_comments_tbl t
        ON t.oprid           = b.oprid
       AND t.comment_id      = b.comment_id
       AND t.random_cmmt_nbr = b.random_cmmt_nbr
  ) x
  WHERE x.clean_comment IS NOT NULL
  GROUP BY x.business_unit, x.po_id
),

consign_info AS (
    SELECT DISTINCT
           a.business_unit,
           a.req_id,
           a.bh_consign_type,
           a.bh_physicians_name,
           a.bh_medrec_no,
           a.bh_har_num,
           TO_CHAR(a.bh_procede_dt,'YYYY-MM-DD') AS bh_procede_dt
    FROM ps_bh_consgn_hdr a
    JOIN ps_bh_consgn_line b
      ON b.business_unit = a.business_unit
     AND b.req_id        = a.req_id
),

Pull_ProcedureInfo AS (
    SELECT DISTINCT
           h.business_unit,
           h.po_id,
           ci.bh_medrec_no      AS MRN,
           ci.bh_procede_dt     AS PHDATE,
           ci.bh_har_num        AS HAR
    FROM ps_po_hdr h
    JOIN ps_po_line_distrib d
      ON d.business_unit = h.business_unit
     AND d.po_id         = h.po_id
    LEFT JOIN consign_info ci
      ON ci.business_unit = d.business_unit
     AND ci.req_id        = d.req_id
)

SELECT
    /* ============================================================
       OUTPUT COLUMNS IN EXACT EXCEL ORDER / NAMES
       ============================================================ */

    h.po_id                                                                                   AS "*No.",
    'Y'                                                                                       AS "Add Only",
    NULL                                                                                      AS "Purchase Orders For Updates",
    h.po_id                                                                                   AS "Purchase Order ID",
    'Y'                                                                                       AS "Submit",
    'N'                                                                                       AS "Locked in Workday",
    h.po_id                                                                                   AS "Document Number",

    NULL								                                                      AS "Invoice Status",
    NULL                                                                                      AS "Payment Status",
    NULL									                                                  AS "Receiving Status",
    NULL                                                                                      AS "Shipping Status",
    NULL                                                                                      AS "Tracking Status",

    /* If you have BU DESCR, replace bu.business_unit with bu.descr */
    'CO_80800'									                                              AS "*Company",
    'WD Supplier Id'                                                                          AS "*Supplier",

  ppt.POTYPE                                                                        AS "Purchase Order Type", 
    null                                                                             AS "External PO Number",
    NULL                                                                                      AS "Order From Supplier Connection",

    TO_CHAR(h.po_dt,'YYYY-MM-DD')                                                             AS "*Document Date",

    NULL                                                                                        AS "Tax Amount",
    NULL                                                                                       AS "Freight Amount",
    NULL                                                                                       AS "Other Charges",

    null                                                                               AS "Payment Terms",
    NULL                                                                                      AS "Override Payment Type",
    NULL                                                                                      AS "Procurement Credit Card",

    NULL			                                                                          AS "Shipping Terms",
    NULL			                                                                          AS "Shipping Method",
    NULL                                                                                      AS "Shipping Instruction",

    NULL							                                                          AS "Due Date",

    NULL                                                                                      AS "Supplier Contract",
    h.currency_cd                                                                             AS "Currency",
    CASE h.poa_status
        WHEN 'AC'   THEN
            'Y'
        WHEN 'AK'   THEN
            'Y'
        ELSE
            'N'
    END                                                                                      AS "Acknowledgement Expected",

    NULL                                                                                      AS "Default Tax Option",
    NULL                                                                                      AS "Default Tax Code",
    'Phone'                                                                                   AS "Issue Option",

    'Y'																		                  AS "Buyer Is Employee",
    'Sourcing Rule'																			  AS "Buyer Worker ID",

    'Y'																		                  AS "Bill To Contact Is Employee",
    'Sourcing Rule'																			  AS "Bill To Contact Worker ID",
    'User name based on Sourcing Rule'														  AS "Bill To Contact Detail",
    'PwC to provide mapping for bill to address'				                              AS "Bill To Address",
    null	                                                                                  AS "Bill To Address ID",

    'TBD'																	                  AS "Ship To Contact Is Employee",
    'TBD'																	                  AS "Ship To Contact Worker ID",
    'User name based on Sourcing Rule'														  AS "Ship To Contact Detail",
   /* TRIM(NVL(sh_loc.address1,'') || ' ' || NVL(sh_loc.address2,'') || ' ' ||
         NVL(sh_loc.address3,'') || ' ' || NVL(sh_loc.address4,'') ||
         ', ' || NVL(sh_loc.city,'') || ', ' || NVL(sh_loc.state,'') || ' ' ||
         NVL(sh_loc.postal,'') || ', ' || NVL(sh_loc.country,''))                              AS "Ship To Address",
         fos.shipto_id                                                                             AS "Ship To Address ID",*/
    ' '                                                                                       AS "Ship To Address",
     initcap('SHIP_TO_'||replace(substr(sh_loc.ADDRESS1,1,11)||'_'||substr(sh_loc.CITY,1,5)||
         ''||sh_loc.STATE||''||substr(sh_loc.POSTAL,1,5),' ',''))||''||fos.SHIPTO_ID                    AS "Ship To Address ID",
    

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
JOIN ps_po_hdr h
  ON h.business_unit = op.business_unit
 AND h.po_id         = op.po_id
 AND h.po_status NOT IN ('C','X') --and h.po_id='0000949497'

JOIN ps_bus_unit_tbl_pm bu
  ON bu.business_unit = h.business_unit

JOIN setids si
  ON si.business_unit = h.business_unit

LEFT JOIN ps_vendor v
  ON v.setid     = si.setid_vendor
 AND v.vendor_id = h.vendor_id

LEFT JOIN psoprdefn opr
  ON opr.oprid = h.buyer_id

LEFT JOIN first_open_sched fos
  ON fos.business_unit = h.business_unit
 AND fos.po_id         = h.po_id

LEFT JOIN location_eff sh_loc
  ON sh_loc.setid    = fos.shipto_setid
 AND sh_loc.location = fos.shipto_id

LEFT JOIN location_eff bl_loc
  ON bl_loc.setid    = si.setid_location
 AND bl_loc.location = bu.location

LEFT JOIN min_due md
  ON md.business_unit = h.business_unit
 AND md.po_id         = h.po_id

LEFT JOIN recv_status_po rcv
  ON rcv.business_unit = h.business_unit
 AND rcv.po_id         = h.po_id

LEFT JOIN invoice_status_po inv
  ON inv.business_unit = h.business_unit
 AND inv.po_id         = h.po_id

LEFT JOIN Pull_Comments pc
  ON pc.business_unit = h.business_unit
 AND pc.po_id         = h.po_id
 
  LEFT JOIN Pull_POTYPE ppt
  ON ppt.business_unit = h.business_unit
 AND ppt.po_id         = h.po_id
 
LEFT JOIN Pull_ProcedureInfo ph
on ph.business_unit = h.business_unit
 AND ph.po_id         = h.po_id

ORDER BY h.business_unit, h.po_id

