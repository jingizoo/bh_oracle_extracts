WITH
ln_ship_agg AS (
  SELECT
    rls.business_unit,
    rls.receiver_id,

    MAX(rls.oprid) KEEP (DENSE_RANK FIRST ORDER BY rls.recv_ln_nbr, rls.recv_ship_seq_nbr) AS requester_oprid,
    MAX(rls.packsLip_no) KEEP (DENSE_RANK FIRST ORDER BY rls.recv_ln_nbr, rls.recv_ship_seq_nbr) AS tracking_no,
    MAX(NULLIF(TRIM(rls.bill_of_lading),'')) KEEP (DENSE_RANK FIRST ORDER BY rls.recv_ln_nbr, rls.recv_ship_seq_nbr) AS bol_no,

    MAX(rls.receipt_dttm) AS receipt_dttm,
    SUM(NVL(rls.qty_sh_recvd,0)) AS bol_qty,

    MAX(NULLIF(TRIM(rls.descr254_mixed),'')) KEEP (DENSE_RANK FIRST ORDER BY rls.recv_ln_nbr, rls.recv_ship_seq_nbr) AS memo_line

  FROM ps_recv_ln_ship rls
  WHERE rls.recv_ship_status <> 'X'
  GROUP BY rls.business_unit, rls.receiver_id
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

  NVL(ls.bol_no,' ')                                  AS "Bill of Lading",

  NVL(ls.requester_oprid,' ')                         AS "Requester",
  NVL(da.req_id,' ')                                  AS "Requisition",
  NVL(ls.tracking_no,' ')                             AS "Tracking Number",

  NVL(da.po_id,' ')                                   AS "Supplier Order Ref",

  CASE
    WHEN ls.receipt_dttm IS NOT NULL
      THEN TO_CHAR(ls.receipt_dttm, 'YYYY-MM-DD"T"HH24:MI:SS')
    ELSE ' '
  END                                                 AS "Shipment Date Time",

  NVL(da.shipment_contact,' ')                        AS "Shipment Contact",
  NVL(ls.bol_qty,0)                                   AS "Bill of Lading Quantity",
  ' '                                                 AS "License Plate",

  NVL(ls.tracking_no,' ')                             AS "Shipment Ref",

  DECODE(h.recv_status,
         'C','Closed Receipt',
         'H','Hold Receipt',
         'M','Moved to Destination',
         'N','PO Not Received',
         'O','Open',
         'P','PO Partially Received',
         'R','Fully Received',
         'X','Canceled',
         h.recv_status)                                AS "Document Status",

  h.vendor_id                                         AS "Supplier",

  TO_CHAR(h.receipt_dt,'YYYY-MM-DD')                  AS "Document Date",

  CASE
    WHEN ls.receipt_dttm IS NOT NULL
      THEN TO_CHAR(ls.receipt_dttm, 'YYYY-MM-DD"T"HH24:MI:SS')
    ELSE TO_CHAR(h.receipt_dt,'YYYY-MM-DD')
  END                                                 AS "Last Updated",

  NVL(ls.requester_oprid,' ')                         AS "Created for Worker ID",

  COALESCE(da.delivery_feedback, ls.memo_line, ' ')    AS "Memo",

  ' '                                                 AS "Contingent Worker Receipt Purchase Order Line",
  ' '                                                 AS "Period Start Date",
  ' '                                                 AS "Period End Date",
  NULL                                                AS "Additional Amount",

  NVL(da.amount_to_receive,0)                         AS "Amount to Receive",

  ' '                                                 AS "Contingent Worker Receipt Memo"

FROM ps_recv_hdr h
LEFT JOIN ln_ship_agg ls
  ON ls.business_unit = h.business_unit
 AND ls.receiver_id   = h.receiver_id
LEFT JOIN dist_agg da
  ON da.business_unit = h.business_unit
 AND da.receiver_id   = h.receiver_id

WHERE h.recv_status <> 'X'
ORDER BY h.receiver_id;
