

WITH
params AS (
  SELECT
    TRUNC(SYSDATE)                  AS asof_dt,
    ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

/* Candidate open POs (status only) */
hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status
    FROM ps_po_hdr h
    CROSS JOIN params p
   WHERE h.po_dt <= p.asof_dt
     AND h.po_status NOT IN ('C','X')
),

/* Receipt totals to date (for open/closed determination) */
recv_agg_all AS (
  SELECT r.business_unit_po AS business_unit,
         r.po_id,
         r.line_nbr,
         r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd_suom, 0))  AS qty_rcvd_suom,
         SUM(NVL(r.merchandise_amt_po, 0)) AS merch_amt_rcvd_po
    FROM ps_recv_ln_ship r
    JOIN hdr_candidates hc
      ON hc.business_unit = r.business_unit_po
     AND hc.po_id         = r.po_id
    CROSS JOIN params p
   WHERE r.recv_ship_status <> 'X'
     AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
   GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),

/* Open schedule flag (same logic as PO_HDR extract) */
sched_open AS (
  SELECT s.business_unit,
         s.po_id,
         s.line_nbr,
         s.sched_nbr,
         s.cancel_status,
         s.due_dt,
         s.shipto_setid,
         s.shipto_id,
         s.qty_po,
         s.merchandise_amt,
         s.liquidate_method,
         NVL(r.qty_rcvd_suom, 0)     AS qty_rcvd_suom,
         NVL(r.merch_amt_rcvd_po, 0) AS merch_amt_rcvd_po,
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
    LEFT JOIN recv_agg_all r
      ON r.business_unit  = s.business_unit
     AND r.po_id          = s.po_id
     AND r.line_nbr       = s.line_nbr
     AND r.sched_nbr      = s.sched_nbr
),

open_pos AS (
  SELECT DISTINCT hc.business_unit, hc.po_id, hc.po_dt
    FROM hdr_candidates hc
   WHERE EXISTS (
     SELECT 1
       FROM sched_open so
      WHERE so.business_unit = hc.business_unit
        AND so.po_id         = hc.po_id
        AND so.is_open       = 1
   )
),

/* Any receipt activity within lookback */
receipt_activity AS (
  SELECT DISTINCT r.business_unit_po AS business_unit, r.po_id
    FROM ps_recv_ln_ship r
    CROSS JOIN params p
   WHERE r.recv_ship_status <> 'X'
     AND r.receipt_dttm >= CAST(p.lookback_dt AS TIMESTAMP)
     AND r.receipt_dttm <  CAST(p.asof_dt + 1 AS TIMESTAMP)
),

/* Any invoice activity within lookback (line-linked to PO) */
invoice_activity AS (
  SELECT DISTINCT vl.business_unit_po AS business_unit, vl.po_id
    FROM ps_voucher_line vl
    JOIN ps_voucher v
      ON v.business_unit = vl.business_unit
     AND v.voucher_id    = vl.voucher_id
    CROSS JOIN params p
   WHERE v.entry_status <> 'X'
     AND v.close_status <> 'C'
     AND vl.po_id IS NOT NULL
     AND vl.po_id <> ' '
     AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
),

/* Final PO population for conversion */
included_po AS (
  SELECT op.business_unit, op.po_id
    FROM open_pos op
    JOIN params p ON 1=1
   WHERE op.po_dt >= p.lookback_dt
      OR EXISTS (SELECT 1 FROM receipt_activity ra WHERE ra.business_unit = op.business_unit AND ra.po_id = op.po_id)
      OR EXISTS (SELECT 1 FROM invoice_activity ia WHERE ia.business_unit = op.business_unit AND ia.po_id = op.po_id)
),

/* Ship-to descr */
shipto_ed AS (
  SELECT st.setid, st.shipto_id, st.descr
    FROM ps_shipto_tbl st
   WHERE st.eff_status = 'A'
     AND st.effdt = (
       SELECT MAX(st2.effdt)
         FROM ps_shipto_tbl st2
        WHERE st2.setid     = st.setid
          AND st2.shipto_id = st.shipto_id
          AND st2.effdt    <= SYSDATE
     )
),

base AS (
  SELECT
      h.business_unit,
      h.po_id,
      l.line_nbr,
      s.sched_nbr,

      h.po_id AS po_no,

      l.inv_item_id,
      l.itm_id_vndr,
      l.unit_of_measure,
      l.category_id,
      l.cntrct_id,
      l.cntrct_line_nbr,
      NVL(NULLIF(TRIM(l.descr254_mixed2), ''), l.descr254_mixed) AS item_descr,

      s.qty_po,
      s.price_po,
      NVL(s.merchandise_amt, (s.qty_po * s.price_po)) AS extended_amt,
      s.due_dt,
      s.shipto_setid,
      s.shipto_id,

      d.business_unit_gl,
      d.location,
      d.resource_category,
      d.distrib_ln_status,

      h.prepaid_po_flg,
      cnt.cntrct_style,
      d.deptid
  FROM included_po ip
  JOIN ps_po_hdr h
    ON h.business_unit = ip.business_unit
   AND h.po_id         = ip.po_id
  JOIN ps_po_line l
    ON l.business_unit = h.business_unit
   AND l.po_id         = h.po_id
   AND l.physical_nature = 'G'
  JOIN ps_po_line_ship s
    ON s.business_unit = l.business_unit
   AND s.po_id         = l.po_id
   AND s.line_nbr      = l.line_nbr
   AND s.sched_nbr     = 1
  JOIN sched_open so
    ON so.business_unit = s.business_unit
   AND so.po_id         = s.po_id
   AND so.line_nbr      = s.line_nbr
   AND so.sched_nbr     = s.sched_nbr
   AND so.is_open       = 1
  JOIN ps_po_line_distrib d
    ON d.business_unit     = s.business_unit
   AND d.po_id             = s.po_id
   AND d.line_nbr          = s.line_nbr
   AND d.sched_nbr         = s.sched_nbr
   AND d.dst_acct_type     = 'DST'
   AND d.distrib_line_num  = 1
  LEFT JOIN ps_cntrct_hdr cnt
    ON cnt.setid     = 'SHARE'
   AND cnt.cntrct_id = l.cntrct_id
  WHERE l.cancel_status <> 'X'
    AND s.cancel_status <> 'X'
    AND d.distrib_ln_status <> 'X'
)

