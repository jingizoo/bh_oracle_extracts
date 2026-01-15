WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

/* === Replace this with the missing list from step (1) === */
missing AS (
  SELECT po_id
  FROM (
    /* example placeholder */
    SELECT '0000000000' AS po_id FROM dual
  )
),

/* expand to BU+PO_ID in case PO_ID is not globally unique */
m_hdr AS (
  SELECT h.business_unit, h.po_id, h.vendor_id, h.po_dt, h.po_status
  FROM ps_po_hdr h
  JOIN missing m ON m.po_id = h.po_id
),

/* header candidate criteria */
in_hdr_candidates AS (
  SELECT mh.*
  FROM m_hdr mh
  CROSS JOIN params p
  WHERE mh.po_dt <= p.asof_dt
    AND mh.po_status NOT IN ('C','X')
    AND mh.vendor_id <> '2000017041'
),

/* activity criteria used by your header open_pos */
po_rcv_activity AS (
  SELECT r.business_unit_po AS business_unit,
         r.po_id,
         MAX(r.receipt_dttm) AS last_receipt_dttm
  FROM ps_recv_ln_ship r
  JOIN in_hdr_candidates hc
    ON hc.business_unit = r.business_unit_po
   AND hc.po_id         = r.po_id
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm >= CAST(p.lookback_dt AS TIMESTAMP)
    AND r.receipt_dttm <  CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id
),
po_inv_activity AS (
  SELECT vl.business_unit_po AS business_unit,
         vl.po_id,
         MAX(NVL(v.invoice_dt, v.entered_dt)) AS last_invoice_dt
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN in_hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND vl.po_id IS NOT NULL
    AND NVL(TRIM(vl.po_id),'') <> ''
    AND NVL(v.invoice_dt, v.entered_dt) >= p.lookback_dt
    AND NVL(v.invoice_dt, v.entered_dt) <  (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id
),

/* vouchered used by sched_open */
vchr_sum AS (
  SELECT vl.business_unit_po AS business_unit,
         vl.po_id,
         vl.line_nbr,
         NVL(vl.sched_nbr, 1) AS sched_nbr,
         SUM(NVL(vl.merchandise_amt,0)) AS merch_amt_vchr
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN in_hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND vl.po_id IS NOT NULL
    AND NVL(TRIM(vl.po_id),'') <> ''
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

/* receipts used by sched_open */
recv_agg AS (
  SELECT r.business_unit_po AS business_unit,
         r.po_id,
         r.line_nbr,
         r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd_suom, 0)) AS qty_rcvd_suom
  FROM ps_recv_ln_ship r
  JOIN in_hdr_candidates hc
    ON hc.business_unit = r.business_unit_po
   AND hc.po_id         = r.po_id
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),

/* === IMPORTANT: this is your CURRENT header sched_open logic (liquidate_method) === */
sched_open_hdr AS (
  SELECT s.business_unit, s.po_id,
         CASE
           WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
           WHEN s.liquidate_method = 'A'
             THEN CASE WHEN NVL(s.merchandise_amt,0) > NVL(vs.merch_amt_vchr,0) THEN 1 ELSE 0 END
           ELSE
             CASE WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0) THEN 1 ELSE 0 END
         END AS is_open
  FROM ps_po_line_ship s
  JOIN in_hdr_candidates hc
    ON hc.business_unit = s.business_unit
   AND hc.po_id         = s.po_id
  LEFT JOIN recv_agg r
    ON r.business_unit = s.business_unit
   AND r.po_id         = s.po_id
   AND r.line_nbr      = s.line_nbr
   AND r.sched_nbr     = s.sched_nbr
  LEFT JOIN vchr_sum vs
    ON vs.business_unit = s.business_unit
   AND vs.po_id         = s.po_id
   AND vs.line_nbr      = s.line_nbr
   AND vs.sched_nbr     = s.sched_nbr
),

open_pos_hdr AS (
  SELECT hc.business_unit, hc.po_id
  FROM in_hdr_candidates hc
  CROSS JOIN params p
  LEFT JOIN po_rcv_activity pra
    ON pra.business_unit = hc.business_unit AND pra.po_id = hc.po_id
  LEFT JOIN po_inv_activity pia
    ON pia.business_unit = hc.business_unit AND pia.po_id = hc.po_id
  WHERE EXISTS (
    SELECT 1 FROM sched_open_hdr so
    WHERE so.business_unit = hc.business_unit
      AND so.po_id         = hc.po_id
      AND so.is_open       = 1
  )
  AND (
       hc.po_dt >= p.lookback_dt
    OR pra.last_receipt_dttm IS NOT NULL
    OR pia.last_invoice_dt   IS NOT NULL
  )
),

/* header final INNER joins that can drop rows */
hdr_final_key AS (
  SELECT DISTINCT op.business_unit, op.po_id
  FROM open_pos_hdr op
  JOIN ps_po_hdr h
    ON h.business_unit = op.business_unit
   AND h.po_id         = op.po_id
  JOIN ps_bus_unit_tbl_pm bu
    ON bu.business_unit = h.business_unit
  JOIN ps_bh_wd_sup_1to1 wd
    ON wd.bh_wd_ps_vendor_id = h.vendor_id
)

SELECT reason, COUNT(*) cnt
FROM (
  SELECT mh.business_unit, mh.po_id,
         CASE
           WHEN NOT EXISTS (
             SELECT 1 FROM in_hdr_candidates hc
             WHERE hc.business_unit = mh.business_unit AND hc.po_id = mh.po_id
           ) THEN 'FAIL_HDR_CANDIDATES (status/date/vendor)'

           WHEN NOT EXISTS (
             SELECT 1 FROM open_pos_hdr op
             WHERE op.business_unit = mh.business_unit AND op.po_id = mh.po_id
           ) THEN 'FAIL_OPEN_POS (open sched or lookback activity)'

           WHEN NOT EXISTS (
             SELECT 1 FROM ps_bus_unit_tbl_pm bu
             WHERE bu.business_unit = mh.business_unit
           ) THEN 'MISSING_PS_BUS_UNIT_TBL_PM'

           WHEN NOT EXISTS (
             SELECT 1 FROM ps_bh_wd_sup_1to1 wd
             WHERE wd.bh_wd_ps_vendor_id = mh.vendor_id
           ) THEN 'MISSING_SUPPLIER_XWALK (ps_bh_wd_sup_1to1)'

           WHEN NOT EXISTS (
             SELECT 1 FROM hdr_final_key hk
             WHERE hk.business_unit = mh.business_unit AND hk.po_id = mh.po_id
           ) THEN 'DROPPED_BY_FINAL_JOIN (unexpected)'

           ELSE 'UNKNOWN'
         END AS reason
  FROM m_hdr mh
)
GROUP BY reason
ORDER BY cnt DESC, reason;
