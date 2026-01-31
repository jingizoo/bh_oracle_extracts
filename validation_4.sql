WITH
params AS (
  SELECT TRUNC(TO_DATE(:ASOF_DT,'YYYY-MM-DD')) AS asof_dt
  FROM dual
),

/* --- Base PO schedules in scope --- */
po_sched AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status,
         h.vendor_id,
         h.currency_cd,

         l.line_nbr,
         NVL(l.cancel_status,' ')    AS line_cancel_status,
         NVL(l.recv_req,'Y')         AS recv_req,
         NVL(l.amt_only_flg,'N')     AS amt_only_flg,
         l.item_id,
         l.descr254                  AS item_descr,
         l.unit_of_meas,

         s.sched_nbr,
         NVL(s.cancel_status,' ')    AS sched_cancel_status,
         NVL(s.qty_po,0)             AS qty_po,
         NVL(s.price_po,0)           AS price_po,
         NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) AS amt_po
  FROM ps_po_hdr h
  JOIN ps_po_line l
    ON l.business_unit = h.business_unit
   AND l.po_id         = h.po_id
  JOIN ps_po_line_ship s
    ON s.business_unit = l.business_unit
   AND s.po_id         = l.po_id
   AND s.line_nbr      = l.line_nbr
  CROSS JOIN params p
  WHERE h.po_dt < (p.asof_dt + 1)
    AND h.po_status NOT IN ('C','X')
    AND NVL(l.cancel_status,' ') <> 'X'
    AND NVL(s.cancel_status,' ') <> 'X'
),

/* --- Receipts aggregated to PO schedule --- */
rcv_agg AS (
  SELECT /*+ MATERIALIZE */
         r.business_unit_po AS business_unit,
         r.po_id,
         r.line_nbr,
         r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd,0))      AS qty_rcvd,
         SUM(NVL(r.merchandise_amt,0))   AS amt_rcvd,
         MAX(r.receipt_dttm)             AS last_receipt_dttm,
         COUNT(DISTINCT r.receiver_id)   AS receiver_cnt
  FROM ps_recv_ln_ship r
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),

/* --- Vouchers aggregated to PO schedule (all, matched subset) --- */
vchr_agg AS (
  SELECT /*+ MATERIALIZE */
         vl.business_unit_po AS business_unit,
         vl.po_id,
         vl.line_nbr,
         NVL(vl.sched_nbr,1) AS sched_nbr,

         SUM(NVL(vl.qty_vchr,0)) AS qty_vchr_total,
         SUM(CASE WHEN v.match_status_vchr='M' THEN NVL(vl.qty_vchr,0) ELSE 0 END) AS qty_vchr_matched,

         SUM(NVL(vl.merchandise_amt,0)) AS amt_vchr_total,
         SUM(CASE WHEN v.match_status_vchr='M' THEN NVL(vl.merchandise_amt,0) ELSE 0 END) AS amt_vchr_matched,

         MAX(NVL(v.invoice_dt, v.entered_dt)) AS last_invoice_dt,
         COUNT(DISTINCT v.voucher_id)         AS voucher_cnt
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND vl.po_id IS NOT NULL
    AND TRIM(vl.po_id) <> ''
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1)
),

/* --- Paid vouchers (header) --- */
paid_vouchers AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  WHERE px.pymnt_action <> 'X'
    AND px.paid_amt > 0
),

/* --- Paid+matched vouchered qty to PO schedule (your “paid base”) --- */
vchr_paid_agg AS (
  SELECT /*+ MATERIALIZE */
         vl.business_unit_po AS business_unit,
         vl.po_id,
         vl.line_nbr,
         NVL(vl.sched_nbr,1) AS sched_nbr,
         SUM(NVL(vl.qty_vchr,0))      AS qty_vchr_paid,
         SUM(NVL(vl.merchandise_amt,0)) AS amt_vchr_paid
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN paid_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.match_status_vchr='M'
    AND vl.po_id IS NOT NULL
    AND TRIM(vl.po_id) <> ''
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1)
)

