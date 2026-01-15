/* ============================================================================
   Workday EIB – PO Invoice Line Worktags – 12‑month lookback + Open PO scope
   - Only for PO invoice lines tied to INCLUDED open GOODS PO lines
   - Keys match existing worktags file: (*No.=VOUCHER_ID, *Invoice Line Replacement Data Line No=VOUCHER_LINE_NUM)
   ============================================================================ */

WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),
hdr_candidates AS (
  SELECT /*+ MATERIALIZE */ h.business_unit, h.po_id, h.po_dt
  FROM ps_po_hdr h
  JOIN params p ON 1=1
  WHERE h.po_dt <= p.asof_dt
    AND h.po_status NOT IN ('C','X')
),
recv_agg AS (
  SELECT r.business_unit_po AS business_unit,
         r.po_id, r.line_nbr, r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd_suom,0))  AS qty_rcvd_suom,
         SUM(NVL(r.merchandise_amt_po,0)) AS merch_amt_rcvd_po
  FROM ps_recv_ln_ship r
  JOIN hdr_candidates hc
    ON hc.business_unit = r.business_unit_po
   AND hc.po_id         = r.po_id
  JOIN params p
    ON 1=1
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),
sched_open AS (
  SELECT s.business_unit, s.po_id, s.line_nbr, s.sched_nbr,
         CASE
           WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
           WHEN s.liquidate_method = 'A' THEN
                CASE WHEN NVL(s.merchandise_amt,0) > NVL(r.merch_amt_rcvd_po,0) THEN 1 ELSE 0 END
           ELSE
                CASE WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0) THEN 1 ELSE 0 END
         END AS is_open
  FROM ps_po_line_ship s
  JOIN hdr_candidates hc
    ON hc.business_unit = s.business_unit
   AND hc.po_id         = s.po_id
  LEFT JOIN recv_agg r
    ON r.business_unit = s.business_unit
   AND r.po_id         = s.po_id
   AND r.line_nbr      = s.line_nbr
   AND r.sched_nbr     = s.sched_nbr
),
open_pos AS (
  SELECT DISTINCT hc.business_unit, hc.po_id, hc.po_dt
  FROM hdr_candidates hc
  WHERE EXISTS (
    SELECT 1 FROM sched_open so
    WHERE so.business_unit = hc.business_unit
      AND so.po_id         = hc.po_id
      AND so.is_open       = 1
  )
),
receipt_activity AS (
  SELECT DISTINCT r.business_unit_po AS business_unit, r.po_id
  FROM ps_recv_ln_ship r
  JOIN params p ON 1=1
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm >= CAST(p.lookback_dt AS TIMESTAMP)
    AND r.receipt_dttm <  CAST(p.asof_dt + 1 AS TIMESTAMP)
),
invoice_activity AS (
  SELECT DISTINCT vl.business_unit_po AS business_unit, vl.po_id
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN params p ON 1=1
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND v.voucher_style <> 'ADJ'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
),
included_po AS (
  SELECT op.business_unit, op.po_id
  FROM open_pos op
  JOIN params p ON 1=1
  WHERE op.po_dt >= p.lookback_dt
     OR EXISTS (SELECT 1 FROM receipt_activity ra WHERE ra.business_unit = op.business_unit AND ra.po_id = op.po_id)
     OR EXISTS (SELECT 1 FROM invoice_activity ia WHERE ia.business_unit = op.business_unit AND ia.po_id = op.po_id)
),
included_goods_lines AS (
  SELECT /*+ MATERIALIZE */ DISTINCT
         l.business_unit, l.po_id, l.line_nbr, s.sched_nbr
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
  WHERE l.cancel_status <> 'X'
    AND s.cancel_status <> 'X'
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
