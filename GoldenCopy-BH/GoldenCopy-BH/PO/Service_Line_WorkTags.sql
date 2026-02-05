/* Service PO Line worktags for Workday:
   - Reuses the open‑service‑PO line population from the service line extract
   - Picks distributions and derives cost center / project / fund worktags for each line
   - Outputs one or more worktag rows per service PO line in the Workday layout */

WITH
params AS (
  SELECT TRUNC(to_date('15-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),

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
    AND h.po_status NOT IN ('C','X')
    AND h.vendor_id <> '2000017041'
),

/* Vouchered to date (remove NVL(TRIM) check; use PS-safe blank check) */
/* only count vouchered amt/qty when voucher is MATCHED + PAID */
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


/* Line flags (recv required + amount-only) */
po_line_flags AS (
  SELECT /*+ LEADING(hc l) USE_NL(l) INDEX(l) */ l.business_unit,
         l.po_id,
         l.line_nbr,
         NVL(l.recv_req,'Y')     AS recv_req,
         NVL(l.amt_only_flg,'N') AS amt_only_flg
    FROM ps_po_line l
    JOIN hdr_candidates hc
      ON hc.business_unit = l.business_unit
     AND hc.po_id         = l.po_id
),

/* Open schedule flag (aligned) */
sched_open AS (
  SELECT /*+ LEADING(hc s) USE_NL(s) INDEX(s) */ s.business_unit,
         s.po_id,
         s.line_nbr,
         s.sched_nbr,
         s.cancel_status,
         s.due_dt,
         s.shipto_setid,
         s.shipto_id,
         s.qty_po,
         s.price_po,
         s.merchandise_amt,
         s.liquidate_method,
         lf.recv_req,
         lf.amt_only_flg,
NVL(vs.merch_amt_vchr, 0)   AS merch_amt_vchr,
         NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) AS sched_amt,
         NVL (vs.qty_vchr,0) as qty_vchr,
         GREATEST(
        NVL(s.merchandise_amt, (NVL(s.qty_po,0) * NVL(s.price_po,0)))
        - NVL(vs.merch_amt_vchr, 0),
        0
      ) AS remaining_amt,
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
     -- WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0)
 WHEN NVL(s.qty_po,0) > NVL(vs.qty_vchr,0)      THEN 1 ELSE 0
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
)
--SELECT * FROM sched_open;
,



/* Precompute POs that have at least one OPEN schedule + active line + active distrib */
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
)

,
service_flags AS (
  SELECT d.business_unit,
         d.po_id,
         CASE WHEN MAX(x.bh_xwlk_t1) IS NOT NULL THEN 'Y' ELSE 'N' END AS has_service
  FROM hdr_candidates hc
  JOIN ps_po_line_distrib d
    ON d.business_unit = hc.business_unit
   AND d.po_id         = hc.po_id
  LEFT JOIN PS_BH_XWLK_VAL_TBL x
    ON x.LONGNAME       = 'WD_ACCT_TO_PO_TYPE'
   AND x.bh_xwlk_module = 'PO'
   AND x.bh_xwlk_track  = 'SCM'
   AND x.BH_XWLK_S2     = d.account
  GROUP BY d.business_unit, d.po_id
),

open_pos AS (
  SELECT /*+ MATERIALIZE */ DISTINCT hc.business_unit, hc.po_id
  FROM hdr_candidates hc
  CROSS JOIN params p
  WHERE hc.po_dt >= p.lookback_dt
    AND EXISTS (
      SELECT 1 FROM open_po_eligible ope
      WHERE ope.business_unit = hc.business_unit
        AND ope.po_id         = hc.po_id
    )
    AND EXISTS (
      SELECT 1 FROM service_flags sf
      WHERE sf.business_unit = hc.business_unit
        AND sf.po_id         = hc.po_id
        AND sf.has_service   = 'Y'
    )
    AND EXISTS (
      SELECT 1 FROM ps_bh_wd_sup_1to1 wd
      WHERE wd.bh_wd_ps_vendor_id = hc.vendor_id
    )
    AND EXISTS (
      SELECT 1 FROM ps_bus_unit_tbl_pm bu
      WHERE bu.business_unit = hc.business_unit
    )
),

/* Final PO population = header PO set (no extra lookback ORs) */
included_po AS (
  SELECT /*+ MATERIALIZE */ op.business_unit, op.po_id
    FROM open_pos op
),

