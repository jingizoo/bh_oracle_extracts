/*
Grand reconciliation: DuckDB outputs vs PeopleSoft (Oracle)

What this file gives you:
1) DuckDB: counts + amount totals by PO from your extracted tables
2) Oracle: a template query to validate those same POs against PeopleSoft rules
   (open + remaining amount / qty-based remaining) and explain WHY each PO is included.

Assumptions:
- DuckDB tables (sanitized):
  - po_header(no, purchase_order_type, ...)
  - goods_po_line(no, extended_amount, quantity, ...)
  - service_po_line(no, extended_amount, ...)
- Oracle rules follow your latest hinted SQLs:
  - Goods open is driven by vouchered qty/amt (matched + paid) + flags (amt_only_flg, recv_req)
  - Service open is amount-based remaining > 0

NOTE: Oracle cannot read DuckDB tables directly.
Workflow:
- Run the DuckDB section to get (a) summary counts and (b) a PO list for Oracle.
- Paste the PO list into the Oracle section (duckdb_po_list CTE) and run in SQL Developer.
*/

/* =====================================================================
   1) DUCKDB SECTION (run in DuckDB against extracts.duckdb)
   ===================================================================== */

-- 1.1) Distinct PO counts (header vs lines)
WITH
hdr_pos AS (SELECT DISTINCT no AS po_id FROM po_header),
line_pos AS (
  SELECT DISTINCT no AS po_id FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_id FROM service_po_line
)
SELECT metric, val
FROM (
  SELECT 'DUCKDB_HDR_DISTINCT_PO' AS metric, COUNT(*)::BIGINT AS val FROM hdr_pos
  UNION ALL
  SELECT 'DUCKDB_LINES_DISTINCT_PO', COUNT(*)::BIGINT FROM line_pos
  UNION ALL
  SELECT 'DUCKDB_LINES_MINUS_HDR_CNT',
         (SELECT COUNT(*)::BIGINT FROM (SELECT po_id FROM line_pos EXCEPT SELECT po_id FROM hdr_pos))
  UNION ALL
  SELECT 'DUCKDB_HDR_MINUS_LINES_CNT',
         (SELECT COUNT(*)::BIGINT FROM (SELECT po_id FROM hdr_pos EXCEPT SELECT po_id FROM line_pos))
)
ORDER BY metric;

-- 1.2) Amount totals by PO (DuckDB) + a simple “why included” derived from outputs
WITH
g AS (
  SELECT
    no AS po_id,
    COUNT(*)::BIGINT AS goods_line_cnt,
    SUM(COALESCE(try_cast(extended_amount AS DOUBLE), 0.0)) AS goods_amt
  FROM goods_po_line
  GROUP BY no
),
s AS (
  SELECT
    no AS po_id,
    COUNT(*)::BIGINT AS service_line_cnt,
    SUM(COALESCE(try_cast(extended_amount AS DOUBLE), 0.0)) AS service_amt
  FROM service_po_line
  GROUP BY no
),
u AS (
  SELECT po_id FROM g
  UNION
  SELECT po_id FROM s
)
SELECT
  u.po_id,
  COALESCE(g.goods_line_cnt, 0) AS goods_line_cnt,
  COALESCE(s.service_line_cnt, 0) AS service_line_cnt,
  COALESCE(g.goods_amt, 0.0) AS goods_amt,
  COALESCE(s.service_amt, 0.0) AS service_amt,
  COALESCE(g.goods_amt, 0.0) + COALESCE(s.service_amt, 0.0) AS total_amt,
  CASE
    WHEN COALESCE(s.service_amt, 0.0) > 0.0 THEN 'SERVICE_LINE_AMT_GT_0'
    WHEN COALESCE(g.goods_amt, 0.0) > 0.0 THEN 'GOODS_LINE_AMT_GT_0'
    ELSE 'NO_AMT'
  END AS duckdb_reason
FROM u
LEFT JOIN g ON g.po_id = u.po_id
LEFT JOIN s ON s.po_id = u.po_id
ORDER BY total_amt DESC
LIMIT 200;

-- 1.2b) Full totals (DuckDB) (counts + sums across ALL POs)
WITH
g AS (
  SELECT
    no AS po_id,
    SUM(COALESCE(try_cast(extended_amount AS DOUBLE), 0.0)) AS goods_amt
  FROM goods_po_line
  GROUP BY no
),
s AS (
  SELECT
    no AS po_id,
    SUM(COALESCE(try_cast(extended_amount AS DOUBLE), 0.0)) AS service_amt
  FROM service_po_line
  GROUP BY no
),
u AS (
  SELECT po_id FROM g
  UNION
  SELECT po_id FROM s
)
SELECT
  COUNT(*)::BIGINT AS distinct_po_cnt,
  SUM(COALESCE(g.goods_amt, 0.0)) AS goods_amt_total,
  SUM(COALESCE(s.service_amt, 0.0)) AS service_amt_total,
  SUM(COALESCE(g.goods_amt, 0.0) + COALESCE(s.service_amt, 0.0)) AS total_amt
FROM u
LEFT JOIN g ON g.po_id = u.po_id
LEFT JOIN s ON s.po_id = u.po_id;

-- 1.3) PO list for Oracle (copy/paste output into Oracle CTE below)
-- NOTE: DuckDB result is a 1-column list; paste into Oracle using UNION ALL SELECT ... FROM dual.
WITH line_pos AS (
  SELECT DISTINCT no AS po_id FROM goods_po_line
  UNION
  SELECT DISTINCT no AS po_id FROM service_po_line
)
SELECT po_id
FROM line_pos
ORDER BY po_id;