SELECT
  ps.business_unit,
  ps.po_id,
  ps.line_nbr,
  ps.sched_nbr,

  ps.po_dt,
  ps.po_status,
  ps.vendor_id,
  ps.currency_cd,
  ps.recv_req,
  ps.amt_only_flg,
  ps.item_id,
  ps.item_descr,
  ps.unit_of_meas,

  ps.qty_po,
  NVL(r.qty_rcvd,0)             AS qty_rcvd,
  NVL(v.qty_vchr_total,0)       AS qty_vchr,
  NVL(vp.qty_vchr_paid,0)       AS qty_vchr_paid,

  /* Useful derived deltas */
  GREATEST(ps.qty_po - NVL(r.qty_rcvd,0), 0)           AS qty_open_to_receive,
  GREATEST(NVL(r.qty_rcvd,0) - NVL(v.qty_vchr_total,0), 0) AS qty_rcvd_not_invoiced,
  GREATEST(ps.qty_po - NVL(v.qty_vchr_total,0), 0)     AS qty_open_to_invoice,
  GREATEST(NVL(r.qty_rcvd,0) - NVL(vp.qty_vchr_paid,0), 0) AS qty_rcvd_not_paid,

  /* Optional amount side (for amt-only/service lines) */
  ps.amt_po,
  NVL(r.amt_rcvd,0)             AS amt_rcvd,
  NVL(v.amt_vchr_total,0)       AS amt_vchr,
  NVL(vp.amt_vchr_paid,0)       AS amt_vchr_paid,

  r.last_receipt_dttm,
  v.last_invoice_dt,
  r.receiver_cnt,
  v.voucher_cnt,

  /* Scenario label aligned to your slide logic (qty-based) */
  CASE
    WHEN ps.amt_only_flg = 'Y' THEN 'AMT_ONLY_LINE_USE_AMOUNTS'
    WHEN NVL(r.qty_rcvd,0) = 0 AND NVL(v.qty_vchr_total,0) = 0 THEN 'NO_RCV_NO_INV'
    WHEN NVL(r.qty_rcvd,0) = 0 AND NVL(v.qty_vchr_total,0) > 0 THEN 'INVOICED_NO_RECEIPT'
    WHEN NVL(r.qty_rcvd,0) > 0 AND NVL(r.qty_rcvd,0) < ps.qty_po AND NVL(v.qty_vchr_total,0) = 0 THEN 'PARTIAL_RCV_NOT_INV'
    WHEN NVL(r.qty_rcvd,0) > 0 AND NVL(r.qty_rcvd,0) < ps.qty_po AND NVL(v.qty_vchr_total,0) = NVL(r.qty_rcvd,0) THEN 'PARTIAL_RCV_INVOICED_TO_RCV'
    WHEN NVL(r.qty_rcvd,0) = ps.qty_po AND NVL(v.qty_vchr_total,0) = ps.qty_po THEN 'FULL_RCV_FULL_INV'
    WHEN NVL(r.qty_rcvd,0) = ps.qty_po AND NVL(v.qty_vchr_total,0) < ps.qty_po THEN 'FULL_RCV_PARTIAL_INV'
    WHEN NVL(r.qty_rcvd,0) < ps.qty_po AND NVL(v.qty_vchr_total,0) < NVL(r.qty_rcvd,0) THEN 'PARTIAL_RCV_PARTIAL_INV'
    ELSE 'OTHER_REVIEW'
  END AS scenario
FROM po_sched ps
LEFT JOIN rcv_agg r
  ON r.business_unit = ps.business_unit
 AND r.po_id         = ps.po_id
 AND r.line_nbr      = ps.line_nbr
 AND r.sched_nbr     = ps.sched_nbr
LEFT JOIN vchr_agg v
  ON v.business_unit = ps.business_unit
 AND v.po_id         = ps.po_id
 AND v.line_nbr      = ps.line_nbr
 AND v.sched_nbr     = ps.sched_nbr
LEFT JOIN vchr_paid_agg vp
  ON vp.business_unit = ps.business_unit
 AND vp.po_id         = ps.po_id
 AND vp.line_nbr      = ps.line_nbr
 AND vp.sched_nbr     = ps.sched_nbr
ORDER BY ps.business_unit, ps.po_id, ps.line_nbr, ps.sched_nbr;
