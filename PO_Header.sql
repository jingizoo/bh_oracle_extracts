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
    AND h.po_dt >= p.lookback_dt
    AND h.po_status NOT IN ('C','X')
    AND h.vendor_id <> '2000017041' -- and h.po_id='0002800649'
),

/* ------------------------------
   Receipts to date
   ------------------------------ */
recv_agg AS (
  SELECT
      r.business_unit_po AS business_unit,
      r.po_id,
      r.line_nbr,
      r.sched_nbr,
      SUM(NVL(r.qty_sh_accpt, 0))    AS qty_rcvd_suom,
      SUM(NVL(r.merchandise_amt_po, 0))   AS merch_amt_rcvd_po
  FROM ps_recv_ln_ship r
  JOIN hdr_candidates hc
    ON hc.business_unit = r.business_unit_po
   AND hc.po_id         = r.po_id
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
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
   JOIN ps_pymnt_vchr_xref px
   on px.business_unit = v.business_unit
        AND px.voucher_id    = v.voucher_id
        AND px.pymnt_action  <> 'X'
        and px.paid_amt >0
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
      x.qty_rcvd_suom,
      x.merch_amt_rcvd_po,
      x.merch_amt_vchr,
      x.sched_amt,
      x.qty_vchr,
      CASE
  WHEN NVL(x.cancel_status,' ') IN ('C','X') THEN 0

  WHEN x.amt_only_flg = 'Y' THEN
    CASE
      WHEN GREATEST(NVL(x.sched_amt,0) - NVL(x.merch_amt_vchr,0), 0) > 1
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
        NVL(r.qty_rcvd_suom, 0)     AS qty_rcvd_suom,
        NVL(r.merch_amt_rcvd_po, 0) AS merch_amt_rcvd_po,
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
    LEFT JOIN recv_agg r
      ON r.business_unit  = s.business_unit
     AND r.po_id          = s.po_id
     AND r.line_nbr       = s.line_nbr
     AND r.sched_nbr      = s.sched_nbr
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
  LEFT JOIN po_rcv_activity pra
    ON pra.business_unit = hc.business_unit
   AND pra.po_id         = hc.po_id
  LEFT JOIN po_inv_activity pia
    ON pia.business_unit = hc.business_unit
   AND pia.po_id         = hc.po_id
  WHERE EXISTS (
    SELECT 1
      FROM open_po_eligible ope
     WHERE ope.business_unit = hc.business_unit
       AND ope.po_id         = hc.po_id
  )
  AND (
       hc.po_dt >= p.lookback_dt

  )
  and exists(
  select 1 from po_has_pos_amt_and_qty p
   WHERE p.business_unit = hc.business_unit
       AND p.po_id         = hc.po_id
)
),

/* ------------------------------
   First open schedule (ship-to fields)
   ------------------------------ */
first_open_sched AS (
  SELECT business_unit,
         po_id,
         MAX(shipto_setid)  KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS shipto_setid,
         MAX(shipto_id)     KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS shipto_id,
         MAX(freight_terms) KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS freight_terms,
         MAX(ship_type_id)  KEEP (DENSE_RANK FIRST ORDER BY line_nbr, sched_nbr) AS ship_type_id
  FROM sched_open
  WHERE is_open = 1
  GROUP BY business_unit, po_id
),

/* ------------------------------
   Location effective dated
   ------------------------------ */
loc_max AS (
  SELECT l.setid,
         l.location,
         MAX(l.effdt) AS effdt
  FROM ps_location_tbl l
  CROSS JOIN params p
  WHERE l.effdt <= p.asof_dt
    AND l.eff_status = 'A'
  GROUP BY l.setid, l.location
),
location_eff AS (
  SELECT l.setid,
         l.location,
         l.attn_to,
         l.address1, l.address2, l.address3, l.address4,
         l.city, l.state, l.postal, l.country
  FROM ps_location_tbl l
  JOIN loc_max m
    ON m.setid    = l.setid
   AND m.location = l.location
   AND m.effdt    = l.effdt
),

/* ------------------------------
   Comments (public + internal)
   ------------------------------ */
