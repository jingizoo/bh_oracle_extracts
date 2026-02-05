/* Service PO Line extract for Workday:
   - Builds a 12‑month “open service PO” population using matched + paid voucher activity and PO status
   - Filters for service POs and computes remaining amounts at the PO line/schedule level
   - Outputs one row per qualifying service PO line in the Workday layout */

WITH
params AS (
  SELECT TRUNC(to_date('15-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),

hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status,
         h.vendor_id
    FROM ps_po_hdr h
    CROSS JOIN params p
   WHERE h.po_dt <= p.asof_dt
     AND h.po_dt >= p.lookback_dt
     AND h.po_status NOT IN ('C','X')
     AND h.vendor_id <> '2000017041' --and h.po_id='0002803045'

),

/* Receipts to date */

/* Vouchered merch amount per PO line/sched (as-of) */

/* only count vouchered amt/qty when voucher is MATCHED + PAID */
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
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.match_status_vchr = 'M'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)

    AND EXISTS (
      SELECT /*+ INDEX(px) */ 1
      FROM ps_pymnt_vchr_xref px
      WHERE px.business_unit = v.business_unit
        AND px.voucher_id    = v.voucher_id
        AND px.pymnt_action  <> 'X'
         AND px.paid_amt > 0
    )

  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

/* Line flags */
po_line_flags AS (
  SELECT /*+ LEADING(hc l) USE_NL(l) INDEX(l) */ l.business_unit,
         l.po_id,
         l.line_nbr,
         NVL(l.recv_req,'Y')     AS recv_req,
         NVL(l.amt_only_flg,'N') AS amt_only_flg
    FROM ps_po_line l
    JOIN hdr_candidates hc
      ON hc.business_unit = l.business_unit
     AND hc.po_id         = l.po_id
),

/* Open schedule logic aligned */
sched_open AS (
  SELECT /*+ LEADING(hc s) USE_NL(s) INDEX(s) */ s.business_unit,
         s.po_id,
         s.line_nbr,
         s.sched_nbr,
         s.cancel_status,
         s.due_dt,
         s.shipto_setid,
         s.shipto_id,
         s.qty_po,
         s.price_po,
         s.merchandise_amt,
         s.liquidate_method,
         lf.recv_req,
         lf.amt_only_flg,
NVL(vs.merch_amt_vchr, 0)   AS merch_amt_vchr,
         NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) AS sched_amt,
         CASE
  WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0

  WHEN lf.amt_only_flg = 'Y' THEN
    CASE
      WHEN GREATEST(
             NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0))
           - NVL(vs.merch_amt_vchr,0),
           0
           ) > 1
      THEN 1 ELSE 0
    END

  WHEN lf.recv_req = 'Y' THEN
    CASE
      WHEN NVL(s.qty_po,0) > NVL(vs.qty_vchr,0)
      THEN 1 ELSE 0
    END

  ELSE
    CASE
      WHEN GREATEST(
             NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0))
           - NVL(vs.merch_amt_vchr,0),
           0
           ) > 1
      THEN 1 ELSE 0
    END
END AS is_open

    FROM ps_po_line_ship s
    JOIN hdr_candidates hc
      ON hc.business_unit = s.business_unit
     AND hc.po_id         = s.po_id
    JOIN po_line_flags lf
      ON lf.business_unit = s.business_unit
     AND lf.po_id         = s.po_id
     AND lf.line_nbr      = s.line_nbr
    LEFT JOIN vchr_sum_match vs
      ON vs.business_unit = s.business_unit
     AND vs.po_id         = s.po_id
     AND vs.line_nbr      = s.line_nbr
     AND vs.sched_nbr     = s.sched_nbr
),

