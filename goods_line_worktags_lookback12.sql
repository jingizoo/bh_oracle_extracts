
WITH
params AS (
  SELECT
    TRUNC(SYSDATE)                  AS asof_dt,
    ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),
hdr_candidates AS (
  SELECT /*+ MATERIALIZE */ h.business_unit, h.po_id, h.po_dt
  FROM ps_po_hdr h
  CROSS JOIN params p
  WHERE h.po_dt <= p.asof_dt
    AND h.po_status NOT IN ('C','X')
),
recv_agg_all AS (
  SELECT r.business_unit_po AS business_unit, r.po_id, r.line_nbr, r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd_suom,0))  AS qty_rcvd_suom,
         SUM(NVL(r.merchandise_amt_po,0)) AS merch_amt_rcvd_po
  FROM ps_recv_ln_ship r
  JOIN hdr_candidates hc
    ON hc.business_unit = r.business_unit_po
   AND hc.po_id         = r.po_id
  CROSS JOIN params p
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
  LEFT JOIN recv_agg_all r
    ON r.business_unit  = s.business_unit
   AND r.po_id          = s.po_id
   AND r.line_nbr       = s.line_nbr
   AND r.sched_nbr      = s.sched_nbr
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
  CROSS JOIN params p
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
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
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
  SELECT DISTINCT
         l.business_unit,
         l.po_id,
         l.line_nbr
  FROM included_po ip
  JOIN ps_po_line l
    ON l.business_unit = ip.business_unit
   AND l.po_id         = ip.po_id
   AND l.physical_nature = 'G'
  JOIN ps_po_line_ship s
    ON s.business_unit = l.business_unit
   AND s.po_id         = l.po_id
   AND s.line_nbr      = l.line_nbr
   AND s.sched_nbr     = 1
  JOIN sched_open so
    ON so.business_unit = s.business_unit
   AND so.po_id         = s.po_id
   AND so.line_nbr      = s.line_nbr
   AND so.sched_nbr     = s.sched_nbr
   AND so.is_open       = 1
  WHERE l.cancel_status <> 'X'
    AND s.cancel_status <> 'X'
),
unpivoted AS (
  SELECT
    d.po_id,
    d.line_nbr,
    ROW_NUMBER() OVER (
      PARTITION BY d.po_id, d.line_nbr
      ORDER BY CASE field_name WHEN 'DEPTID' THEN 1 WHEN 'PROJECT_ID' THEN 2 END
    ) AS row_num,
    value
  FROM (
    SELECT
      d.po_id,
      d.line_nbr,
      d.deptid,
      d.project_id
    FROM ps_po_line_distrib d
    JOIN included_goods_lines gl
      ON gl.business_unit = d.business_unit
     AND gl.po_id         = d.po_id
     AND gl.line_nbr      = d.line_nbr
    WHERE d.dst_acct_type    = 'DST'
      AND d.distrib_line_num = 1
      AND d.distrib_ln_status <> 'X'
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
ORDER BY u.po_id, u.line_nbr, u.row_num;
