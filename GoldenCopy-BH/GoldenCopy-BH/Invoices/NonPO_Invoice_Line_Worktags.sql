/* ============================================================================
   Workday EIB – Non?PO Invoice Line Worktags – 12?month lookback
   - Only for NON?PO vouchers within lookback (no PO on header or any line)
   - Exclude adjustments
   ============================================================================ */

WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),


/* 1) Voucher candidates (date filter without TRUNC; same result set) */
voucher_candidates AS (
  SELECT /*+ MATERIALIZE */
         v.business_unit,
         v.voucher_id
          FROM ps_voucher v
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND v.voucher_style <> 'ADJ' -- AND V.VOUCHER_ID='05312841'
    AND v.appr_status = 'A'
    AND v.voucher_style<>'JRNL'
    AND NVL(v.invoice_dt, v.entered_dt) >= p.lookback_dt
    AND NVL(v.invoice_dt, v.entered_dt) <  (p.asof_dt + 1)
    AND NVL(v.po_id,' ') = ' '              -- Non-PO header PO blank
),

/* 2) Vouchers that have ANY PO on ANY voucher line (restricted) */
has_po_line AS (
  SELECT /*+ MATERIALIZE */ DISTINCT vl.business_unit, vl.voucher_id
  FROM ps_voucher_line vl
  JOIN voucher_candidates vc
    ON vc.business_unit = vl.business_unit
   AND vc.voucher_id    = vl.voucher_id
  WHERE vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
),

/* 3) Paid vouchers (restricted to candidates; avoids full scan of xref) */
paid_xref AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN voucher_candidates vc
    ON vc.business_unit = px.business_unit
   AND vc.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND ABS(NVL(px.paid_amt,0)) > 0
),

/* 3) Paid zero amount vouchers (restricted to candidates; avoids full scan of xref) */
paid_zero_amt_xref AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN voucher_candidates vc
    ON vc.business_unit = px.business_unit
   AND vc.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND ABS(NVL(px.paid_amt,0)) = 0 and pymnt_selct_status='P'
),

/*exclude vouchers having department =99999*/
exclude_dept AS (
  SELECT DISTINCT
         d.business_unit,
         d.voucher_id
  FROM ps_distrib_line d
  JOIN voucher_candidates vc
    ON vc.business_unit = d.business_unit
   AND vc.voucher_id    = d.voucher_id
  JOIN ps_voucher_line k
    ON k.business_unit     = d.business_unit
   AND k.voucher_id        = d.voucher_id
   AND k.voucher_line_num  = d.voucher_line_num
  WHERE d.deptid = '99999'
),

/* 4) Final drive set: approved + unpaid + nonpo (no PO lines) */
nonpo_vouchers AS (
  SELECT /*+ MATERIALIZE */ vc.*
  FROM voucher_candidates vc
  LEFT JOIN has_po_line hp
    ON hp.business_unit = vc.business_unit
   AND hp.voucher_id    = vc.voucher_id
  LEFT JOIN paid_xref px
    ON px.business_unit = vc.business_unit
   AND px.voucher_id    = vc.voucher_id
    left join paid_zero_amt_xref npx
    ON npx.business_unit = vc.business_unit
   AND npx.voucher_id    = vc.voucher_id
  LEFT JOIN exclude_dept DL
   ON DL.business_unit = vc.business_unit
   AND DL.voucher_id    = vc.voucher_id
  WHERE hp.voucher_id IS NULL          -- exclude any voucher with PO on any line
    AND px.voucher_id IS NULL          -- unpaid
    AND npx.voucher_id IS NULL          -- unpaid
    AND DL.voucher_id IS NULL          -- Exclude deptid = '99999' vouchers
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

qual_lines AS (
  SELECT /*+ MATERIALIZE */ DISTINCT
         v.business_unit,
         v.voucher_id,
         vl.voucher_line_num
  FROM ps_voucher v
  JOIN nonpo_vouchers nv
    ON nv.business_unit = v.business_unit
   AND nv.voucher_id    = v.voucher_id
  JOIN ps_voucher_line vl
    ON vl.business_unit = v.business_unit
   AND vl.voucher_id    = v.voucher_id
  JOIN ps_bh_wd_sup_1to1 wd ON v.vendor_id = wd.bh_wd_ps_vendor_id 
  WHERE NVL(vl.po_id,' ') = ' '
),


base AS (
  SELECT
      voucher_id,
      voucher_line_num,
      ROW_NUMBER() OVER (
          PARTITION BY voucher_id, voucher_line_num
          ORDER BY
              CASE field_name
                  WHEN 'DEPTID' THEN 1
                  WHEN 'FUND' THEN 2
                  WHEN 'PROJECT_ACTIVITY' THEN 3
              END
      ) AS row_num,
      value
  FROM (
      SELECT
          q.voucher_id,
          q.voucher_line_num,
        --  'CC_'||d.operating_unit||'-'||d.deptid as deptid,
          NVL(REPLACE(cc.wd_cost_center, ' ', '_'),'CC_'||d.operating_unit||'-'||d.deptid) AS deptid,
          d.fund_code,
          CASE
              WHEN TRIM(d.project_id) <> ' ' AND TRIM(d.activity_id) <> ' '
                THEN d.project_id || ' ' || d.activity_id
              WHEN TRIM(d.project_id) <> ' ' AND (d.activity_id IS NULL OR TRIM(d.activity_id) = '')
                THEN d.project_id
              WHEN (d.project_id IS NULL OR TRIM(d.project_id) = '') AND TRIM(d.activity_id) <> ' '
                THEN d.activity_id
              ELSE NULL
          END AS project_activity
      FROM qual_lines q
      JOIN ps_distrib_line d
        ON d.business_unit    = q.business_unit
       AND d.voucher_id       = q.voucher_id
       AND d.voucher_line_num = q.voucher_line_num
         LEFT JOIN cc_cocnt cc
  ON cc.ps_op_unit = d.operating_unit
 AND cc.ps_deptid  = d.deptid
  )
  UNPIVOT (
      value FOR field_name IN (
          deptid AS 'DEPTID',
          fund_code AS 'FUND',
          project_activity AS 'PROJECT_ACTIVITY'
      )
  )
  WHERE TRIM(value) IS NOT NULL
  /*  AND TRIM(value) <> ''
    AND TRIM(value) <> ' '*/
)

SELECT
    b.voucher_id       AS "*No.",
   b.voucher_id||'-'|| b.voucher_line_num AS "*Invoice Line Replacement Data Line No",
    b.row_num          AS "*Invoice Line Worktags Line No",
    b.value            AS "Worktags"
FROM base b
ORDER BY b.voucher_id, b.voucher_line_num, b.row_num