po_comments_clean AS (
  SELECT b.business_unit,
         b.po_id,
         b.public_flg,
         b.comment_id,
         b.random_cmmt_nbr,
         REGEXP_REPLACE(t.comments_2000, '[^[:print:]]', ' ') AS clean_comment
  FROM open_pos op
  JOIN ps_po_comments b
    ON b.business_unit = op.business_unit
   AND b.po_id         = op.po_id
  JOIN ps_comments_tbl t
    ON t.oprid           = b.oprid
   AND t.comment_id      = b.comment_id
   AND t.random_cmmt_nbr = b.random_cmmt_nbr
  WHERE t.comments_2000 IS NOT NULL
),
Pull_Comments AS (
  SELECT
      x.business_unit,
      x.po_id,
      RTRIM(
        XMLCAST(
          XMLAGG(
            CASE WHEN x.public_flg = 'Y'
                 THEN XMLELEMENT(e, XMLCDATA(x.clean_comment || ' | '))
            END
            ORDER BY x.comment_id, x.random_cmmt_nbr
          ) AS CLOB
        ),
        ' | '
      ) AS memo,
      RTRIM(
        XMLCAST(
          XMLAGG(
            CASE WHEN x.public_flg <> 'Y'
                 THEN XMLELEMENT(e, XMLCDATA(x.clean_comment || ' | '))
            END
            ORDER BY x.comment_id, x.random_cmmt_nbr
          ) AS CLOB
        ),
        ' | '
      ) AS internal_memo
  FROM po_comments_clean x
  GROUP BY x.business_unit, x.po_id
),

/* ------------------------------
   POTYPE classification (same logic as your original)
   ------------------------------ */
par_cons_items AS (
  SELECT /*+ MATERIALIZE */ DISTINCT bh_xwlk_s3 AS inv_item_id
  FROM ps_bh_xwlk_val_tbl
  WHERE longname = 'WD_PAR_CONS_NONSTOCK'
    AND bh_xwlk_s3 IS NOT NULL
),
cm_items AS (
  SELECT /*+ MATERIALIZE */ DISTINCT cm.business_unit, cm.inv_item_id
  FROM ps_cm_item_method cm
  JOIN ps_bu_items_inv it
    ON it.business_unit = cm.business_unit
   AND it.inv_item_id   = cm.inv_item_id
),
po_item_flags AS (
  SELECT l.business_unit,
         l.po_id,
         MAX(CASE WHEN pci.inv_item_id IS NOT NULL THEN 1 ELSE 0 END) AS has_par_cons,
         MAX(CASE WHEN cmi.inv_item_id IS NOT NULL THEN 1 ELSE 0 END) AS has_cm_item
  FROM open_pos op
  JOIN ps_po_line l
    ON l.business_unit = op.business_unit
   AND l.po_id         = op.po_id
  LEFT JOIN par_cons_items pci
    ON pci.inv_item_id = l.inv_item_id
  LEFT JOIN cm_items cmi
    ON cmi.business_unit = l.business_unit
   AND cmi.inv_item_id   = l.inv_item_id
  GROUP BY l.business_unit, l.po_id
),
po_dist_flags AS (
  SELECT /*+ LEADING(op d) USE_NL(d) INDEX(d) */ d.business_unit,
         d.po_id,
         MAX(CASE WHEN d.deptid = '20100' THEN 1 ELSE 0 END) AS has_inventory_dept,
         MAX(CASE WHEN rl.ln_type = 'DCPO' THEN 1 ELSE 0 END) AS has_dcpo,
         CASE WHEN MAX(x.BH_XWLK_t1) IS NOT NULL THEN 'Y' ELSE 'N' END AS has_service
  FROM open_pos op
  JOIN ps_po_line_distrib d
    ON d.business_unit = op.business_unit
   AND d.po_id         = op.po_id
  LEFT JOIN ps_req_line rl
    ON rl.business_unit = d.business_unit
   AND rl.req_id        = d.req_id
   AND rl.line_nbr      = d.req_line_nbr
  LEFT JOIN PS_BH_XWLK_VAL_TBL x
    ON x.LONGNAME        = 'WD_ACCT_TO_PO_TYPE'
   AND x.bh_xwlk_module  = 'PO'
   AND x.bh_xwlk_track   = 'SCM'
   AND x.BH_XWLK_S2      = d.account
  GROUP BY d.business_unit, d.po_id
),
Pull_POTYPE AS (
  SELECT op.business_unit,
         op.po_id,
         CASE
           WHEN h.buyer_id = 'BILLONLY'         THEN 'Bill Only'
           WHEN h.buyer_id = 'BH_CAPITAL_BUYER' THEN 'Capital'
           WHEN df.has_inventory_dept = 1       THEN 'Inventory'
           WHEN df.has_dcpo = 1                 THEN 'Punchout'
           WHEN df.has_service = 'Y'            THEN 'Service'
           WHEN ifl.has_par_cons = 1            THEN 'Par Consignment'
           WHEN ifl.has_cm_item = 1             THEN 'Consignment bill and replace'
           ELSE 'Supplies'
         END AS POTYPE
  FROM open_pos op
  JOIN hdr_candidates h
    ON h.business_unit = op.business_unit
   AND h.po_id         = op.po_id
  LEFT JOIN po_dist_flags df
    ON df.business_unit = op.business_unit
   AND df.po_id         = op.po_id
  LEFT JOIN po_item_flags ifl
    ON ifl.business_unit = op.business_unit
   AND ifl.po_id         = op.po_id
),

