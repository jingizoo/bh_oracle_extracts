/* ============================================================================
   Workday EIB – Non‑PO Invoice Line Worktags – 12‑month lookback
   - Only for NON‑PO vouchers within lookback (no PO on header or any line)
   - Exclude adjustments
   ============================================================================ */

WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

nonpo_vouchers AS (
  SELECT /*+ MATERIALIZE */ v.business_unit, v.voucher_id
  FROM ps_voucher v
  JOIN params p ON 1=1
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND v.voucher_style <> 'ADJ'
    AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
    AND NVL(v.po_id,' ') = ' '
    AND NOT EXISTS (
      SELECT 1
      FROM ps_voucher_line vlx
      WHERE vlx.business_unit = v.business_unit
        AND vlx.voucher_id    = v.voucher_id
        AND vlx.po_id IS NOT NULL
        AND vlx.po_id <> ' '
    )
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
  WHERE NVL(vl.po_id,' ') = ' '
),

base AS (
  SELECT
      q.voucher_id,
      q.voucher_line_num,
      ROW_NUMBER() OVER (
          PARTITION BY q.voucher_id, q.voucher_line_num
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
          d.deptid,
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
  )
  UNPIVOT (
      value FOR field_name IN (
          deptid AS 'DEPTID',
          fund_code AS 'FUND',
          project_activity AS 'PROJECT_ACTIVITY'
      )
  )
  WHERE TRIM(value) IS NOT NULL
    AND TRIM(value) <> ''
    AND TRIM(value) <> ' '
)

SELECT
    b.voucher_id       AS "*No.",
    b.voucher_line_num AS "*Invoice Line Replacement Data Line No",
    b.row_num          AS "*Invoice Line Worktags Line No",
    b.value            AS "Worktags"
FROM base b
ORDER BY b.voucher_id, b.voucher_line_num, b.row_num
;
