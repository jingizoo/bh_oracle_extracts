/* ============================================================
   HEADER vs GOODS vs SERVICE - missing analysis (header-only POs)
   Paste your FINAL SELECTs (NO ORDER BY) into hdr_out/goods_out/service_out
   Requires only:
     Header: "*No."
     Goods/Service: "*No.", "Line Number"
   ============================================================ */

WITH
hdr_out AS (
  /* PASTE FINAL HEADER SELECT HERE (NO ORDER BY) */
  SELECT 1 AS dummy FROM dual
),
goods_out AS (
  /* PASTE FINAL GOODS SELECT HERE (NO ORDER BY) */
  SELECT 1 AS dummy FROM dual
),
service_out AS (
  /* PASTE FINAL SERVICE SELECT HERE (NO ORDER BY) */
  SELECT 1 AS dummy FROM dual
),

/* ---- PO sets ---- */
hdr_pos AS (
  SELECT DISTINCT h."*No." AS po_id
  FROM hdr_out h
),
line_pos AS (
  SELECT DISTINCT g."*No." AS po_id FROM goods_out g
  UNION
  SELECT DISTINCT s."*No." AS po_id FROM service_out s
),
hdr_only AS (
  SELECT po_id FROM hdr_pos
  MINUS
  SELECT po_id FROM line_pos
),
line_only AS (
  SELECT po_id FROM line_pos
  MINUS
  SELECT po_id FROM hdr_pos
),

/* ---- Map header-only PO_ID -> BU (detect multi-BU reuse) ---- */
po_bu_map AS (
  SELECT h.po_id,
         MIN(h.business_unit) AS business_unit,
         COUNT(DISTINCT h.business_unit) AS bu_cnt
    FROM ps_po_hdr h
   WHERE h.po_id IN (SELECT po_id FROM hdr_only)
   GROUP BY h.po_id
),
po_bu_one AS (
  SELECT * FROM po_bu_map WHERE bu_cnt = 1
),

/* ---- Basic existence counts driving line extracts ---- */
po_line_cnt AS (
  SELECT l.business_unit, l.po_id, COUNT(*) AS po_line_cnt
    FROM ps_po_line l
    JOIN po_bu_one m
      ON m.business_unit = l.business_unit
     AND m.po_id         = l.po_id
   WHERE NVL(l.cancel_status,' ') <> 'X'
   GROUP BY l.business_unit, l.po_id
),
ship_cnt AS (
  SELECT s.business_unit, s.po_id,
         COUNT(*) AS sched_cnt,
         SUM(CASE WHEN s.sched_nbr = 1 THEN 1 ELSE 0 END) AS sched1_cnt
    FROM ps_po_line_ship s
    JOIN po_bu_one m
      ON m.business_unit = s.business_unit
     AND m.po_id         = s.po_id
   WHERE NVL(s.cancel_status,' ') <> 'X'
   GROUP BY s.business_unit, s.po_id
),
distrib_cnt AS (
  SELECT d.business_unit, d.po_id,
         COUNT(*) AS distrib_cnt,
         SUM(CASE WHEN d.sched_nbr = 1 THEN 1 ELSE 0 END) AS distrib_sched1_cnt,
         SUM(CASE WHEN d.sched_nbr = 1 AND d.dst_acct_type = 'DST' AND d.distrib_line_num = 1 THEN 1 ELSE 0 END) AS dst1_sched1_cnt
    FROM ps_po_line_distrib d
    JOIN po_bu_one m
      ON m.business_unit = d.business_unit
     AND m.po_id         = d.po_id
   GROUP BY d.business_unit, d.po_id
),

/* ---- Recompute "open schedule" at PO_LINE_SHIP grain (aligned rule) ---- */
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt FROM dual
),
recv_agg AS (
  SELECT r.business_unit_po AS business_unit,
         r.po_id, r.line_nbr, r.sched_nbr,
         SUM(NVL(r.qty_sh_recvd_suom,0)) AS qty_rcvd_suom
    FROM ps_recv_ln_ship r
    JOIN po_bu_one m
      ON m.business_unit = r.business_unit_po
     AND m.po_id         = r.po_id
    CROSS JOIN params p
   WHERE r.recv_ship_status <> 'X'
     AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
   GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),