/* =====================================================================
   2) ORACLE SECTION (run in Oracle SQL Developer)
   ===================================================================== */

/* 2.0) Paste DuckDB PO list here:
duckdb_po_list AS (
  SELECT '0001234567' AS po_id FROM dual
  UNION ALL SELECT '0002345678' FROM dual
  -- ...
),
*/

/* 2.1) Oracle validation + “why included”
   - Produces per-PO remaining amounts based on your rules and indicates which rule included it.
*/
WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),
duckdb_po_list AS (
  /* REPLACE THIS BLOCK with DuckDB PO list (see 2.0) */
  SELECT '<<PASTE_PO_ID>>' AS po_id FROM dual
),
hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status,
         h.vendor_id
  FROM ps_po_hdr h
  JOIN duckdb_po_list d
    ON d.po_id = h.po_id
  CROSS JOIN params p
  WHERE h.po_dt <= p.asof_dt
    AND h.po_dt >= p.lookback_dt
    AND h.po_status NOT IN ('C','X')
    AND h.vendor_id <> '2000017041'
),

/* Service flag (PO-level) */
service_flags AS (
  SELECT d.business_unit,
         d.po_id,
         CASE WHEN MAX(x.bh_xwlk_t1) IS NOT NULL THEN 'Y' ELSE 'N' END AS has_service
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

/* Paid vouchers as-of (use your latest header logic: PS_PAYMENT_TBL status 'P') */
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

/* Matched+paid voucher totals by PO line/sched */
vchr_sum_match AS (
  SELECT
      vl.business_unit_po AS business_unit,
      vl.po_id,
      vl.line_nbr,
      NVL(vl.sched_nbr, 1) AS sched_nbr,
      SUM(NVL(vl.merchandise_amt,0)) AS merch_amt_vchr,
      SUM(NVL(vl.qty_vchr,0))        AS qty_vchr
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
    AND v.match_status_vchr = 'M'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

po_line_flags AS (
  SELECT l.business_unit,
         l.po_id,
         l.line_nbr,
         NVL(l.recv_req,'Y')     AS recv_req,
         NVL(l.amt_only_flg,'N') AS amt_only_flg
  FROM ps_po_line l
  JOIN hdr_candidates hc
    ON hc.business_unit = l.business_unit
   AND hc.po_id         = l.po_id
),

/* Schedule facts (1 row per schedule) */
sched_facts AS (
  SELECT
      s.business_unit,
      s.po_id,
      s.line_nbr,
      s.sched_nbr,
      lf.recv_req,
      lf.amt_only_flg,
      s.cancel_status,
      NVL(s.qty_po, 0) AS qty_po,
      NVL(s.price_po, 0) AS price_po,
      NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) AS sched_amt,
      NVL(vs.merch_amt_vchr, 0) AS merch_amt_vchr,
      NVL(vs.qty_vchr, 0) AS qty_vchr,
      /* remaining amount/qty pieces */
      GREATEST(NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0), 0) AS rem_amt,
      GREATEST(NVL(s.qty_po,0) - NVL(vs.qty_vchr,0), 0) AS rem_qty
  FROM ps_po_line_ship s
  JOIN hdr_candidates hc
    ON hc.business_unit = s.business_unit
   AND hc.po_id         = s.po_id
  JOIN po_line_flags lf
    ON lf.business_unit = s.business_unit
   AND lf.po_id         = s.po_id
   AND lf.line_nbr      = s.line_nbr
  LEFT JOIN vchr_sum_match vs
    ON vs.business_unit = s.business_unit
   AND vs.po_id         = s.po_id
   AND vs.line_nbr      = s.line_nbr
   AND vs.sched_nbr     = s.sched_nbr
  WHERE NVL(s.cancel_status,' ') NOT IN ('C','X')
),

/* Per-PO rollups using the same logic as your extracts */
po_recon AS (
  SELECT
      sfacts.business_unit,
      sfacts.po_id,
      MAX(svc.has_service) AS has_service,

      /* Goods remaining amount (qty-based or amount-based depending on flags) */
      SUM(
        CASE
          WHEN svc.has_service = 'Y' THEN 0
          WHEN sfacts.amt_only_flg = 'Y' THEN sfacts.rem_amt
          WHEN sfacts.recv_req = 'Y' THEN sfacts.rem_qty * sfacts.price_po
          ELSE sfacts.rem_qty * sfacts.price_po
        END
      ) AS goods_remaining_amt,

      /* Service remaining amount (always amount-based) */
      SUM(
        CASE
          WHEN svc.has_service = 'Y' THEN sfacts.rem_amt
          ELSE 0
        END
      ) AS service_remaining_amt,

      /* Simple rule flags for “why included” */
      MAX(CASE WHEN svc.has_service = 'Y' AND sfacts.rem_amt > 0 THEN 1 ELSE 0 END) AS has_service_amt_open,
      MAX(CASE WHEN svc.has_service = 'N' AND sfacts.amt_only_flg = 'Y' AND sfacts.rem_amt > 0 THEN 1 ELSE 0 END) AS has_goods_amt_only_open,
      MAX(CASE WHEN svc.has_service = 'N' AND sfacts.amt_only_flg <> 'Y' AND sfacts.rem_qty > 0 THEN 1 ELSE 0 END) AS has_goods_qty_open

  FROM sched_facts sfacts
  JOIN service_flags svc
    ON svc.business_unit = sfacts.business_unit
   AND svc.po_id         = sfacts.po_id
  GROUP BY sfacts.business_unit, sfacts.po_id
)
SELECT
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
ORDER BY total_remaining_amt DESC;

