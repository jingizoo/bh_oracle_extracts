-- Replace :p_bu and :p_po_id
WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt FROM dual
),
recv_agg AS (
  SELECT r.business_unit_po AS business_unit,
         r.po_id, r.line_nbr, r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd_suom,0)) AS qty_rcvd_suom
  FROM ps_recv_ln_ship r
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
    AND r.business_unit_po = :p_bu
    AND r.po_id            = :p_po_id
  GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),
vchr_sum AS (
  SELECT vl.business_unit_po AS business_unit,
         vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1) AS sched_nbr,
         SUM(NVL(vl.merchandise_amt,0)) AS merch_amt_vchr
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND vl.business_unit_po = :p_bu
    AND vl.po_id            = :p_po_id
    AND vl.po_id IS NOT NULL
    AND NVL(TRIM(vl.po_id),'') <> ''
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1)
),
line_flags AS (
  SELECT l.business_unit, l.po_id, l.line_nbr,
         NVL(l.recv_req,'Y')     AS recv_req,
         NVL(l.amt_only_flg,'N') AS amt_only_flg
  FROM ps_po_line l
  WHERE l.business_unit = :p_bu
    AND l.po_id         = :p_po_id
)
SELECT
  s.business_unit, s.po_id, s.line_nbr, s.sched_nbr,
  s.cancel_status,
  lf.amt_only_flg,
  lf.recv_req,
  s.liquidate_method,
  s.qty_po,
  NVL(r.qty_rcvd_suom,0) AS qty_rcvd_suom,
  NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) AS sched_amt,
  NVL(vs.merch_amt_vchr,0) AS merch_amt_vchr,

  /* current HEADER logic */
  CASE
    WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
    WHEN s.liquidate_method = 'A'
      THEN CASE WHEN NVL(s.merchandise_amt,0) > NVL(vs.merch_amt_vchr,0) THEN 1 ELSE 0 END
    ELSE
      CASE WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0) THEN 1 ELSE 0 END
  END AS is_open_hdr_old,

  /* corrected logic aligned to AMT_ONLY_FLG + RECV_REQ */
  CASE
    WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
    WHEN lf.amt_only_flg = 'Y'
      THEN CASE WHEN NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) > NVL(vs.merch_amt_vchr,0) THEN 1 ELSE 0 END
    WHEN lf.recv_req = 'Y'
      THEN CASE WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0) THEN 1 ELSE 0 END
    ELSE
      CASE WHEN NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) > NVL(vs.merch_amt_vchr,0) THEN 1 ELSE 0 END
  END AS is_open_hdr_new

FROM ps_po_line_ship s
JOIN line_flags lf
  ON lf.business_unit = s.business_unit
 AND lf.po_id         = s.po_id
 AND lf.line_nbr      = s.line_nbr
LEFT JOIN recv_agg r
  ON r.business_unit  = s.business_unit
 AND r.po_id          = s.po_id
 AND r.line_nbr       = s.line_nbr
 AND r.sched_nbr      = s.sched_nbr
LEFT JOIN vchr_sum vs
  ON vs.business_unit = s.business_unit
 AND vs.po_id         = s.po_id
 AND vs.line_nbr      = s.line_nbr
 AND vs.sched_nbr     = s.sched_nbr
WHERE s.business_unit = :p_bu
  AND s.po_id         = :p_po_id
  AND s.sched_nbr     = 1
ORDER BY s.line_nbr;
