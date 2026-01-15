

WITH
params AS (
  SELECT
    TRUNC(SYSDATE)                    AS asof_dt,
    ADD_MONTHS(TRUNC(SYSDATE), -12)   AS lookback_dt
  FROM dual
),

/* Qualifying receipt schedules (drives the whole extract) */
qual_ship AS (
  SELECT
    rls.business_unit,
    rls.receiver_id,
    rls.recv_ln_nbr,
    rls.recv_ship_seq_nbr,

    rls.business_unit_po,
    rls.po_id,
    rls.line_nbr,
    rls.sched_nbr,

    rls.oprid,
    rls.packsLip_no,
    rls.bill_of_lading,
    rls.receipt_dttm,
    rls.qty_sh_recvd,
    rls.descr254_mixed

  FROM ps_recv_ln_ship rls
  JOIN params p
    ON 1=1
  JOIN ps_po_hdr poh
    ON poh.business_unit = rls.business_unit_po
   AND poh.po_id         = rls.po_id
  JOIN ps_po_line pol
    ON pol.business_unit = rls.business_unit_po
   AND pol.po_id         = rls.po_id
   AND pol.line_nbr      = rls.line_nbr

  WHERE rls.recv_ship_status <> 'X'
    AND TRUNC(CAST(rls.receipt_dttm AS DATE)) BETWEEN p.lookback_dt AND p.asof_dt

    /* PO must still be open-ish */
    AND poh.po_status NOT IN ('C','X')
    AND pol.cancel_status NOT IN ('C','X')

    /* Bill-only / Do Not Receive */
    AND pol.recv_req <> 'X'
),

ln_ship_agg AS (
  SELECT
    q.business_unit,
    q.receiver_id,

    MAX(q.oprid) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS requester_oprid,
    MAX(q.packsLip_no) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS tracking_no,
    MAX(NULLIF(TRIM(q.bill_of_lading),'')) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS bol_no,

    MAX(q.receipt_dttm) AS receipt_dttm,
    SUM(NVL(q.qty_sh_recvd,0)) AS bol_qty,

    MAX(NULLIF(TRIM(q.descr254_mixed),'')) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS memo_line

  FROM qual_ship q
  GROUP BY q.business_unit, q.receiver_id
),

dist_agg AS (
  SELECT
    rld.business_unit,
    rld.receiver_id,

    MAX(rld.business_unit_gl) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS company,

    MAX(NULLIF(TRIM(rld.delivered_to),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS shipment_contact,

    MAX(NULLIF(TRIM(rld.delivery_feedback),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS delivery_feedback,

    MAX(NULLIF(TRIM(rld.req_id),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS req_id,

    MAX(NULLIF(TRIM(rld.po_id),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS po_id,

    SUM(NVL(rld.merchandise_amt,0)) AS amount_to_receive

  FROM ps_recv_ln_distrib rld
  /* restrict distribs to qualifying receipt schedules */
  JOIN qual_ship q
    ON q.business_unit      = rld.business_unit
   AND q.receiver_id        = rld.receiver_id
   AND q.recv_ln_nbr        = rld.recv_ln_nbr
   AND q.recv_ship_seq_nbr  = rld.recv_ship_seq_nbr

  WHERE rld.recv_ds_status <> 'X'
    AND rld.dst_acct_type = 'DST'
  GROUP BY rld.business_unit, rld.receiver_id
)

SELECT
  h.receiver_id                                       AS "*No.",
  'Y'                                                 AS "Add Only",
  ' '                                                 AS "Receipt Reference For Update",
  h.receiver_id                                       AS "Receipt Number",
  ' '                                                 AS "Locked in Workday",
  'Y'                                                 AS "Submit",

  NVL(da.company,' ')                                 AS "Company",

  ' '                                                 AS "Bill of Lading",
  ' '                                                 AS "Requester",
  ' '                                                 AS "Requisition",
  ' '                                                 AS "Tracking Number",
  ' '                                                 AS "Supplier Order Ref",
  ' '                                                 AS "Shipment Date Time",
  ' '                                                 AS "Shipment Contact",
  ' '                                                 AS "Bill of Lading Quantity",
  ' '                                                 AS "License Plate",
  ' '                                                 AS "Shipment Ref",
  ' '                                                 AS "Document Status",

  wd.bh_wd_supplier_id                                AS "Supplier",

  TO_CHAR(h.receipt_dt,'YYYY-MM-DD')                  AS "Document Date",
  ' '                                                 AS "Last Updated",
  ' '                                                 AS "Created for Worker ID",

  COALESCE(da.delivery_feedback, ls.memo_line, ' ')    AS "Memo",

  ' '                                                 AS "Contingent Worker Receipt Purchase Order Line",
  ' '                                                 AS "Period Start Date",
  ' '                                                 AS "Period End Date",
  NULL                                                AS "Additional Amount",
  ' '                                                 AS "Amount to Receive",
  ' '                                                 AS "Contingent Worker Receipt Memo"

FROM ps_recv_hdr h
JOIN params p
  ON 1=1
/* only headers that have at least one qualifying receipt line */
JOIN (SELECT DISTINCT business_unit, receiver_id FROM qual_ship) qh
  ON qh.business_unit = h.business_unit
 AND qh.receiver_id   = h.receiver_id

LEFT JOIN ln_ship_agg ls
  ON ls.business_unit = h.business_unit
 AND ls.receiver_id   = h.receiver_id
LEFT JOIN dist_agg da
  ON da.business_unit = h.business_unit
 AND da.receiver_id   = h.receiver_id

LEFT JOIN ps_bh_wd_sup_1to1 wd
  ON h.vendor_id = wd.bh_wd_ps_vendor_id

WHERE h.recv_status <> 'X'
  AND TRUNC(h.receipt_dt) BETWEEN p.lookback_dt AND p.asof_dt

ORDER BY h.receiver_id;
