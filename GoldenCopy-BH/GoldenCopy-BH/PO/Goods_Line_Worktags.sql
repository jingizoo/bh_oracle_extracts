/* Goods PO Line worktags for Workday:
   - Reuses the open‑goods‑PO line population from the goods line extract
   - Picks one best distribution per line and derives cost center / project worktags
   - Outputs one or more worktag rows per goods PO line in the Workday layout */

WITH params AS (
    SELECT
        TRUNC(TO_DATE('15-01-2026','DD-MM-YYYY')) AS asof_dt,
        ADD_MONTHS(TRUNC(TO_DATE('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
    FROM dual
),

/* header candidates */
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

/* paid vouchers (your definition: xref exists with paid_amt>0, not cancelled) */
paid_vouchers AS (
    SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
    FROM ps_pymnt_vchr_xref px
    WHERE px.pymnt_action <> 'X'
      AND px.paid_amt > 0
),

/* only count vouchered amt/qty when voucher is MATCHED + PAID */
vchr_sum_match AS (
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
      AND v.match_status_vchr = 'M'
      AND vl.po_id IS NOT NULL
      AND vl.po_id <> ' '
      AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
    GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

/* line flags */
po_line_flags AS (
    SELECT /*+ MATERIALIZE */
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

/* sched_open (same logic as your current file) */
sched_open AS (
    SELECT
        s.business_unit,
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
        NVL(vs.merch_amt_vchr, 0) AS merch_amt_vchr,
        NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) AS sched_amt,
        NVL(vs.qty_vchr, 0) AS qty_vchr,

        CASE
          WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
          WHEN lf.amt_only_flg = 'Y' THEN
            CASE
              WHEN GREATEST(
                     NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0),
                     0
                   ) > 1
              THEN 1 ELSE 0
            END
          WHEN lf.recv_req = 'Y' THEN
            CASE WHEN NVL(s.qty_po,0) > NVL(vs.qty_vchr,0) THEN 1 ELSE 0 END
          ELSE
            CASE
              WHEN GREATEST(
                     NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0),
                     0
                   ) > 1
              THEN 1 ELSE 0
            END
        END AS is_open,

        CASE
          WHEN lf.amt_only_flg = 'Y' THEN 1
          WHEN lf.recv_req = 'Y' THEN GREATEST(NVL(s.qty_po,0) - NVL(vs.qty_vchr,0), 0)
          ELSE
            CASE
              WHEN NVL(s.price_po,0) = 0 THEN 0
              ELSE GREATEST(NVL(s.qty_po,0) - NVL(vs.qty_vchr,0), 0)
            END
        END AS qty_po1,

        CASE
          WHEN lf.amt_only_flg = 'Y' THEN
            GREATEST(NVL(NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)),0) - NVL(vs.merch_amt_vchr,0), 0)
          WHEN lf.recv_req = 'Y' THEN
            GREATEST(NVL(s.qty_po,0) - NVL(vs.qty_vchr,0), 0) * NVL(s.price_po,0)
          ELSE
            (GREATEST(NVL(s.qty_po,0) - NVL(vs.qty_vchr,0), 0)) * NULLIF(s.price_po,0)
        END AS extended_amt1

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

/* open PO eligibility: open schedule + active line + active distrib */
open_po_eligible AS (
  SELECT /*+ MATERIALIZE */
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

/* PO candidates FIRST (cuts service_flags cost massively) */
po_candidates AS (
  SELECT /*+ MATERIALIZE */ DISTINCT
         hc.business_unit,
         hc.po_id,
         hc.vendor_id
  FROM hdr_candidates hc
  CROSS JOIN params p
  JOIN open_po_eligible ope
    ON ope.business_unit = hc.business_unit
   AND ope.po_id         = hc.po_id
  JOIN ps_bh_wd_sup_1to1 wd
    ON wd.bh_wd_ps_vendor_id = hc.vendor_id
  JOIN ps_bus_unit_tbl_pm bu
    ON bu.business_unit = hc.business_unit
  WHERE hc.po_dt >= p.lookback_dt
),

/* service_flags computed only on po_candidates (same logic, smaller input) */
service_flags AS (
  SELECT /*+ MATERIALIZE */
         d.business_unit,
         d.po_id,
         CASE WHEN MAX(x.bh_xwlk_t1) IS NOT NULL THEN 'Y' ELSE 'N' END AS has_service
  FROM po_candidates pc
  JOIN ps_po_line_distrib d
    ON d.business_unit = pc.business_unit
   AND d.po_id         = pc.po_id
  LEFT JOIN ps_bh_xwlk_val_tbl x
    ON x.longname       = 'WD_ACCT_TO_PO_TYPE'
   AND x.bh_xwlk_module = 'PO'
   AND x.bh_xwlk_track  = 'SCM'
   AND x.bh_xwlk_s2     = d.account
  GROUP BY d.business_unit, d.po_id
),

/* final included POs (goods only) */
included_po AS (
  SELECT /*+ MATERIALIZE */ pc.business_unit, pc.po_id
  FROM po_candidates pc
  JOIN service_flags sf
    ON sf.business_unit = pc.business_unit
   AND sf.po_id         = pc.po_id
  WHERE sf.has_service = 'N'
),

/* pick first open sched per line (restricted to included POs) */
open_sched_pick AS (
  SELECT so.business_unit,
         so.po_id,
         so.line_nbr,
         MIN(so.sched_nbr) KEEP (DENSE_RANK FIRST ORDER BY so.sched_nbr) AS sched_nbr
  FROM sched_open so
  JOIN included_po ip
    ON ip.business_unit = so.business_unit
   AND ip.po_id         = so.po_id
  WHERE so.is_open = 1
  GROUP BY so.business_unit, so.po_id, so.line_nbr
),

/* line set (same filters, but use EXISTS to avoid distrib multiplication) */
included_goods_lines AS (
  SELECT
      osp.business_unit,
      osp.po_id,
      osp.line_nbr,
      osp.sched_nbr
  FROM open_sched_pick osp
  JOIN sched_open so
    ON so.business_unit = osp.business_unit
   AND so.po_id         = osp.po_id
   AND so.line_nbr      = osp.line_nbr
   AND so.sched_nbr     = osp.sched_nbr
   AND so.is_open       = 1
   AND so.extended_amt1 > 0
   AND so.qty_po1       > 0
  JOIN ps_po_line l
    ON l.business_unit = so.business_unit
   AND l.po_id         = so.po_id
   AND l.line_nbr      = so.line_nbr
   AND l.cancel_status <> 'X'
  WHERE EXISTS (
    SELECT 1
    FROM ps_po_line_distrib d
    WHERE d.business_unit      = so.business_unit
      AND d.po_id              = so.po_id
      AND d.line_nbr           = so.line_nbr
      AND d.sched_nbr          = so.sched_nbr
      AND d.distrib_ln_status <> 'X'
  )
),

/* compute distrib choice only for included lines */
po_distrib_one AS (
  SELECT *
  FROM (
    SELECT d.*,
           ROW_NUMBER() OVER (
             PARTITION BY d.business_unit, d.po_id, d.line_nbr, d.sched_nbr
             ORDER BY CASE WHEN d.dst_acct_type = 'DST' THEN 0 ELSE 1 END,
                      d.distrib_line_num
           ) AS rn
    FROM ps_po_line_distrib d
    JOIN included_goods_lines gl
      ON gl.business_unit = d.business_unit
     AND gl.po_id         = d.po_id
     AND gl.line_nbr      = d.line_nbr
     AND gl.sched_nbr     = d.sched_nbr
    WHERE d.distrib_ln_status <> 'X'
  )
  WHERE rn = 1
)   ,cc_cocnt AS (
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
      ORDER BY CASE field_name WHEN 'DEPTID' THEN 1 WHEN 'PROJECT_ID' THEN 2 END
    ) AS row_num,
    value
  FROM (
    SELECT
      d.po_id,
      d.line_nbr,
      --'CC_'||d.operating_unit||'-'||d.deptid AS deptid,
      NVL(REPLACE(cc.wd_cost_center, ' ', '_'),'CC_'||d.operating_unit||'-'||d.deptid) AS deptid,
      d.project_id
    FROM po_distrib_one d
    LEFT JOIN cc_cocnt cc
  ON cc.ps_op_unit = d.operating_unit
 AND cc.ps_deptid  = d.deptid
  )
  UNPIVOT ( value FOR field_name IN (deptid AS 'DEPTID', project_id AS 'PROJECT_ID') )
  WHERE TRIM(value) IS NOT NULL
)

SELECT
  u.po_id     AS "*No.",
  u.line_nbr  AS "*Goods Line Replacement Data Line No",
  u.row_num   AS "*Worktags Line No",
  u.value     AS "*Worktags"
FROM unpivoted u
ORDER BY u.po_id, u.line_nbr, u.row_num