/* ============================================================================
   Workday EIB – Supplier Invoice Adjustment LINE WORKTAGS
   Update for slide criteria:
   - ONLY adjustment vouchers in last 12 months
   - ONLY open/not-cancelled vouchers
   - Worktags derived from PS_DISTRIB_LINE for voucher lines
   ============================================================================
   Output columns per your Invoice_adjustment_worktags.txt:
     No.
     Invoice Line Replacement Data Line No
     Worktags Line No
     Worktags
   ============================================================================ */

WITH
params AS (
  SELECT TRUNC(to_date('01-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('01-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
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

/*Voucher List*/
vchr_list as (
select distinct v.*
FROM ps_voucher v
JOIN params p
  ON 1=1
JOIN ps_bh_wd_sup_1to1 wd
  ON v.vendor_id = wd.bh_wd_ps_vendor_id
JOIN ps_voucher_line vl
  ON vl.business_unit = v.business_unit
 AND vl.voucher_id    = v.voucher_id
WHERE v.gross_amt < 0 and v.voucher_style<>'JRNL' and v.origin <> 'FAV'
  AND v.entry_status <> 'X'  AND v.appr_status = 'A'
  AND v.close_status <> 'C'
  AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
 AND vl.merchandise_amt <>0
),



/* Paid zero amount vouchers (restricted to candidates; avoids full scan of xref) */
paid_zero_amt_xref AS (
   SELECT /*+ MATERIALIZE */
           px.business_unit,
           px.voucher_id
    FROM ps_pymnt_vchr_xref px
    JOIN vchr_list vc
      ON vc.business_unit = px.business_unit
     AND vc.voucher_id   = px.voucher_id
    WHERE px.pymnt_action <> 'X'
    GROUP BY px.business_unit, px.voucher_id
    HAVING
        SUM(CASE WHEN px.pymnt_selct_status <> 'P' THEN 1 ELSE 0 END) = 0
    AND SUM(CASE WHEN px.paid_amt < 0 THEN 1 ELSE 0 END) > 0
),

/* AT THIS POINT WE EXCLUDE THE PAID VOUCHERS*/

vchr_base AS (
  SELECT pv.*
  FROM vchr_list pv
  WHERE  NOT EXISTS (
      SELECT 1 FROM paid_zero_amt_xref px1
      WHERE px1.business_unit = pv.business_unit
        AND px1.voucher_id    = pv.voucher_id
    )
),
/*calculate the partial paid vocuher amount */
paid_amt_sum AS (
    SELECT
           px.business_unit,
           px.voucher_id,
           abs(SUM(px.paid_amt)) AS total_paid_amt
    FROM ps_pymnt_vchr_xref px
   JOIN vchr_base vc
    ON vc.business_unit = px.business_unit
   AND vc.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND px.paid_amt< 0 and pymnt_selct_status='P'
    GROUP BY px.business_unit, px.voucher_id
),


/*Aggregate the amount on lines and pick the line number of -ve amount*/
net_adj_lines AS (
    SELECT
        vl.business_unit,
        vl.voucher_id,

        /* Pick the negative line (the one to keep in Workday) */
        MAX(CASE 
              WHEN vl.merchandise_amt < 0 
              THEN vl.voucher_line_num 
            END) AS neg_line_num,

        /* Net of all lines */
        SUM(vl.merchandise_amt) AS net_merch_amt1,
/*calculate remaining amount*/
       abs(SUM(vl.merchandise_amt)) - max(nvl(pa.total_paid_amt,0)) AS net_merch_amt
    FROM ps_voucher_line vl
    JOIN vchr_base vb
      ON vb.business_unit = vl.business_unit
     AND vb.voucher_id    = vl.voucher_id
    left join paid_amt_sum pa
    ON vb.business_unit = pa.business_unit
     AND vb.voucher_id    = pa.voucher_id
    WHERE vl.merchandise_amt <> 0
    GROUP BY
        vl.business_unit,
        vl.voucher_id

    HAVING SUM(vl.merchandise_amt) <> 0
),

base AS (
  SELECT
      voucher_id,
      neg_line_num,
      ROW_NUMBER() OVER (
        PARTITION BY voucher_id, neg_line_num
        ORDER BY CASE field_name WHEN 'DEPTID' THEN 1 ELSE 2 END
      ) AS row_num,
      value
  FROM (
      SELECT
          vl.voucher_id,
          vl.neg_line_num ,
         NVL(REPLACE(cc.wd_cost_center, ' ', '_'),'CC_'||d.operating_unit||'-'||d.deptid) AS deptid,

          d.project_id
      FROM vchr_base vb
      JOIN net_adj_lines vl
        ON vl.business_unit = vb.business_unit
       AND vl.voucher_id    = vb.voucher_id
      JOIN ps_distrib_line d
        ON d.business_unit      = vl.business_unit
       AND d.voucher_id         = vl.voucher_id
       AND d.voucher_line_num   = vl.neg_line_num
      LEFT JOIN cc_cocnt cc
  	ON cc.ps_op_unit = d.operating_unit
 	AND cc.ps_deptid  = d.deptid
      where  abs(vl.net_merch_amt)<>0	

  )
  UNPIVOT (
    value FOR field_name IN (
      deptid     AS 'DEPTID',
      project_id AS 'PROJECT_ID'
    )
  )
  WHERE TRIM(value) IS NOT NULL
   /* AND TRIM(value) <> ''
    AND TRIM(value) <> ' '*/
)

SELECT
    b.voucher_id        AS "No.",
     b.voucher_id||'-'||b.neg_line_num  AS "Invoice Line Replacement Data Line No",
    b.row_num           AS "Worktags Line No",
    b.value             AS "Worktags"
FROM base b
ORDER BY b.voucher_id, b.neg_line_num, b.row_num