/* ------------------------------
   Procedure info (same logic)
   ------------------------------ */
consign_info AS (
  SELECT /*+ MATERIALIZE */
      a.business_unit,
      a.req_id,
      a.bh_medrec_no,
      a.bh_har_num,
      a.bh_procede_dt
  FROM ps_bh_consgn_hdr a
  WHERE EXISTS (
    SELECT 1
    FROM ps_bh_consgn_line b
    WHERE b.business_unit = a.business_unit
      AND b.req_id        = a.req_id
  )
),
Pull_ProcedureInfo AS (
  SELECT
      op.business_unit,
      op.po_id,
      MIN(ci.bh_medrec_no)    KEEP (DENSE_RANK FIRST ORDER BY ci.bh_procede_dt NULLS LAST) AS mrn,
      MIN(ci.bh_procede_dt)   KEEP (DENSE_RANK FIRST ORDER BY ci.bh_procede_dt NULLS LAST) AS phdate,
      MIN(ci.bh_har_num)      KEEP (DENSE_RANK FIRST ORDER BY ci.bh_procede_dt NULLS LAST) AS har
  FROM open_pos op
  JOIN ps_po_line_distrib d
    ON d.business_unit = op.business_unit
   AND d.po_id         = op.po_id
  LEFT JOIN consign_info ci
    ON ci.business_unit = d.business_unit
   AND ci.req_id        = d.req_id
  GROUP BY op.business_unit, op.po_id
),

/* ------------------------------
   Req_name (AGG to 1 row/PO)
   ------------------------------ */
Req_name AS (
  SELECT
      op.business_unit,
      op.po_id,
   ---   d.req_id,
min(r.requestor_id) as req_id,
min(opr.emplid)  as requestor_id,
case WHEN INSTR(max(opr.oprdefndesc), ',') > 0 THEN
       TRIM(SUBSTR(max(opr.oprdefndesc), INSTR(max(opr.oprdefndesc), ',') + 1))
    || ' '
    || TRIM(SUBSTR(max(opr.oprdefndesc), 1, INSTR(max(opr.oprdefndesc), ',') - 1))
  ELSE
    max(opr.oprdefndesc) end as ship_to_contact_detail
  FROM open_pos op
  JOIN ps_po_line_distrib d
    ON d.business_unit = op.business_unit
   AND d.po_id         = op.po_id
  LEFT JOIN ps_req_hdr r
    ON r.business_unit = d.business_unit_req
   AND r.req_id        = d.req_id
  LEFT JOIN psoprdefn opr
    ON opr.oprid = r.requestor_id
  GROUP BY op.business_unit, op.po_id
),

/* ------------------------------
   Sourcing rule -> buyer mapping
   ------------------------------ */