/* Precompute POs that have at least one OPEN schedule + active line + active distrib */
open_po_eligible AS (
  SELECT /*+ MATERIALIZE LEADING(so l d) USE_NL(l) INDEX(l) USE_NL(d) INDEX(d) */
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

open_pos AS (
  SELECT /*+ MATERIALIZE */ DISTINCT hc.business_unit, hc.po_id, hc.po_dt
    FROM hdr_candidates hc
    CROSS JOIN params p
   WHERE hc.po_dt >= p.lookback_dt
     AND EXISTS (
       SELECT 1
         FROM open_po_eligible ope
        WHERE ope.business_unit = hc.business_unit
          AND ope.po_id         = hc.po_id
     )
     AND EXISTS (
       SELECT 1
         FROM service_flags sf
        WHERE sf.business_unit = hc.business_unit
          AND sf.po_id         = hc.po_id
          AND sf.has_service   = 'Y'
     )
     AND EXISTS (
       SELECT 1
         FROM ps_bh_wd_sup_1to1 wd
        WHERE wd.bh_wd_ps_vendor_id = hc.vendor_id
     )
     AND EXISTS (
       SELECT 1
         FROM ps_bus_unit_tbl_pm bu
        WHERE bu.business_unit = hc.business_unit
     )
    
),

included_po AS (
  SELECT /*+ MATERIALIZE */ op.business_unit, op.po_id
    FROM open_pos op
),

/* Location effective-dated */
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
         l.address1, l.city, l.state, l.postal
    FROM ps_location_tbl l
    JOIN loc_max m
      ON m.setid    = l.setid
     AND m.location = l.location
     AND m.effdt    = l.effdt
),

/* Pick first OPEN schedule per PO line */
open_sched_pick AS (
  SELECT business_unit,
         po_id,
         line_nbr,
         MIN(sched_nbr) KEEP (DENSE_RANK FIRST ORDER BY sched_nbr) AS sched_nbr
    FROM sched_open
   WHERE is_open = 1
   GROUP BY business_unit, po_id, line_nbr
),

/* Pick best distrib per line/sched */
po_distrib_one AS (
  SELECT *
  FROM (
    SELECT /*+ LEADING(ip d) USE_NL(d) INDEX(d) */ d.*,
           ROW_NUMBER() OVER (
             PARTITION BY d.business_unit, d.po_id, d.line_nbr, d.sched_nbr
             ORDER BY CASE WHEN d.dst_acct_type = 'DST' THEN 0 ELSE 1 END,
                      d.distrib_line_num
           ) rn
    FROM ps_po_line_distrib d
    JOIN included_po ip
      ON ip.business_unit = d.business_unit
     AND ip.po_id         = d.po_id
    WHERE d.distrib_ln_status <> 'X'
  )
  WHERE rn = 1
),
spend_cat_xwlk AS (
  SELECT BH_XWLK_S1, MAX(BH_XWLK_S3) AS spend_cat
    FROM PS_BH_XWLK_VAL_TBL
   WHERE LONGNAME = 'WD_SPEND_CATEGORY'
   GROUP BY BH_XWLK_S1
),
base AS (
  SELECT DISTINCT
      h.business_unit,
      h.po_id,
      l.line_nbr,
      s.sched_nbr,
      h.po_id AS po_no,

      NVL(NULLIF(TRIM(l.descr254_mixed2), ''), l.descr254_mixed) AS line_descr,
      l.cntrct_id,
      l.cntrct_line_nbr,

      NVL(s.merchandise_amt, (NVL(s.qty_po,0) * NVL(s.price_po,0))) AS po_sched_amt,

      GREATEST(
        NVL(s.merchandise_amt, (NVL(s.qty_po,0) * NVL(s.price_po,0)))
        - NVL(vs.merch_amt_vchr, 0),
        0
      ) AS remaining_amt,

      s.due_dt,
      s.shipto_setid,
      s.shipto_id,

      d.business_unit_gl,
      d.resource_category,
      d.distrib_ln_status,
      d.account,
    l.inv_item_id

  FROM included_po ip
  JOIN ps_po_hdr h
    ON h.business_unit = ip.business_unit
   AND h.po_id         = ip.po_id
  JOIN ps_po_line l
    ON l.business_unit = h.business_unit
   AND l.po_id         = h.po_id
  JOIN open_sched_pick osp
    ON osp.business_unit = l.business_unit
   AND osp.po_id         = l.po_id
   AND osp.line_nbr      = l.line_nbr
  JOIN ps_po_line_ship s
    ON s.business_unit = l.business_unit
   AND s.po_id         = l.po_id
   AND s.line_nbr      = l.line_nbr
   AND s.sched_nbr     = osp.sched_nbr
  JOIN sched_open so
    ON so.business_unit = s.business_unit
   AND so.po_id         = s.po_id
   AND so.line_nbr      = s.line_nbr
   AND so.sched_nbr     = s.sched_nbr
   AND so.is_open       = 1
  JOIN po_distrib_one d
    ON d.business_unit = s.business_unit
   AND d.po_id         = s.po_id
   AND d.line_nbr      = s.line_nbr
   AND d.sched_nbr     = s.sched_nbr
  LEFT JOIN vchr_sum_match vs
    ON vs.business_unit = s.business_unit
   AND vs.po_id         = s.po_id
   AND vs.line_nbr      = s.line_nbr
   AND vs.sched_nbr     = s.sched_nbr
  WHERE l.cancel_status <> 'X'
    AND s.cancel_status <> 'X'
)

