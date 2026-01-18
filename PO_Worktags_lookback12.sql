/* ============================================================================
   Workday EIB – PO Invoice Line Worktags – 12‑month lookback + Open PO scope
   - Only for PO invoice lines tied to INCLUDED open GOODS PO lines
   - Keys match existing worktags file: (*No.=VOUCHER_ID, *Invoice Line Replacement Data Line No=VOUCHER_LINE_NUM)
   ============================================================================ */

WITH
params AS (
  /* Keep in sync with PO_Header.sql / Goods_PO_Line.sql / Service_PO_Line.sql */
  SELECT TRUNC(to_date('15-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),
hdr_candidates AS (
  /* Candidate open-ish POs (status + lookback window), aligned to line/header extracts */
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

/* only count vouchered amt/qty when voucher is MATCHED + PAID (aligned to Goods_PO_Line.sql) */
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
  JOIN hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.match_status_vchr = 'M'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
    AND EXISTS (
      SELECT /*+ NO_UNNEST INDEX(px SYSADM.PSDPYMNT_VCHR_XREF) */ 1
      FROM ps_pymnt_vchr_xref px
      WHERE px.business_unit = v.business_unit
        AND px.voucher_id    = v.voucher_id
        AND px.pymnt_action  <> 'X'
        AND px.paid_amt      > 0
        AND ROWNUM = 1
    )
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

/* Line flags (recv required + amount-only), aligned */
po_line_flags AS (
  SELECT /*+ LEADING(hc l) USE_NL(l) INDEX(l) */
         l.business_unit,
         l.po_id,
         l.line_nbr,
         NVL(l.recv_req,'Y')     AS recv_req,
         NVL(l.amt_only_flg,'N') AS amt_only_flg
  FROM ps_po_line l
  JOIN hdr_candidates hc
    ON hc.business_unit = l.business_unit
   AND hc.po_id         = l.po_id
),

sched_open AS (
  /* Open schedule logic aligned to Goods_PO_Line.sql */
  SELECT /*+ LEADING(hc s) USE_NL(s) INDEX(s) */
         s.business_unit,
         s.po_id,
         s.line_nbr,
         s.sched_nbr,
         s.cancel_status,
         s.qty_po,
         s.price_po,
         s.merchandise_amt,
         s.liquidate_method,
         lf.recv_req,
         lf.amt_only_flg,
         NVL(vs.merch_amt_vchr, 0) AS merch_amt_vchr,
         NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) AS sched_amt,
         NVL(vs.qty_vchr, 0) AS qty_vchr,
         CASE
           WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
           WHEN lf.amt_only_flg = 'Y' THEN
             CASE
               WHEN GREATEST(
                      NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0))
                    - NVL(vs.merch_amt_vchr,0),
                    0
                    ) > 1
               THEN 1 ELSE 0
             END
           WHEN lf.recv_req = 'Y' THEN
             CASE
               WHEN NVL(s.qty_po,0) > NVL(vs.qty_vchr,0) THEN 1 ELSE 0
             END
           ELSE
             CASE
               WHEN GREATEST(
                      NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0))
                    - NVL(vs.merch_amt_vchr,0),
                    0
                    ) > 1
               THEN 1 ELSE 0
             END
         END AS is_open
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
),

/* Precompute POs that have at least one OPEN schedule + active line + active distrib (aligned) */
open_po_eligible AS (
  SELECT /*+ MATERIALIZE LEADING(so l d) USE_NL(l) INDEX(l) USE_NL(d) INDEX(d) */
         so.business_unit,
         so.po_id
    FROM sched_open so
    JOIN ps_po_line l
      ON l.business_unit = so.business_unit
     AND l.po_id         = so.po_id
     AND l.line_nbr      = so.line_nbr
     AND l.cancel_status <> 'X'
    JOIN ps_po_line_distrib d
      ON d.business_unit      = so.business_unit
     AND d.po_id              = so.po_id
     AND d.line_nbr           = so.line_nbr
     AND d.sched_nbr          = so.sched_nbr
     AND d.distrib_ln_status <> 'X'
   WHERE so.is_open = 1
   GROUP BY so.business_unit, so.po_id
),