sourcing_rule AS (
  SELECT
      op.business_unit,
      op.po_id,
      MIN(d.operating_unit) KEEP (DENSE_RANK FIRST ORDER BY d.budget_dt DESC NULLS LAST) AS operating_unit,
      MIN(d.deptid)         KEEP (DENSE_RANK FIRST ORDER BY d.budget_dt DESC NULLS LAST) AS deptid
  FROM open_pos op
  JOIN ps_po_line_distrib d
    ON d.business_unit = op.business_unit
   AND d.po_id         = op.po_id
  GROUP BY op.business_unit, op.po_id
),
buyer_userid AS (
  SELECT
      s.business_unit,
      s.po_id,
      x.bh_xwlk_t1,
      CASE
  WHEN INSTR(oprdefndesc, ',') > 0 THEN
       TRIM(SUBSTR(oprdefndesc, INSTR(oprdefndesc, ',') + 1))
    || ' '
    || TRIM(SUBSTR(oprdefndesc, 1, INSTR(oprdefndesc, ',') - 1))
  ELSE
    oprdefndesc
END as bill_to_contact_name, o.oprid as bill_to_contact
     
  FROM sourcing_rule s
  LEFT JOIN ps_bh_xwlk_val_tbl x
    ON x.longname       = 'WD_CC_TO_BUYER_ID'
   AND x.bh_xwlk_module = 'PO'
   AND x.bh_xwlk_track  = 'SCM'
   AND x.bh_xwlk_s2     = s.operating_unit
   AND x.bh_xwlk_s3     = s.deptid
  LEFT JOIN psoprdefn o
    ON o.oprid = x.bh_xwlk_t1  
),

/* ------------------------------
   wd_comp single-row (prevents duplication)
   ------------------------------ */
wd_comp AS (
  SELECT MAX(bh_xwlk_t1) AS bh_xwlk_t1
  FROM ps_bh_xwlk_val_tbl
  WHERE UPPER(longname) = 'WD_BILL_TO_ADDRESS_ID'
    AND bh_xwlk_module  = 'PO'
    AND bh_xwlk_track   = 'SCM'
    AND bh_xwlk_s1      = 'CO_80800'
)
--start;
SELECT --r.req_id,
      h.po_id                AS "*No.",
      'Y'                    AS "Add Only",
      NULL                   AS "Purchase Orders For Updates",
      h.po_id                AS "Purchase Order ID",
      'Y'                    AS "Submit",
      'N'                    AS "Locked in Workday",
      h.po_id                AS "Document Number",
      NULL                   AS "Invoice Status",
      NULL                   AS "Payment Status",
      NULL                   AS "Receiving Status",
      NULL                   AS "Shipping Status",
      NULL                   AS "Tracking Status",
      'CO_80800'             AS "*Company",
      wd.bh_wd_supplier_id   AS "*Supplier",
      ppt.potype             AS "Purchase Order Type",
      NULL                   AS "External PO Number",
      NULL                   AS "Order From Supplier Connection",
      TO_CHAR(h.po_dt, 'YYYY-MM-DD') AS "*Document Date",
      NULL                   AS "Tax Amount",
      NULL                   AS "Freight Amount",
      NULL                   AS "Other Charges",
      NULL                   AS "Payment Terms",
      NULL                   AS "Override Payment Type",
      NULL                   AS "Procurement Credit Card",
      NULL                   AS "Shipping Terms",
      NULL                   AS "Shipping Method",
      NULL                   AS "Shipping Instruction",
      NULL                   AS "Due Date",
      NULL                   AS "Supplier Contract",
      h.currency_cd          AS "Currency",
      CASE h.poa_status
          WHEN 'AC' THEN 'Y'
          WHEN 'AK' THEN 'Y'
          ELSE 'N'
      END                    AS "Acknowledgement Expected",
      NULL                   AS "Default Tax Option",
      NULL                   AS "Default Tax Code",
      'Phone'                AS "Issue Option",
      'Y'                    AS "Buyer Is Employee",
      CASE WHEN us.bh_xwlk_t1 IS NULL THEN '216749' ELSE us.bh_xwlk_t1 END AS "Buyer Worker ID",
      'Y'                    AS "Bill To Contact Is Employee",
      CASE WHEN us.bh_xwlk_t1 IS NULL THEN '216749' ELSE us.bh_xwlk_t1 END AS "Bill To Contact Worker ID",
      CASE WHEN us.bh_xwlk_t1 IS NULL THEN 'Christie Lockman'
        

           ELSE nvl(us.bill_to_contact_name,'Gwinda I Fay')
      END                    AS "Bill To Contact Detail",
      NULL                   AS "Bill To Address",
      wd_comp.bh_xwlk_t1     AS "Bill To Address ID",
      'Y'                    AS "Ship To Contact Is Employee",
    
     -- nvl(trim(r.requestor_id), h.oprid_entered_by) as "Ship To Contact Worker ID",
     
     nvl(trim(r.requestor_id), opr.emplid) as "Ship To Contact Worker ID",
     -- opr.oprdefndesc       
       nvl(trim(r.ship_to_contact_detail), case WHEN INSTR(opr.oprdefndesc, ',') > 0 THEN
       TRIM(SUBSTR(opr.oprdefndesc, INSTR(opr.oprdefndesc, ',') + 1))
    || ' '
    || TRIM(SUBSTR(opr.oprdefndesc, 1, INSTR(opr.oprdefndesc), ',') - 1))
  ELSE
    opr.oprdefndesc
