/*
Oracle-only "grand recon" (SQL Developer).

What you get:
1) Summary metrics: counts + remaining amount totals, split by Service vs Goods
2) Breakdown of POs by "reason included"
3) Detailed per-PO output (amounts + reason)

Notes:
- Uses matched + PAID vouchers (PS_PAYMENT_TBL.pymnt_status='P') and match_status_vchr='M'
- Goods remaining is qty-based unless AMT_ONLY_FLG='Y' (then amount-based)
- Service remaining is always amount-based

How to run:
- In SQL Developer, open this file and press F5 (Run Script)
*/

/* ======================
   0) Parameters
   ====================== */
WITH
params AS (
  /* Change :asof_dt here if needed */
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

/* ======================
   1) Header candidates (lookback window)
   ====================== */
hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status,
         h.vendor_id
  FROM ps_po_hdr h
  CROSS JOIN params p
  WHERE h.po_dt <= p.asof_dt
    AND h.po_dt >= p.lookback_dt
    AND h.po_status NOT IN ('C','X')
    AND h.vendor_id <> '2000017041'
),

/* ======================
   2) Service flag (PO-level)
   ====================== */
service_flags AS (
  SELECT
      d.business_unit,
      d.po_id,
      CASE WHEN MAX(CASE WHEN x.bh_xwlk_t1 IS NOT NULL THEN 1 ELSE 0 END) = 1 THEN 'Y' ELSE 'N' END AS has_service
  FROM hdr_candidates hc
  JOIN ps_po_line_distrib d
    ON d.business_unit = hc.business_unit
   AND d.po_id         = hc.po_id
  LEFT JOIN ps_bh_xwlk_val_tbl x
    ON x.longname       = 'WD_ACCT_TO_PO_TYPE'
   AND x.bh_xwlk_module = 'PO'
   AND x.bh_xwlk_track  = 'SCM'
   AND x.bh_xwlk_s2     = d.account
  GROUP BY d.business_unit, d.po_id
),

/* ======================
   3) Paid vouchers as-of (matched+paid logic)
   ====================== */
paid_vouchers AS (
  SELECT DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN ps_payment_tbl pt
    ON pt.bank_setid    = px.bank_setid
   AND pt.bank_cd       = px.bank_cd
   AND pt.bank_acct_key = px.bank_acct_key
   AND pt.pymnt_id      = px.pymnt_id
   AND pt.schedule_id   = px.schedule_id
  CROSS JOIN params p
  WHERE px.pymnt_action <> 'X'
    AND pt.pymnt_status = 'P'
    AND pt.pymnt_dt < (p.asof_dt + 1)
),