/* Non-service PO filter (PO-level), aligned to goods extract */
service_flags AS (
  SELECT /*+ LEADING(hc d) USE_NL(d) INDEX(d) */
         d.business_unit,
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

open_pos AS (
  /* OPEN goods POs in scope: same driver set as Goods_PO_Line.sql */
  SELECT /*+ MATERIALIZE */ DISTINCT hc.business_unit, hc.po_id, hc.po_dt
    FROM hdr_candidates hc
    CROSS JOIN params p
   WHERE hc.po_dt >= p.lookback_dt
     AND EXISTS (
       SELECT 1
         FROM open_po_eligible ope
        WHERE ope.business_unit = hc.business_unit
          AND ope.po_id         = hc.po_id
     )
     AND EXISTS (
       SELECT 1
         FROM service_flags sf
        WHERE sf.business_unit = hc.business_unit
          AND sf.po_id         = hc.po_id
          AND sf.has_service   = 'N'
     )
     AND EXISTS (
       SELECT 1
         FROM ps_bh_wd_sup_1to1 wd
        WHERE wd.bh_wd_ps_vendor_id = hc.vendor_id
     )
     AND EXISTS (
       SELECT 1
         FROM ps_bus_unit_tbl_pm bu
        WHERE bu.business_unit = hc.business_unit
     )
),

included_po AS (
  SELECT /*+ MATERIALIZE */ op.business_unit, op.po_id
    FROM open_pos op
),

included_goods_lines AS (
  /* Goods lines/schedules that would be INCLUDED by Goods_PO_Line.sql (remaining qty/amount gates) */
  SELECT /*+ MATERIALIZE */ DISTINCT
         l.business_unit,
         l.po_id,
         s.line_nbr,
         s.sched_nbr
  FROM included_po ip
  JOIN ps_po_line l
    ON l.business_unit = ip.business_unit
   AND l.po_id         = ip.po_id
   AND l.physical_nature = 'G'
  JOIN ps_po_line_ship s
    ON s.business_unit = l.business_unit
   AND s.po_id         = l.po_id
   AND s.line_nbr      = l.line_nbr
  JOIN sched_open so
    ON so.business_unit = s.business_unit
   AND so.po_id         = s.po_id
   AND so.line_nbr      = s.line_nbr
   AND so.sched_nbr     = s.sched_nbr
   AND so.is_open       = 1
  LEFT JOIN vchr_sum_match vs
    ON vs.business_unit = s.business_unit
   AND vs.po_id         = s.po_id
   AND vs.line_nbr      = s.line_nbr
   AND vs.sched_nbr     = s.sched_nbr
  WHERE l.cancel_status <> 'X'
    AND s.cancel_status <> 'X'
    AND (
      CASE
        WHEN so.amt_only_flg = 'Y' THEN 1
        ELSE GREATEST(NVL(s.qty_po,0) - NVL(vs.qty_vchr,0), 0)
      END
    ) > 0
    AND (
      CASE
        WHEN so.amt_only_flg = 'Y' THEN GREATEST(NVL(so.sched_amt,0) - NVL(so.merch_amt_vchr,0), 0)
        ELSE GREATEST(NVL(s.qty_po,0) - NVL(vs.qty_vchr,0), 0) * NVL(s.price_po,0)
      END
    ) > 0
),
qual_lines AS (
  SELECT /*+ MATERIALIZE */ DISTINCT
         vl.business_unit,
         vl.voucher_id,
         vl.voucher_line_num
  FROM ps_voucher v
  JOIN ps_voucher_line vl
    ON vl.business_unit = v.business_unit
   AND vl.voucher_id    = v.voucher_id
  JOIN included_goods_lines gl
    ON gl.business_unit = vl.business_unit_po
   AND gl.po_id         = vl.po_id
   AND gl.line_nbr      = vl.line_nbr
   AND gl.sched_nbr     = NVL(vl.sched_nbr, gl.sched_nbr)
  JOIN params p ON 1=1
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND v.voucher_style <> 'ADJ'
    AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
),

base AS (
  SELECT
      q.voucher_id,
      q.voucher_line_num,
      ROW_NUMBER() OVER(
          PARTITION BY q.voucher_id, q.voucher_line_num
          ORDER BY CASE field_name WHEN 'DEPTID' THEN 1 ELSE 2 END
      ) AS row_num,
      value
  FROM (
      SELECT
          q.voucher_id,
          q.voucher_line_num,
          d.deptid,
          d.project_id
      FROM qual_lines q
      JOIN ps_distrib_line d
        ON d.business_unit      = q.business_unit
       AND d.voucher_id         = q.voucher_id
       AND d.voucher_line_num   = q.voucher_line_num
  )
  UNPIVOT ( value FOR field_name IN (deptid AS 'DEPTID', project_id AS 'PROJECT_ID') )
  WHERE TRIM(value) IS NOT NULL
)

SELECT
  b.voucher_id        AS "*No.",
  b.voucher_line_num  AS "*Invoice Line Replacement Data Line No",
  b.row_num           AS "*Invoice Line Worktags Line No",
  b.value             AS "Worktags"
FROM base b
ORDER BY b.voucher_id, b.voucher_line_num, b.row_num
;
