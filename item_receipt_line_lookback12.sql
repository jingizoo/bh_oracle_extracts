

WITH
params AS (
  SELECT
    TRUNC(SYSDATE)                  AS asof_dt,
    ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

hdr_candidates AS (
  SELECT /*+ MATERIALIZE */ h.business_unit, h.po_id, h.po_dt, h.buyer_id
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
         l.line_nbr,
         s.sched_nbr
  FROM included_po ip
  JOIN ps_po_hdr h
    ON h.business_unit = ip.business_unit
   AND h.po_id         = ip.po_id
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
    AND NVL(h.buyer_id,' ') <> 'BILLONLY'
),

shipto_setid_by_bu AS (
  SELECT r.setcntrlvalue AS business_unit, MAX(r.setid) AS shipto_setid
  FROM ps_set_cntrl_rec r
  WHERE r.recname = 'SHIPTO_TBL'
  GROUP BY r.setcntrlvalue
),
shipto_ed AS (
  SELECT st.setid, st.shipto_id, st.descr
  FROM ps_shipto_tbl st
  WHERE st.eff_status = 'A'
    AND st.effdt = (
      SELECT MAX(st2.effdt)
      FROM ps_shipto_tbl st2
      WHERE st2.setid     = st.setid
        AND st2.shipto_id = st.shipto_id
        AND st2.effdt    <= SYSDATE
    )
),

agg AS (
  SELECT
    rls.business_unit,
    rls.receiver_id,
    rls.recv_ln_nbr,
    rls.recv_ship_seq_nbr,

    rls.business_unit_po,
    rls.po_id,
    rls.line_nbr,
    rls.sched_nbr,

    CASE
      WHEN SUBSTR(TRIM(rls.po_id), 1, 3) = 'PO-' THEN TRIM(rls.po_id)
      WHEN TRANSLATE(TRIM(rls.po_id), '0123456789', '') IS NULL
           THEN 'PO-' || LPAD(TRIM(rls.po_id), 8, '0')
      ELSE 'PO-' || TRIM(rls.po_id)
    END AS po_no,

    MAX(rls.inv_item_id)        AS inv_item_id,
    MAX(rls.qty_sh_recvd)       AS qty_sh_recvd,
    MAX(rls.receive_uom)        AS receive_uom,
    MAX(rls.shipto_id)          AS shipto_id,
    MAX(rls.descr254_mixed)     AS recv_descr,

    MAX(pl.cntrct_id)           AS cntrct_id,
    MAX(pl.cntrct_line_nbr)     AS cntrct_line_nbr,
    MAX(pl.physical_nature)     AS physical_nature,

    MAX(rld.business_unit_gl) KEEP (DENSE_RANK FIRST ORDER BY rld.distrib_line_num) AS business_unit_gl,
    MAX(rld.location)         KEEP (DENSE_RANK FIRST ORDER BY rld.distrib_line_num) AS location,
    MAX(NULLIF(TRIM(rld.delivery_feedback),'')) KEEP (DENSE_RANK FIRST ORDER BY rld.distrib_line_num) AS delivery_feedback

  FROM ps_recv_ln_ship rls
  JOIN ps_recv_ln_distrib rld
    ON rld.business_unit      = rls.business_unit
   AND rld.receiver_id        = rls.receiver_id
   AND rld.recv_ln_nbr        = rls.recv_ln_nbr
   AND rld.recv_ship_seq_nbr  = rls.recv_ship_seq_nbr

  JOIN included_goods_lines gl
    ON gl.business_unit = rls.business_unit_po
   AND gl.po_id         = rls.po_id
   AND gl.line_nbr      = rls.line_nbr
   AND gl.sched_nbr     = rls.sched_nbr

  LEFT JOIN ps_po_line pl
    ON pl.business_unit = rls.business_unit_po
   AND pl.po_id         = rls.po_id
   AND pl.line_nbr      = rls.line_nbr

  JOIN params p
    ON 1=1
  WHERE rls.recv_ship_status <> 'X'
    AND rld.recv_ds_status   <> 'X'
    AND rld.dst_acct_type    = 'DST'
    AND rls.receipt_dttm >= CAST(p.lookback_dt AS TIMESTAMP)
    AND rls.receipt_dttm <  CAST(p.asof_dt + 1 AS TIMESTAMP)

  GROUP BY
    rls.business_unit,
    rls.receiver_id,
    rls.recv_ln_nbr,
    rls.recv_ship_seq_nbr,
    rls.business_unit_po,
    rls.po_id,
    rls.line_nbr,
    rls.sched_nbr
),

numbered AS (
  SELECT
    a.*,
    ROW_NUMBER() OVER (PARTITION BY a.receiver_id ORDER BY a.recv_ln_nbr, a.recv_ship_seq_nbr) AS line_seq
  FROM agg a
)

SELECT
  n.receiver_id                                           AS "*No.",
  n.receiver_id || '-' || n.line_seq                      AS "*Item Receipt Line Replacement Line No",
  n.po_no || '-' || TO_CHAR(n.line_nbr)                   AS "Purchase Order Line",
  CASE
    WHEN TRIM(n.cntrct_id) IS NOT NULL AND TRIM(n.cntrct_id) <> ''
      THEN TRIM(n.cntrct_id) || '-' || TO_CHAR(n.cntrct_line_nbr)
    ELSE ' '
  END                                                     AS "Supplier Contract Line",
  n.business_unit_gl                                       AS "Line Company",
  ' '                                                     AS "Packaging String",
  n.inv_item_id                                            AS "Purchase Item",
  n.qty_sh_recvd                                           AS "Quantity",
  n.receive_uom                                            AS "Unit of Measure",
  'Delivery'                                               AS "Delivery Type",
  CASE
    WHEN st.descr IS NOT NULL THEN n.shipto_id || ' - ' || st.descr
    ELSE n.shipto_id
  END                                                     AS "Ship To Address",
  ' '                                                     AS "Ship To Contact Worker Type",
  ' '                                                     AS "Ship To Contact Worker ID",
  n.location                                               AS "Deliver To",
  ' '                                                     AS "Commodity Code",
  COALESCE(n.delivery_feedback, NULLIF(TRIM(n.recv_descr),''), ' ') AS "Memo",
  n.receiver_id || '-' || TO_CHAR(n.line_seq)              AS "Goods Delivery Line"
FROM numbered n
LEFT JOIN shipto_setid_by_bu sb
  ON sb.business_unit = n.business_unit_po
LEFT JOIN shipto_ed st
  ON st.setid     = sb.shipto_setid
 AND st.shipto_id = n.shipto_id
ORDER BY n.receiver_id, n.line_seq;