vchr_sum AS (
  SELECT vl.business_unit_po AS business_unit,
         vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1) AS sched_nbr,
         SUM(NVL(vl.merchandise_amt,0)) AS merch_amt_vchr
    FROM ps_voucher_line vl
    JOIN ps_voucher v
      ON v.business_unit = vl.business_unit
     AND v.voucher_id    = vl.voucher_id
    JOIN po_bu_one m
      ON m.business_unit = vl.business_unit_po
     AND m.po_id         = vl.po_id
    CROSS JOIN params p
   WHERE v.entry_status <> 'X'
     AND vl.po_id IS NOT NULL
     AND NVL(TRIM(vl.po_id),'') <> ''
     AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
   GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1)
),
line_flags AS (
  SELECT l.business_unit, l.po_id, l.line_nbr,
         NVL(l.recv_req,'Y')     AS recv_req,
         NVL(l.amt_only_flg,'N') AS amt_only_flg
    FROM ps_po_line l
    JOIN po_bu_one m
      ON m.business_unit = l.business_unit
     AND m.po_id         = l.po_id
),
sched_calc AS (
  SELECT s.business_unit, s.po_id, s.line_nbr, s.sched_nbr,
         NVL(lf.recv_req,'Y')     AS recv_req,
         NVL(lf.amt_only_flg,'N') AS amt_only_flg,
         NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) AS sched_amt,
         NVL(vs.merch_amt_vchr,0) AS merch_amt_vchr,
         NVL(s.qty_po,0)          AS qty_po,
         NVL(r.qty_rcvd_suom,0)   AS qty_rcvd_suom,
         CASE
           WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
           WHEN NVL(lf.amt_only_flg,'N') = 'Y'
             THEN CASE WHEN NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) > NVL(vs.merch_amt_vchr,0) THEN 1 ELSE 0 END
           WHEN NVL(lf.recv_req,'Y') = 'Y'
             THEN CASE WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0) THEN 1 ELSE 0 END
           ELSE
             CASE WHEN NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) > NVL(vs.merch_amt_vchr,0) THEN 1 ELSE 0 END
         END AS is_open
    FROM ps_po_line_ship s
    JOIN po_bu_one m
      ON m.business_unit = s.business_unit
     AND m.po_id         = s.po_id
    LEFT JOIN line_flags lf
      ON lf.business_unit = s.business_unit
     AND lf.po_id         = s.po_id
     AND lf.line_nbr      = s.line_nbr
    LEFT JOIN recv_agg r
      ON r.business_unit  = s.business_unit
     AND r.po_id          = s.po_id
     AND r.line_nbr       = s.line_nbr
     AND r.sched_nbr      = s.sched_nbr
    LEFT JOIN vchr_sum vs
      ON vs.business_unit = s.business_unit
     AND vs.po_id         = s.po_id
     AND vs.line_nbr      = s.line_nbr
     AND vs.sched_nbr     = s.sched_nbr
),
open_sched_cnt AS (
  SELECT business_unit, po_id,
         SUM(CASE WHEN is_open = 1 THEN 1 ELSE 0 END) AS open_sched_cnt,
         SUM(CASE WHEN is_open = 1 AND sched_nbr = 1 THEN 1 ELSE 0 END) AS open_sched1_cnt
    FROM sched_calc
   GROUP BY business_unit, po_id
),