vchr_sum_match AS (
  /* Matched + PAID voucher totals by PO line/sched */
  SELECT
      vl.business_unit_po AS business_unit,
      vl.po_id,
      vl.line_nbr,
      NVL(vl.sched_nbr, 1) AS sched_nbr,
      SUM(NVL(vl.merchandise_amt, 0)) AS merch_amt_vchr,
      SUM(NVL(vl.qty_vchr, 0))        AS qty_vchr
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN paid_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
  JOIN hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND NVL(v.match_status_vchr, ' ') = 'M'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

/* ======================
   4) PO line flags (recv_req / amt_only)
   ====================== */
po_line_flags AS (
  SELECT
      l.business_unit,
      l.po_id,
      l.line_nbr,
      NVL(l.recv_req, 'Y')     AS recv_req,
      NVL(l.amt_only_flg, 'N') AS amt_only_flg
  FROM ps_po_line l
  JOIN hdr_candidates hc
    ON hc.business_unit = l.business_unit
   AND hc.po_id         = l.po_id
  WHERE l.cancel_status <> 'X'
),

/* ======================
   5) Schedule facts (active line + active distrib + not-cancelled ship sched)
   ====================== */
sched_facts AS (
  SELECT
      s.business_unit,
      s.po_id,
      s.line_nbr,
      s.sched_nbr,
      lf.recv_req,
      lf.amt_only_flg,
      s.cancel_status,
      NVL(s.qty_po, 0)   AS qty_po,
      NVL(s.price_po, 0) AS price_po,
      NVL(s.merchandise_amt, NVL(s.qty_po, 0) * NVL(s.price_po, 0)) AS sched_amt,
      NVL(vs.merch_amt_vchr, 0) AS merch_amt_vchr,
      NVL(vs.qty_vchr, 0)       AS qty_vchr,
      GREATEST(NVL(s.merchandise_amt, NVL(s.qty_po, 0) * NVL(s.price_po, 0)) - NVL(vs.merch_amt_vchr, 0), 0) AS rem_amt,
      GREATEST(NVL(s.qty_po, 0) - NVL(vs.qty_vchr, 0), 0) AS rem_qty
  FROM ps_po_line_ship s
  JOIN hdr_candidates hc
    ON hc.business_unit = s.business_unit
   AND hc.po_id         = s.po_id
  JOIN po_line_flags lf
    ON lf.business_unit = s.business_unit
   AND lf.po_id         = s.po_id
   AND lf.line_nbr      = s.line_nbr
  JOIN ps_po_line_distrib d
    ON d.business_unit      = s.business_unit
   AND d.po_id              = s.po_id
   AND d.line_nbr           = s.line_nbr
   AND d.sched_nbr          = s.sched_nbr
   AND d.distrib_ln_status <> 'X'
  LEFT JOIN vchr_sum_match vs
    ON vs.business_unit = s.business_unit
   AND vs.po_id         = s.po_id
   AND vs.line_nbr      = s.line_nbr
   AND vs.sched_nbr     = s.sched_nbr
  WHERE NVL(s.cancel_status, ' ') NOT IN ('C', 'X')
),

/* ======================
   6) Per-PO rollups + reason
   ====================== */
po_recon AS (
  SELECT
      sf.business_unit,
      sf.po_id,
      MAX(svc.has_service) AS has_service,

      /* Remaining by rule */
      SUM(
        CASE
          WHEN svc.has_service = 'Y' THEN 0
          WHEN sf.amt_only_flg = 'Y' THEN sf.rem_amt
          ELSE sf.rem_qty * sf.price_po
        END
      ) AS goods_remaining_amt,
      SUM(
        CASE
          WHEN svc.has_service = 'Y' THEN sf.rem_amt
          ELSE 0
        END
      ) AS service_remaining_amt,

      /* Open flags (for explaining why) */
      MAX(CASE WHEN svc.has_service = 'Y' AND sf.rem_amt > 0 THEN 1 ELSE 0 END) AS has_service_amt_open,
      MAX(CASE WHEN svc.has_service = 'N' AND sf.amt_only_flg = 'Y' AND sf.rem_amt > 0 THEN 1 ELSE 0 END) AS has_goods_amt_only_open,
      MAX(CASE WHEN svc.has_service = 'N' AND sf.amt_only_flg <> 'Y' AND sf.rem_qty > 0 THEN 1 ELSE 0 END) AS has_goods_qty_open
  FROM sched_facts sf
  JOIN service_flags svc
    ON svc.business_unit = sf.business_unit
   AND svc.po_id         = sf.po_id
  GROUP BY sf.business_unit, sf.po_id
),

po_out AS (
  SELECT
      r.business_unit,
      r.po_id,
      r.has_service,
      r.goods_remaining_amt,
      r.service_remaining_amt,
      (r.goods_remaining_amt + r.service_remaining_amt) AS total_remaining_amt,
      CASE
        WHEN r.has_service_amt_open = 1 THEN 'SERVICE_REMAINING_AMT_GT_0'
        WHEN r.has_goods_amt_only_open = 1 THEN 'GOODS_AMT_ONLY_REMAINING_AMT_GT_0'
        WHEN r.has_goods_qty_open = 1 THEN 'GOODS_QTY_REMAINING_GT_0'
        ELSE 'NOT_OPEN_BY_RULES'
      END AS oracle_reason_included
  FROM po_recon r
  WHERE (r.goods_remaining_amt + r.service_remaining_amt) > 0
)

/* ==========================================================
   OUTPUT 1: Overall totals
   ========================================================== */
SELECT
  COUNT(*) AS po_cnt,
  SUM(CASE WHEN has_service = 'Y' THEN 1 ELSE 0 END) AS service_po_cnt,
  SUM(CASE WHEN has_service = 'N' THEN 1 ELSE 0 END) AS goods_po_cnt,
  SUM(goods_remaining_amt) AS goods_remaining_amt_total,
  SUM(service_remaining_amt) AS service_remaining_amt_total,
  SUM(total_remaining_amt) AS total_remaining_amt
FROM po_out
;

/* ==========================================================
   OUTPUT 2: Counts by reason
   ========================================================== */
SELECT
  oracle_reason_included,
  COUNT(*) AS po_cnt,
  SUM(total_remaining_amt) AS total_remaining_amt
FROM po_out
GROUP BY oracle_reason_included
ORDER BY oracle_reason_included
;

/* ==========================================================
   OUTPUT 3: Detailed per-PO (top 500 by remaining amount)
   ========================================================== */
SELECT
  business_unit,
  po_id,
  has_service,
  goods_remaining_amt,
  service_remaining_amt,
  total_remaining_amt,
  oracle_reason_included
FROM (
  SELECT
    p.*,
    ROW_NUMBER() OVER (ORDER BY total_remaining_amt DESC, business_unit, po_id) AS rn
  FROM po_out p
)
WHERE rn <= 500
ORDER BY total_remaining_amt DESC, business_unit, po_id
;

