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
  SELECT
    TRUNC(SYSDATE)                  AS asof_dt,
    ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

voucher_base AS (
  SELECT /*+ MATERIALIZE */
      v.business_unit,
      v.voucher_id
  FROM ps_voucher v
  JOIN params p
    ON 1=1
  WHERE v.voucher_style = 'ADJ'
    AND v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
),

base AS (
  SELECT
      vl.voucher_id,
      vl.voucher_line_num,
      ROW_NUMBER() OVER (
        PARTITION BY vl.voucher_id, vl.voucher_line_num
        ORDER BY CASE field_name WHEN 'DEPTID' THEN 1 ELSE 2 END
      ) AS row_num,
      value
  FROM (
      SELECT
          vl.voucher_id,
          vl.voucher_line_num,
          d.deptid,
          d.project_id
      FROM voucher_base vb
      JOIN ps_voucher_line vl
        ON vl.business_unit = vb.business_unit
       AND vl.voucher_id    = vb.voucher_id
      JOIN ps_distrib_line d
        ON d.business_unit      = vl.business_unit
       AND d.voucher_id         = vl.voucher_id
       AND d.voucher_line_num   = vl.voucher_line_num
  )
  UNPIVOT (
    value FOR field_name IN (
      deptid     AS 'DEPTID',
      project_id AS 'PROJECT_ID'
    )
  )
  WHERE TRIM(value) IS NOT NULL
    AND TRIM(value) <> ''
    AND TRIM(value) <> ' '
)

SELECT
    b.voucher_id        AS "No.",
    b.voucher_line_num  AS "Invoice Line Replacement Data Line No",
    b.row_num           AS "Worktags Line No",
    b.value             AS "Worktags"
FROM base b
ORDER BY b.voucher_id, b.voucher_line_num, b.row_num;