/* ---- Header-only PO diagnostics + reason bucket ---- */
hdr_only_detail AS (
  SELECT ho.po_id,
         pb.business_unit,
         pb.bu_cnt,
         NVL(pl.po_line_cnt,0) AS po_line_cnt,
         NVL(sc.sched_cnt,0)   AS sched_cnt,
         NVL(sc.sched1_cnt,0)  AS sched1_cnt,
         NVL(dc.distrib_cnt,0) AS distrib_cnt,
         NVL(dc.dst1_sched1_cnt,0) AS dst1_sched1_cnt,
         NVL(os.open_sched_cnt,0)  AS open_sched_cnt,
         NVL(os.open_sched1_cnt,0) AS open_sched1_cnt,
         CASE
           WHEN pb.po_id IS NULL THEN 'PO_NOT_FOUND_IN_PS_PO_HDR'
           WHEN pb.bu_cnt > 1 THEN 'PO_ID_IN_MULTI_BU (include BU in extracts)'
           WHEN NVL(pl.po_line_cnt,0) = 0 THEN 'NO_PS_PO_LINE_ROWS'
           WHEN NVL(sc.sched_cnt,0) = 0 THEN 'NO_PO_LINE_SHIP_ROWS'
           WHEN NVL(os.open_sched_cnt,0) = 0 THEN 'NOT_OPEN_BY_ALIGNED_RULE (header open_pos mismatch)'
           WHEN NVL(sc.sched1_cnt,0) = 0 THEN 'NO_SCHED_NBR_1 (line extracts hardcode sched_nbr=1)'
           WHEN NVL(os.open_sched1_cnt,0) = 0 THEN 'OPEN_ONLY_ON_NON_SCHED1 (remove sched_nbr=1 filter)'
           WHEN NVL(dc.distrib_cnt,0) = 0 THEN 'NO_PO_LINE_DISTRIB_ROWS (service_flags/extract joins drop)'
           WHEN NVL(dc.dst1_sched1_cnt,0) = 0 THEN 'NO_DST_DIST_LINE1_FOR_SCHED1 (extract joins drop)'
           ELSE 'OTHER_LINE_FILTER (service/goods split, remaining_amt>0, etc.)'
         END AS reason
    FROM hdr_only ho
    LEFT JOIN po_bu_map pb
      ON pb.po_id = ho.po_id
    LEFT JOIN po_bu_one p1
      ON p1.po_id = ho.po_id
    LEFT JOIN po_line_cnt pl
      ON pl.business_unit = p1.business_unit AND pl.po_id = p1.po_id
    LEFT JOIN ship_cnt sc
      ON sc.business_unit = p1.business_unit AND sc.po_id = p1.po_id
    LEFT JOIN distrib_cnt dc
      ON dc.business_unit = p1.business_unit AND dc.po_id = p1.po_id
    LEFT JOIN open_sched_cnt os
      ON os.business_unit = p1.business_unit AND os.po_id = p1.po_id
),

reason_samples AS (
  SELECT reason,
         COUNT(*) AS cnt,
         LISTAGG(po_id, ', ') WITHIN GROUP (ORDER BY po_id) AS sample_pos
  FROM (
    SELECT reason, po_id,
           ROW_NUMBER() OVER (PARTITION BY reason ORDER BY po_id) AS rn
    FROM hdr_only_detail
  )
  WHERE rn <= 10
  GROUP BY reason
)

SELECT section, metric, val, sample_pos
FROM (
  SELECT 'SUMMARY' AS section, 'HDR_DISTINCT_PO' AS metric, COUNT(*) AS val, NULL AS sample_pos FROM hdr_pos
  UNION ALL SELECT 'SUMMARY', 'LINES_DISTINCT_PO(goods+service)', COUNT(*), NULL FROM line_pos
  UNION ALL SELECT 'SUMMARY', 'HDR_ONLY_PO (header not in lines)', COUNT(*), NULL FROM hdr_only
  UNION ALL SELECT 'SUMMARY', 'LINE_ONLY_PO (lines not in header)', COUNT(*), NULL FROM line_only

  UNION ALL
  SELECT 'HDR_ONLY_REASON' AS section, reason AS metric, cnt AS val, sample_pos
  FROM reason_samples
)
ORDER BY section, val DESC, metric;