END ) AS "Ship To Contact Detail",
      ' '                    AS "Ship To Address",
      initcap('SHIP_TO_'
              || replace(trim(substr(sh_loc.address1, 1, 11))
                         || '_'
                         || substr(sh_loc.city, 1, 5) || '_'
                         || sh_loc.state || '_'
                         || substr(sh_loc.postal, 1, 5), ' ', '_'))
      || '_' || fos.shipto_id AS "Ship To Address ID",
      NULL                   AS "Document Link",
      pc.memo                AS "Memo",
      pc.internal_memo       AS "Internal Memo",
      NULL                   AS "Prepaid",
      NULL                   AS "Prepayment Release Type",
      NULL                   AS "Expected Release Date",
      NULL                   AS "Frequency",
      NULL                   AS "Number of Prepayment Installments",
      NULL                   AS "Use Invoice Date",
      NULL                   AS "Specified Date",
      NULL                   AS "Use Prepaid Posting Rules for Receipt Accruals",
      NULL                   AS "Percent to Retain",
      NULL                   AS "Estimated Retention Release Date",
      NULL                   AS "XMLNAME 3rd Party Retention",
      NULL                   AS "Retention Memo",
      NULL                   AS "Down Payment Amount",
      NULL                   AS "Down Payment Percentage",
      NULL                   AS "Down Payment Memo",
      CASE
          WHEN ppt.potype = 'Bill Only' THEN TO_CHAR(ph.phdate, 'YYYY-MM-DD')
          ELSE NULL
      END                    AS "Procedure Date",
      NULL                   AS "Procedure",
      CASE
          WHEN ppt.potype = 'Bill Only' THEN ph.har
          ELSE ' '
      END                    AS "Procedure Number",
      NULL                   AS "Patient ID",
      CASE
          WHEN ppt.potype = 'Bill Only' THEN ph.mrn
          ELSE ' '
      END                    AS "Medical Record Number",
      NULL                   AS "Physician ID",
      NULL                   AS "Verified By",
      NULL                   AS "Supplier Representative",
      NULL                   AS "Additional Procedure Details"
FROM open_pos op
JOIN hdr_candidates h
  ON h.business_unit = op.business_unit
 AND h.po_id         = op.po_id
JOIN ps_bus_unit_tbl_pm bu
  ON bu.business_unit = h.business_unit
JOIN ps_bh_wd_sup_1to1 wd
  ON h.vendor_id = wd.bh_wd_ps_vendor_id
LEFT JOIN first_open_sched fos
  ON fos.business_unit = h.business_unit
 AND fos.po_id         = h.po_id
LEFT JOIN location_eff sh_loc
  ON sh_loc.setid      = fos.shipto_setid
 AND sh_loc.location   = fos.shipto_id
LEFT JOIN Pull_Comments pc
  ON pc.business_unit  = h.business_unit
 AND pc.po_id          = h.po_id
LEFT JOIN Pull_POTYPE ppt
  ON ppt.business_unit = h.business_unit
 AND ppt.po_id         = h.po_id
LEFT JOIN Pull_ProcedureInfo ph
  ON ph.business_unit  = h.business_unit
 AND ph.po_id          = h.po_id
LEFT JOIN psoprdefn opr
  ON opr.oprid = h.oprid_entered_by
 
LEFT JOIN buyer_userid us
  ON us.business_unit = h.business_unit
 AND us.po_id         = h.po_id
LEFT JOIN Req_name r
  ON r.business_unit = h.business_unit
 AND r.po_id         = h.po_id
CROSS JOIN wd_comp
--where h.po_id='0002549389'
ORDER BY h.business_unit, h.po_id