SELECT
    b.po_no                                                     AS "*No.",
    b.line_nbr                                                  AS "*Goods Line Replacement Data Line No",
    b.inv_item_id                                               AS "Item",
    b.po_no || '-' || TO_CHAR(b.line_nbr)                       AS "Goods Purchase Order Line ID",
    b.line_nbr                                                  AS "Line Number",
    b.business_unit_gl                                          AS "Line Company",
    b.itm_id_vndr                                               AS "Supplier Item Identifier",
    ' '                                                         AS "Supplier Part ID",
    ' '                                                         AS "Supplier Part Auxiliary ID",
    ' '                                                         AS "UNSPSC Code",
    b.item_descr                                                AS "Item Description",
    CASE
      WHEN TRIM(b.cntrct_id) IS NOT NULL THEN TRIM(b.cntrct_id) || '-' || TO_CHAR(b.cntrct_line_nbr)
      ELSE ' '
    END                                                         AS "Supplier Contract Line",
    ' '                                                         AS "Commodity Code",
    ' '                                                         AS "Payment Status",
    ' '                                                         AS "Invoice Status",
    ' '                                                         AS "Receiving Status",
    ' '                                                         AS "Shipping Status",
    ' '                                                         AS "Tracking Status",
    b.resource_category                                         AS "*Resource Category",
    ' '                                                         AS "Tax Applicability",
    ' '                                                         AS "Tax Code",
    ' '                                                         AS "Tax Rate 1",
    ' '                                                         AS "Tax Recoverability 1",
    ' '                                                         AS "Tax Option 1",
    ' '                                                         AS "Tax Recoverability 2",
    ' '                                                         AS "Tax Option 2",
    ' '                                                         AS "Tax Recoverability 3",
    ' '                                                         AS "Tax Option 3",
    ' '                                                         AS "Tax Recoverability 4",
    ' '                                                         AS "Tax Option 4",
    ' '                                                         AS "Tax Recoverability 5",
    ' '                                                         AS "Tax Option 52",
    ' '                                                         AS "Tax Recoverability 6",
    ' '                                                         AS "Tax Option 6",
    ' '                                                         AS "Packaging String",
    b.qty_po                                                    AS "*Quantity",
    b.unit_of_measure                                           AS "*Unit of Measure",
    b.price_po                                                  AS "Unit Cost",
    ' '                                                         AS "Requested as No Charge",
    b.extended_amt                                              AS "Extended Amount",
    ' '                                                         AS "Lot Serial Information Reference",
    ' '                                                         AS "Lot Number",
    ' '                                                         AS "Serial Number",
    TO_CHAR(b.due_dt, 'YYYY-MM-DD')                             AS "Due Date",
    CASE WHEN b.deptid = '20100' THEN 'Inventory_Replenishment' ELSE ' ' END AS "Delivery Type",
    CASE WHEN b.cntrct_style = 'PPD_AMORT' THEN 'Y' ELSE 'N' END AS "Prepaid",
    ' '                                                         AS "Down Payment",
    ' '                                                         AS "Retention",
    ' '                                                         AS "Requested Delivery Date",
    ' '                                                         AS "Budget Date",
    ' '                                                         AS "Memo",
    CASE
      WHEN st.descr IS NOT NULL THEN b.shipto_id || ' - ' || st.descr
      ELSE b.shipto_id
    END                                                         AS "Ship To Address",
    ' '                                                         AS "Ship To Global Location Number",
    ' '                                                         AS "Ship To Location Identifier",
    ' '                                                         AS "Ship To Contact Is Employee",
    ' '                                                         AS "Ship To Contact Worker ID",
    ' '                                                         AS "Requester Is Employee",
    ' '                                                         AS "Requester Worker ID",
    b.location                                                  AS "Deliver To Location",
    ' '                                                         AS "Deliver To Location GLN",
    ' '                                                         AS "Deliver To Location Location Id",
    TRIM(b.cntrct_id)                                           AS "Supplier Contract",
    ' '                                                         AS "Storage Location",
    b.distrib_ln_status                                         AS "Close Status"
FROM base b
LEFT JOIN shipto_ed st
  ON st.setid     = b.shipto_setid
 AND st.shipto_id = b.shipto_id
ORDER BY b.po_no, b.line_nbr;