SELECT --b.inv_item_id, sc.spend_cat,
  b.po_no                                                     AS "*No.",
  b.line_nbr                                                  AS "*Service Line Replacement Data Line No",
  ' '                                                         AS "Item",
  b.po_no || '-' || TO_CHAR(b.line_nbr)                       AS "Service Order Line ID",
  b.line_nbr                                                  AS "Line Number",
  b.business_unit_gl                                          AS "Line Company",
  b.line_descr                                                AS "Description",

  CASE
    WHEN TRIM(b.cntrct_id) IS NOT NULL AND TRIM(b.cntrct_id) <> ''
      THEN TRIM(b.cntrct_id) || '-' || TO_CHAR(b.cntrct_line_nbr)
    ELSE ' '
  END                                                         AS "Supplier Contract Line",

  ' '                                                         AS "Commodity Code",
  ' '                                                         AS "Payment Status",
  ' '                                                         AS "Invoice Status",
  ' '                                                         AS "Receiving Status",

    sc.spend_cat        AS "*Resource Category",

  ' '                                                         AS "Tax Applicability",
  ' '                                                         AS "Tax Code",
  ' '                                                         AS "Tax Rate 1",
  ' '                                                         AS "Tax Recoverability 1",
  ' '                                                         AS "Tax Option 1",
  ' '                                                         AS "Tax Recoverability 2",
  ' '                                                         AS "Tax Option 2",
  ' '                                                         AS "Tax Recoverability 3",
  ' '                                                         AS "Tax Option 3",
  ' '                                                         AS "Tax Recoverability 4",
  ' '                                                         AS "Tax Option 4",
  ' '                                                         AS "Tax Recoverability 5",
  ' '                                                         AS "Tax Option 5",
  ' '                                                         AS "Tax Recoverability 6",
  ' '                                                         AS "Tax Option 6",

  round(b.remaining_amt,2)                                             AS "Extended Amount",
  TO_CHAR(b.due_dt, 'YYYY-MM-DD')                             AS "Due Date",

  ' '                                                         AS "Start Date",
  ' '                                                         AS "End Date",
  ' '                                                         AS "Prepaid",
  ' '                                                         AS "Down Payment",
  ' '                                                         AS "Retention",
  ' '                                                         AS "Budget Date",
  ' '                                                         AS "Memo",

  initcap('SHIP_TO_'
          || replace(trim(substr(sh_loc.address1, 1, 11))
                     || '_'
                     || substr(sh_loc.city, 1, 5)
                     || '_'
                     || sh_loc.state
                     || '_'
                     || substr(sh_loc.postal, 1, 5), ' ', '_'))
    || '_' || b.shipto_id                                      AS "Ship To Address",

  ' '                                                         AS "Ship To Contact Is Employee",
  ' '                                                         AS "Ship To Contact Worker ID",
  ' '                                                         AS "Requester Is Employee",
  ' '                                                         AS "Requester Worker ID",

  ' '                                                         AS "Deliver To Location",
  TRIM(b.cntrct_id)                                           AS "Supplier Contract",
  ' '                                                         AS "Storage Location",
  ' '                                         AS "Close Status"
FROM base b
LEFT JOIN location_eff sh_loc
  ON sh_loc.setid    = b.shipto_setid
 AND sh_loc.location = b.shipto_id
 LEFT JOIN spend_cat_xwlk sc
  ON sc.bh_xwlk_s1 = b.account
WHERE b.remaining_amt > 0
ORDER BY b.po_no, b.line_nbr