open_sched_pick AS (
  SELECT business_unit,
         po_id,
         line_nbr,
         MIN(sched_nbr) KEEP (DENSE_RANK FIRST ORDER BY sched_nbr) AS sched_nbr
  FROM sched_open
  WHERE is_open = 1
  GROUP BY business_unit, po_id, line_nbr
),

po_distrib_one AS (
  SELECT *
  FROM (
    SELECT d.*,
           ROW_NUMBER() OVER (
             PARTITION BY d.business_unit, d.po_id, d.line_nbr, d.sched_nbr
             ORDER BY CASE WHEN d.dst_acct_type = 'DST' THEN 0 ELSE 1 END,
                      d.distrib_line_num
           ) rn
    FROM ps_po_line_distrib d
    JOIN included_po ip
      ON ip.business_unit = d.business_unit
     AND ip.po_id         = d.po_id
    WHERE d.distrib_ln_status <> 'X'
  )
  WHERE rn = 1
),

included_service_lines AS (
  SELECT DISTINCT
         ip.business_unit,
         ip.po_id,
         osp.line_nbr,
         osp.sched_nbr
  FROM included_po ip
  JOIN open_sched_pick osp
    ON osp.business_unit = ip.business_unit
   AND osp.po_id         = ip.po_id
  JOIN sched_open so
    ON so.business_unit = osp.business_unit
   AND so.po_id         = osp.po_id
   AND so.line_nbr      = osp.line_nbr
   AND so.sched_nbr     = osp.sched_nbr
   AND so.is_open       = 1
   and so.remaining_amt >1
  JOIN ps_po_line l
    ON l.business_unit = so.business_unit
   AND l.po_id         = so.po_id
   AND l.line_nbr      = so.line_nbr
   AND l.cancel_status <> 'X'
  JOIN po_distrib_one d
    ON d.business_unit = so.business_unit
   AND d.po_id         = so.po_id
   AND d.line_nbr      = so.line_nbr
   AND d.sched_nbr     = so.sched_nbr
),
cc_cocnt AS (
  SELECT
      BH_WD_PS_OP_UNIT AS ps_op_unit,
      BH_WD_PS_DEPT    AS ps_deptid,

      /* prefer CO_80800 if duplicates ever exist; otherwise MAX works */
      MAX(BH_WD_FDM_COST_CNT) KEEP (
        DENSE_RANK FIRST ORDER BY
          CASE
            WHEN BH_WD_FDM_CCT_RSTR IN ('CO_80800','CO 80800') THEN 0
            ELSE 1
          END,
          BH_WD_FDM_CCT_RSTR
      ) AS wd_cost_center
  FROM PS_BH_WD_FDM_COCNT
  GROUP BY BH_WD_PS_OP_UNIT, BH_WD_PS_DEPT
),
unpivoted AS (
  SELECT
    po_id,
    line_nbr,
    ROW_NUMBER() OVER (
      PARTITION BY po_id, line_nbr
      ORDER BY CASE field_name
                 WHEN 'DEPTID' THEN 1
                 WHEN 'PROJECT_ID' THEN 2
                 WHEN 'FUND_CODE' THEN 3
               END
    ) AS row_num,
    value
  FROM (
    SELECT
      d.po_id,
      d.line_nbr,
      'CC_'||d.operating_unit||'-'||d.deptid AS deptid,
      d.project_id,
      d.fund_code
    FROM po_distrib_one d
    JOIN included_service_lines sl
      ON sl.business_unit = d.business_unit
     AND sl.po_id         = d.po_id
     AND sl.line_nbr      = d.line_nbr
     AND sl.sched_nbr     = d.sched_nbr
  )
  UNPIVOT (
    value FOR field_name IN (
      deptid     AS 'DEPTID',
      project_id AS 'PROJECT_ID',
      fund_code  AS 'FUND_CODE'
    )
  )
  WHERE TRIM(value) IS NOT NULL
)

SELECT
  u.po_id     AS "*No.",
  u.line_nbr  AS "*Service Line Replacement Data Line No",
  u.row_num   AS "*Worktags Line No",
  u.value     AS "*Worktags"
FROM unpivoted u
ORDER BY u.po_id, u.line_nbr, u.row_num