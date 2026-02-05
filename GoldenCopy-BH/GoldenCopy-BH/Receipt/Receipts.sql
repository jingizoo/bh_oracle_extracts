

/* Receipt Header extract for Workday:
   - Uses the same open‑PO logic as the item receipt line query to identify qualifying receipts
   - Aggregates receipt ship and distribution data up to the receiver header level
   - Outputs one row per open receipt header in the Workday “Receipts” layout */

WITH params AS (
  SELECT TRUNC(to_date('15-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),

/* ------------------------------
   Header candidates
   ------------------------------ */
hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status,
         h.vendor_id,
         h.buyer_id,
         h.currency_cd,
         h.poa_status,
         h.oprid_entered_by
  FROM ps_po_hdr h
  CROSS JOIN params p
  WHERE h.po_dt <= p.asof_dt
    AND h.po_status NOT IN ('C','X')
    AND h.vendor_id <> '2000017041' --and h.po_id='0002563676'
),

/* ------------------------------
   Receipts to date
   ------------------------------ */


paid_vouchers AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  WHERE px.pymnt_action <> 'X'
    AND px.paid_amt > 0
),

vchr_sum_match AS (
  SELECT
      vl.business_unit_po AS business_unit,
      vl.po_id,
      vl.line_nbr,
      NVL(vl.sched_nbr, 1) AS sched_nbr,
      SUM(NVL(vl.merchandise_amt,0)) AS merch_amt_vchr,
      SUM(NVL(vl.qty_vchr,0))        AS qty_vchr
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
   
   CROSS JOIN PARAMS P
  JOIN paid_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
  WHERE v.entry_status <> 'X'
    AND v.match_status_vchr = 'M'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
    
  
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),
/* ------------------------------
   Definitive flags from PS_PO_LINE
   ------------------------------ */
po_line_flags AS (
  SELECT /*+ LEADING(hc l) USE_NL(l) INDEX(l) */
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

/* Service PO filter (PO-level) */
service_flags AS (
  SELECT /*+ LEADING(hc d) USE_NL(d) INDEX(d) */ d.business_unit,
         d.po_id,
         CASE WHEN MAX(x.BH_XWLK_t1) IS NOT NULL THEN 'Y' ELSE 'N' END AS has_service
    FROM hdr_candidates hc
    JOIN ps_po_line_distrib d
      ON d.business_unit = hc.business_unit
     AND d.po_id         = hc.po_id
    LEFT JOIN PS_BH_XWLK_VAL_TBL x
      ON x.LONGNAME        = 'WD_ACCT_TO_PO_TYPE'
     AND x.bh_xwlk_module  = 'PO'
     AND x.bh_xwlk_track   = 'SCM'
     AND x.BH_XWLK_S2      = d.account
   GROUP BY d.business_unit, d.po_id
),
/* ------------------------------
   Open schedule logic (ALIGNED):
   - AMT_ONLY_FLG='Y' => sched_amt > vouchered
   - else if RECV_REQ='Y' => qty_po > qty_received
   - else => sched_amt > vouchered
   ------------------------------ */
sched_open AS (
  SELECT
      x.business_unit,
      x.po_id,
      x.line_nbr,
      x.sched_nbr,
      x.cancel_status,
      x.due_dt,
      x.shipto_setid,
      x.shipto_id,
      x.freight_terms,
      x.ship_type_id,
      x.qty_po,x.price_po,
      x.merchandise_amt,
      x.liquidate_method,
      x.recv_req,
      x.amt_only_flg,
     -- x.qty_rcvd_suom,
   --   x.merch_amt_rcvd_po,
      x.merch_amt_vchr,
      x.sched_amt,
      x.qty_vchr,
      CASE
  WHEN NVL(x.cancel_status,' ') IN ('C','X') THEN 0

  WHEN x.amt_only_flg = 'Y' THEN
    CASE
      WHEN GREATEST(NVL(x.sched_amt,0) - NVL(x.merch_amt_vchr,0), 0) > 1 and (sched_amt)>0
      THEN 1 ELSE 0
    END

  WHEN x.recv_req = 'Y' THEN
    CASE
     -- WHEN NVL(x.qty_po,0) > NVL(x.qty_rcvd_suom,0)
        WHEN NVL(x.qty_po,0) > NVL(x.qty_vchr,0)
 THEN 1 ELSE 0
    END

  ELSE
    CASE
      WHEN GREATEST(NVL(x.sched_amt,0) - NVL(x.merch_amt_vchr,0), 0) > 1
      THEN 1 ELSE 0
    END
END AS is_open
  FROM (
    SELECT /*+ LEADING(hc s) USE_NL(s) INDEX(s) */
        s.business_unit,
        s.po_id,
        s.line_nbr,
        s.sched_nbr,
        s.cancel_status,
        s.due_dt,
        s.shipto_setid,
        s.shipto_id,
        s.freight_terms,
        s.ship_type_id,
        s.qty_po,
        s.price_po,
        s.merchandise_amt,
        s.liquidate_method,
        lf.recv_req,
        lf.amt_only_flg,
      --  NVL(r.qty_rcvd_suom, 0)     AS qty_rcvd_suom,
        --NVL(r.merch_amt_rcvd_po, 0) AS merch_amt_rcvd_po,
        NVL(vs.merch_amt_vchr, 0)   AS merch_amt_vchr,
        NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) AS sched_amt,
           NVL (vs.qty_vchr,0) as qty_vchr
    FROM ps_po_line_ship s
    JOIN hdr_candidates hc
      ON hc.business_unit = s.business_unit
     AND hc.po_id         = s.po_id
    JOIN po_line_flags lf
      ON lf.business_unit = s.business_unit
     AND lf.po_id         = s.po_id
     AND lf.line_nbr      = s.line_nbr
  /*  LEFT JOIN recv_agg r
      ON r.business_unit  = s.business_unit
     AND r.po_id          = s.po_id
     AND r.line_nbr       = s.line_nbr
     AND r.sched_nbr      = s.sched_nbr*/
    LEFT JOIN vchr_sum_match vs
      ON vs.business_unit = s.business_unit
     AND vs.po_id         = s.po_id
     AND vs.line_nbr      = s.line_nbr
     AND vs.sched_nbr     = s.sched_nbr
  ) x
),

po_has_pos_amt_and_qty AS (
  SELECT
      so.business_unit,
      so.po_id
  FROM sched_open so
  join SERVICE_FLAGS pt on  so.business_unit=pt.business_unit and
      so.po_id=pt.po_id
 WHERE so.is_open = 1
    /* Amount gate must match line extract logic (extended_amt / remaining_amt) */
    AND (
      CASE
        /* Service POs are always amount-based */
        WHEN pt.has_service = 'Y'
          THEN GREATEST(NVL(so.sched_amt, 0) - NVL(so.merch_amt_vchr, 0), 0)
        /* Goods amt-only lines are amount-based */
        WHEN NVL(so.amt_only_flg, 'N') = 'Y'
          THEN GREATEST(NVL(so.sched_amt, 0) - NVL(so.merch_amt_vchr, 0), 0)
        /* Goods receiving-required lines are receipt-qty based */
        WHEN NVL(so.recv_req, 'Y') = 'Y'
          THEN GREATEST(NVL(so.qty_po, 0) - NVL(so.qty_vchr, 0), 0) * NVL(so.price_po, 0)
        /* Goods non-receiving lines are voucher-qty based */
        ELSE
          GREATEST(NVL(so.qty_po, 0) - NVL(so.qty_vchr, 0), 0) * NVL(so.price_po, 0)
      END
    ) > 0
    AND (
          pt.has_service = 'Y'
          OR (
               pt.has_service = 'N'
               AND (
                    /* Mirror goods-line logic: qty gate depends on recv_req / amt_only */
                    NVL(so.amt_only_flg, 'N') = 'Y'
                    OR (
                         NVL(so.recv_req, 'Y') = 'Y'
                         AND GREATEST(NVL(so.qty_po, 0) - NVL(so.qty_vchr, 0), 0) > 0
                       )
                    OR (
                         NVL(so.recv_req, 'Y') <> 'Y'
                         AND GREATEST(NVL(so.qty_po, 0) - NVL(so.qty_vchr, 0), 0) > 0
                        )
                  )
             )
        )
  GROUP BY so.business_unit, so.po_id
) ,


/* Precompute POs that have at least one OPEN schedule + active line + active distrib */
open_po_eligible AS (
  SELECT /*+ MATERIALIZE LEADING(so) USE_NL(l) INDEX(l) USE_NL(d) INDEX(d) */
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

/* ------------------------------
   Lookback activity
   ------------------------------ */
po_rcv_activity AS (
  SELECT
      r.business_unit_po AS business_unit,
      r.po_id,
      MAX(r.receipt_dttm) AS last_receipt_dttm
  FROM ps_recv_ln_ship r
  JOIN hdr_candidates hc
    ON hc.business_unit = r.business_unit_po
   AND hc.po_id         = r.po_id
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm >= CAST(p.lookback_dt AS TIMESTAMP)
    AND r.receipt_dttm <  CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id
),

po_inv_activity AS (
  SELECT
      vl.business_unit_po AS business_unit,
      vl.po_id,
      MAX(NVL(v.invoice_dt, v.entered_dt)) AS last_invoice_dt
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
  CROSS JOIN params p
  WHERE vl.business_unit_po IS NOT NULL
    AND vl.po_id IS NOT NULL
   -- AND NVL(TRIM(vl.po_id),'') <> ''
    AND v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND NVL(v.invoice_dt, v.entered_dt) >= p.lookback_dt
    AND NVL(v.invoice_dt, v.entered_dt) <  (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id
),

/* ------------------------------
   Open POs in scope
   ------------------------------ */
open_pos AS (
  SELECT /*+ MATERIALIZE */
         hc.business_unit,
         hc.po_id
  FROM hdr_candidates hc
  CROSS JOIN params p
 /* LEFT JOIN po_rcv_activity pra
    ON pra.business_unit = hc.business_unit
   AND pra.po_id         = hc.po_id
  LEFT JOIN po_inv_activity pia
    ON pia.business_unit = hc.business_unit
   AND pia.po_id         = hc.po_id*/
  WHERE EXISTS (
    SELECT 1
      FROM open_po_eligible ope
     WHERE ope.business_unit = hc.business_unit
       AND ope.po_id         = hc.po_id
  )
  AND (
       hc.po_dt >= p.lookback_dt
  AND NVL(hc.buyer_id,' ') <> 'BILLONLY'  )
  
  and exists(
  select 1 from po_has_pos_amt_and_qty p
   WHERE p.business_unit = hc.business_unit
       AND p.po_id         = hc.po_id
)
AND EXISTS (SELECT 1 FROM ps_bh_wd_sup_1to1 wd WHERE wd.bh_wd_ps_vendor_id = hc.vendor_id)
    AND EXISTS (SELECT 1 FROM ps_bus_unit_tbl_pm bu WHERE bu.business_unit = hc.business_unit)
    
),
/* 1) DIRECT ship-level paid qty where voucher has receipt keys */
vchr_sum_match_ship_direct AS (
  SELECT
      vl.business_unit_po AS business_unit,
      vl.po_id,
      vl.line_nbr,
      NVL(vl.sched_nbr, 1) AS sched_nbr,
      vl.receiver_id,
      vl.recv_ln_nbr,
      vl.recv_ship_seq_nbr,
      SUM(NVL(vl.qty_vchr,0)) AS qty_vchr_direct
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN paid_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.match_status_vchr = 'M'
    AND vl.po_id IS NOT NULL
    AND TRIM(vl.po_id) <> ''
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
    /* treat as DIRECT only if receipt keys exist */
    AND vl.receiver_id IS NOT NULL
    AND vl.recv_ln_nbr IS NOT NULL
    AND vl.recv_ship_seq_nbr IS NOT NULL
  GROUP BY
      vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1),
      vl.receiver_id, vl.recv_ln_nbr, vl.recv_ship_seq_nbr
),

/* DIRECT qty rolled up to schedule grain */
direct_sched_sum AS (
  SELECT
    business_unit, po_id, line_nbr, sched_nbr,
    SUM(qty_vchr_direct) AS qty_vchr_direct_sched
  FROM vchr_sum_match_ship_direct
  GROUP BY business_unit, po_id, line_nbr, sched_nbr
),

/* 2) Receipt ship lines in scope (same driver as your final receipt file) */
rcv_ship_for_alloc AS (
  SELECT
    rls.business_unit_po AS business_unit,
    rls.po_id,
    rls.line_nbr,
    rls.sched_nbr,

    rls.business_unit AS rcv_business_unit,
    rls.receiver_id,
    rls.recv_ln_nbr,
    rls.recv_ship_seq_nbr,
    rls.receipt_dttm,
    NVL(rls.qty_sh_recvd,0) AS qty_sh_recvd
  FROM ps_recv_ln_ship rls
  JOIN params p
    ON 1=1
  JOIN open_pos op
    ON op.business_unit = rls.business_unit_po
   AND op.po_id         = rls.po_id
  WHERE rls.recv_ship_status <> 'X'
    AND TRUNC(CAST(rls.receipt_dttm AS DATE))
        BETWEEN p.lookback_dt AND p.asof_dt
),

/* 3) Rank receipts + compute remaining paid qty to allocate per schedule */
rcv_ship_ranked AS (
  SELECT
    r.*,

    /* direct paid qty on this receipt ship-line (if any) */
    NVL(d.qty_vchr_direct,0) AS qty_vchr_direct,

    /* receipt qty still available after applying direct */
    GREATEST(r.qty_sh_recvd - NVL(d.qty_vchr_direct,0), 0) AS qty_rcvd_unmapped,

    /* total PAID+MATCHED qty at schedule level (your existing vchr_sum_match) */
    NVL(vs.qty_vchr,0) AS qty_paid_sched,

    /* schedule qty already accounted for via DIRECT receipt-linked voucher lines */
    NVL(ds.qty_vchr_direct_sched,0) AS qty_paid_direct_sched,

    /* remaining paid qty that has NO receipt linkage -> allocate across receipts */
    GREATEST(NVL(vs.qty_vchr,0) - NVL(ds.qty_vchr_direct_sched,0), 0) AS qty_paid_to_allocate,

    /* cumulative available (unmapped) receipt qty for FIFO allocation */
    SUM(GREATEST(r.qty_sh_recvd - NVL(d.qty_vchr_direct,0), 0)) OVER (
      PARTITION BY r.business_unit, r.po_id, r.line_nbr, r.sched_nbr
      ORDER BY r.receipt_dttm, r.receiver_id, r.recv_ln_nbr, r.recv_ship_seq_nbr
    ) AS cum_rcvd_unmapped
  FROM rcv_ship_for_alloc r
  LEFT JOIN vchr_sum_match_ship_direct d
    ON d.business_unit       = r.business_unit
   AND d.po_id               = r.po_id
   AND d.line_nbr            = r.line_nbr
   AND d.sched_nbr           = r.sched_nbr
   AND d.receiver_id         = r.receiver_id
   AND d.recv_ln_nbr         = r.recv_ln_nbr
   AND d.recv_ship_seq_nbr   = r.recv_ship_seq_nbr
  LEFT JOIN direct_sched_sum ds
    ON ds.business_unit      = r.business_unit
   AND ds.po_id              = r.po_id
   AND ds.line_nbr           = r.line_nbr
   AND ds.sched_nbr          = r.sched_nbr
  LEFT JOIN vchr_sum_match vs
    ON vs.business_unit      = r.business_unit
   AND vs.po_id              = r.po_id
   AND vs.line_nbr           = r.line_nbr
   AND vs.sched_nbr          = r.sched_nbr
),

/* 4) FINAL ship-level paid qty = DIRECT + ALLOCATED remainder */
vchr_sum_match_ship AS (
  SELECT
    r.business_unit,
    r.po_id,
    r.line_nbr,
    r.sched_nbr,

    r.rcv_business_unit,
    r.receiver_id,
    r.recv_ln_nbr,
    r.recv_ship_seq_nbr,

    /* FIFO allocated portion of �unmapped� paid qty */
    LEAST(
      r.qty_rcvd_unmapped,
      GREATEST(
        r.qty_paid_to_allocate - (r.cum_rcvd_unmapped - r.qty_rcvd_unmapped),
        0
      )
    ) AS qty_vchr_alloc,

    /* total paid qty applied to this receipt ship-line */
    ( r.qty_vchr_direct +
      LEAST(
        r.qty_rcvd_unmapped,
        GREATEST(
          r.qty_paid_to_allocate - (r.cum_rcvd_unmapped - r.qty_rcvd_unmapped),
          0
        )
      )
    ) AS qty_vchr_ship
  FROM rcv_ship_ranked r
),

/* 5) Qualifying receipt schedules � now correctly at ship-line grain */
qual_ship AS (
  SELECT
    rls.business_unit,
    rls.receiver_id,
    rls.recv_ln_nbr,
    rls.recv_ship_seq_nbr,

    rls.business_unit_po,
    rls.po_id,
    rls.line_nbr,
    rls.sched_nbr,

    rls.oprid,
    rls.packsLip_no,
    rls.bill_of_lading,
    rls.receipt_dttm,
    rls.qty_sh_recvd,
    rls.descr254_mixed,

    /* OPEN qty on this ship line */
    GREATEST(
      NVL(rls.qty_sh_recvd,0) - NVL(vsr.qty_vchr_ship,0),
      0
    ) AS qty_open_ship

  FROM ps_recv_ln_ship rls
  JOIN params p
    ON 1=1

  /* only receipts for POs in scope */
  JOIN open_pos op
    ON op.business_unit = rls.business_unit_po
   AND op.po_id         = rls.po_id

  LEFT JOIN vchr_sum_match_ship vsr
    ON vsr.business_unit      = rls.business_unit_po
   AND vsr.po_id              = rls.po_id
   AND vsr.line_nbr           = rls.line_nbr
   AND vsr.sched_nbr          = rls.sched_nbr
   AND vsr.rcv_business_unit  = rls.business_unit
   AND vsr.receiver_id        = rls.receiver_id
   AND vsr.recv_ln_nbr        = rls.recv_ln_nbr
   AND vsr.recv_ship_seq_nbr  = rls.recv_ship_seq_nbr

  WHERE rls.recv_ship_status <> 'X'
    AND TRUNC(CAST(rls.receipt_dttm AS DATE))
        BETWEEN p.lookback_dt AND p.asof_dt

    /* only OPEN receipt qty lines */
    AND GREATEST(NVL(rls.qty_sh_recvd,0) - NVL(vsr.qty_vchr_ship,0), 0) > 0
),

/* Aggregate per receiver header (use OPEN qty to align with receipt file) */
ln_ship_agg AS (
  SELECT
    q.business_unit,
    q.receiver_id,

    MAX(q.oprid) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS requester_oprid,
    MAX(q.packsLip_no) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS tracking_no,
    MAX(NULLIF(TRIM(q.bill_of_lading),'')) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS bol_no,

    MAX(q.receipt_dttm) AS receipt_dttm,

    /* IMPORTANT: sum OPEN qty, not full received qty */
    SUM(NVL(q.qty_open_ship,0)) AS bol_qty,

    MAX(NULLIF(TRIM(q.descr254_mixed),'')) KEEP (DENSE_RANK FIRST ORDER BY q.recv_ln_nbr, q.recv_ship_seq_nbr) AS memo_line

  FROM qual_ship q
  GROUP BY q.business_unit, q.receiver_id
),

dist_agg AS (
  SELECT
    rld.business_unit,
    rld.receiver_id,

    MAX(rld.business_unit_gl) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS company,

    MAX(NULLIF(TRIM(rld.delivered_to),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS shipment_contact,

    MAX(NULLIF(TRIM(rld.delivery_feedback),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS delivery_feedback,

    MAX(NULLIF(TRIM(rld.req_id),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS req_id,

    MAX(NULLIF(TRIM(rld.po_id),'')) KEEP (DENSE_RANK FIRST
      ORDER BY rld.recv_ln_nbr, rld.recv_ship_seq_nbr, rld.distrib_line_num) AS po_id,

    SUM(NVL(rld.merchandise_amt,0)) AS amount_to_receive

  FROM ps_recv_ln_distrib rld
  JOIN qual_ship q
    ON q.business_unit      = rld.business_unit
   AND q.receiver_id        = rld.receiver_id
   AND q.recv_ln_nbr        = rld.recv_ln_nbr
   AND q.recv_ship_seq_nbr  = rld.recv_ship_seq_nbr

  WHERE rld.recv_ds_status <> 'X'
    AND rld.dst_acct_type = 'DST'
  GROUP BY rld.business_unit, rld.receiver_id
)

SELECT
  h.receiver_id                                       AS "No",
  'Y'                                                 AS "Add Only",
  ' '                                                 AS "Receipt Reference For Update",
  h.receiver_id                                       AS "Receipt Number",
  ' '                                                 AS "Locked in Workday",
  'Y'                                                 AS "Submit",

  NVL(da.company,' ')                                 AS "Company",

  ' '                                                 AS "Bill of Lading",
  ' '                                                 AS "Requester",
  ' '                                                 AS "Requisition",
  ' '                                                 AS "Tracking Number",
  ' '                                                 AS "Supplier Order Ref",
  ' '                                                 AS "Shipment Date Time",
  ' '                                                 AS "Shipment Contact",
  ' '                                                 AS "Bill of Lading Quantity",
  ' '                                                 AS "License Plate",
  ' '                                                 AS "Shipment Ref",
  ' '                                                 AS "Document Status",-- h.vendor_id as Supp,

  wd.bh_wd_supplier_id                                AS "Supplier",

  TO_CHAR(h.receipt_dt,'YYYY-MM-DD')                  AS "Document Date",
  ' '                                                 AS "Last Updated",
  ' '                                                 AS "Created for Worker ID",

  --COALESCE(da.delivery_feedback, ls.memo_line, ' ')    AS "Memo",
    ls.requester_oprid||'-'||o.oprdefndesc          AS "Memo",
  ' '                                                 AS "Contingent Worker Receipt Purchase Order Line",
  ' '                                                 AS "Period Start Date",
  ' '                                                 AS "Period End Date",
  NULL                                                AS "Additional Amount",
  ' '                                                 AS "Amount to Receive",
  ' '                                                 AS "Contingent Worker Receipt Memo"

FROM ps_recv_hdr h
JOIN params p
  ON 1=1
/* only headers that have at least one qualifying receipt line */
JOIN (SELECT DISTINCT business_unit, receiver_id FROM qual_ship) qh
  ON qh.business_unit = h.business_unit
 AND qh.receiver_id   = h.receiver_id
 JOIN ps_bh_wd_sup_1to1 wd
  ON h.vendor_id = wd.bh_wd_ps_vendor_id
/*JOIN dist_agg da
  ON da.business_unit = h.business_unit
 AND da.receiver_id   = h.receiver_id*/
LEFT JOIN ln_ship_agg ls
  ON ls.business_unit = h.business_unit
 AND ls.receiver_id   = h.receiver_id
  LEFT JOIN PSOPRDEFN O ON ls.requester_oprid=O.OPRID
LEFT JOIN dist_agg da
  ON da.business_unit = h.business_unit
 AND da.receiver_id   = h.receiver_id


WHERE h.recv_status <>'X'--not in ('C', 'X')
  AND TRUNC(h.receipt_dt) BETWEEN p.lookback_dt AND p.asof_dt
--and h.receiver_id='0002594774'
ORDER BY h.receiver_id