WITH
params AS (
  SELECT TRUNC(to_date('15-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),

/* Candidate open-ish POs (status only) */
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
     AND h.vendor_id <> '2000017041' -- and h.po_id='0002800649'
),

/* Receipt totals to date */

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
    )

  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

/* Line flags (recv required + amount-only) */
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

/* Open schedule flag (aligned) */
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
         NVL (vs.qty_vchr,0) as qty_vchr,
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
     -- WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0)
 WHEN NVL(s.qty_po,0) > NVL(vs.qty_vchr,0)      THEN 1 ELSE 0
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
)
--SELECT * FROM sched_open;
,

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
)

,

/* Non-service PO filter (PO-level) */
service_flags AS (
  SELECT /*+ LEADING(hc d) USE_NL(d) INDEX(d) */ d.business_unit,
         d.po_id,
         CASE WHEN MAX(x.bh_xwlk_t1) IS NOT NULL THEN 'Y' ELSE 'N' END AS has_service
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

/* OPEN POs = exactly same PO-set driver as po_hdr_lookback12, plus goods/service split */
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
          AND sf.has_service   = 'N'
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

--SELECT * FROM open_pos;--_eligible;,

/* Final PO population = header PO set (no extra lookback ORs) */
included_po AS (
  SELECT /*+ MATERIALIZE */ op.business_unit, op.po_id
    FROM open_pos op
),

/* Location (effective dated) */
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

Deliver_location AS (
  SELECT
      a.setid,
      a.location,
      MIN(initcap(replace(
            c.std_id_num || '-' || b.std_id_num || '_' || e.descr || '_' || a.descr
          , ' ', '_'))) AS del_loc
  FROM ps_location_tbl a
  LEFT JOIN ps_location_id_nbr b
    ON a.setid = b.setid
   AND a.location = b.location
   AND b.std_id_num_qual = 'DPT'
   
  LEFT JOIN ps_location_id_nbr c
    ON b.setid = c.setid
   AND b.location = c.location
   AND c.std_id_num_qual = 'OU'
   
  LEFT JOIN ps_dept_tbl e
    ON b.std_id_num = e.deptid
   AND e.effdt = (
        SELECT MAX(e_ed.effdt)
          FROM ps_dept_tbl e_ed
         WHERE e.setid = e_ed.setid
           AND e.deptid = e_ed.deptid
           AND e_ed.effdt <= SYSDATE
   ) where
    a.effdt = (
        SELECT MAX(e_ed.effdt)
          FROM ps_location_tbl e_ed
         WHERE a.setid = e_ed.setid
           AND a.location = e_ed.location
           AND e_ed.effdt <= SYSDATE
   )
  GROUP BY a.setid, a.location
),

/* De-dupe mapping tables */
ou_comp_xlat AS (
  SELECT bhvalue, MAX(bhxlat) AS bhxlat
    FROM PS_BHXLATITEM
   WHERE fieldname = 'BH_WD_FDM_OU_COMP'
   GROUP BY bhvalue
),
spend_cat_xwlk AS (
  SELECT BH_XWLK_S1, MAX(BH_XWLK_S3) AS spend_cat
    FROM PS_BH_XWLK_VAL_TBL
   WHERE LONGNAME = 'WD_SPEND_CATEGORY'
   GROUP BY BH_XWLK_S1
),
inv_site_loc_type AS (
  SELECT BH_XWLK_S2, MAX(BH_XWLK_S3) AS inv_loc_type
    FROM PS_BH_XWLK_VAL_TBL
   WHERE LONGNAME = 'WD_LOC_INV_SITE_LOC_TYPE'
   GROUP BY BH_XWLK_S2
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

/* Pick best distrib per line/sched (prefer DST else lowest distrib_line_num) */
po_distrib_one AS (
  SELECT *
  FROM (
    SELECT /*+ LEADING(ip d) USE_NL(d) INDEX(d) */ d.*,
           ROW_NUMBER() OVER (
             PARTITION BY d.business_unit, d.po_id, d.line_nbr, d.sched_nbr
             ORDER BY CASE WHEN d.dst_acct_type = 'DST' THEN 0 ELSE 1 END,
                      d.distrib_line_num
           ) AS rn
    FROM ps_po_line_distrib d
    JOIN included_po ip
      ON ip.business_unit = d.business_unit
     AND ip.po_id         = d.po_id
    WHERE d.distrib_ln_status <> 'X'
  )
  WHERE rn = 1
),

base AS (
  SELECT DISTINCT
      h.business_unit,
      h.po_id,
      l.line_nbr,
      s.sched_nbr,
      h.po_id AS po_no,

      l.inv_item_id,
      l.itm_id_vndr,
      l.unit_of_measure,
      l.category_id,
      l.cntrct_id,
      l.cntrct_line_nbr,
      NVL(NULLIF(TRIM(l.descr254_mixed2), ''), l.descr254_mixed) AS item_descr,

      CASE
        WHEN so.amt_only_flg = 'Y' THEN 1
        WHEN so.recv_req = 'Y' THEN GREATEST(NVL(s.qty_po,0) - NVL(so.qty_vchr,0), 0)
        ELSE
          CASE
            WHEN NVL(s.price_po,0) = 0 THEN 0
            ELSE --GREATEST( (GREATEST(NVL(so.sched_amt,0) - NVL(so.merch_amt_vchr,0),0)) / NULLIF(s.price_po,0), 0)
            GREATEST(NVL(s.qty_po,0) - NVL(so.qty_vchr,0),0)
          END
      END AS qty_po,

      CASE
        WHEN so.amt_only_flg = 'Y'
          THEN GREATEST(NVL(so.sched_amt,0) - NVL(so.merch_amt_vchr,0), 0)
        ELSE NVL(s.price_po,0)
      END AS price_po,

      CASE
        WHEN so.amt_only_flg = 'Y'
          THEN GREATEST(NVL(so.sched_amt,0) - NVL(so.merch_amt_vchr,0), 0)
        WHEN so.recv_req = 'Y'
          THEN GREATEST(NVL(s.qty_po,0) - NVL(so.qty_vchr,0), 0) * NVL(s.price_po,0)
        ELSE
         -- GREATEST(NVL(so.sched_amt,0) - NVL(so.merch_amt_vchr,0), 0)
         (GREATEST(NVL(s.qty_po,0) - NVL(so.qty_vchr,0),0))*NULLIF(s.price_po,0)
      END AS extended_amt,

      s.due_dt,
      s.shipto_setid,
      s.shipto_id,

      d.business_unit_gl,
      d.location,
      d.resource_category,
      d.distrib_ln_status,

      h.prepaid_po_flg,
      cnt.cntrct_style,
      d.deptid,
      d.operating_unit,
      d.account,
      d.business_unit_in,
      h.vendor_id
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
  LEFT JOIN ps_cntrct_hdr cnt
    ON cnt.setid     = 'SHARE'
   AND cnt.cntrct_id = l.cntrct_id
  WHERE l.cancel_status <> 'X'
    AND s.cancel_status <> 'X'
)
,

po_dist_flags AS (
  SELECT d.business_unit,
         d.po_id,
         MAX(CASE WHEN d.deptid = '20100' THEN 1 ELSE 0 END) AS has_inventory_dept
    FROM base op
    JOIN ps_po_line_distrib d
      ON d.business_unit = op.business_unit
     AND d.po_id         = op.po_id
   GROUP BY d.business_unit, d.po_id
)

SELECT --b.shipto_id,
    b.po_no                                                     AS "*No.",
    b.line_nbr                                                  AS "*Goods Line Replacement Data Line No",
    b.inv_item_id                                               AS "Item",
    b.po_no || '-' || TO_CHAR(b.line_nbr)                       AS "Goods Purchase Order Line ID",
    b.line_nbr                                                  AS "Line Number",
    x.bhxlat                                                    AS "Line Company",

   CASE WHEN TRIM(b.inv_item_id) is null THEN b.itm_id_vndr ELSE ' ' END
                                                                AS "Supplier Item Identifier",
    ' '                                                         AS "Supplier Part ID",
    ' '                                                         AS "Supplier Part Auxiliary ID",
    ' '                                                         AS "UNSPSC Code",
    CASE WHEN TRIM(b.inv_item_id) is null THEN b.item_descr ELSE ' ' END
                                                                AS "Item Description",

    ' '                                                         AS "Supplier Contract Line",
    ' '                                                         AS "Commodity Code",
    ' '                                                         AS "Payment Status",
    ' '                                                         AS "Invoice Status",
    ' '                                                         AS "Receiving Status",
    ' '                                                         AS "Shipping Status",
    ' '                                                         AS "Tracking Status",

   CASE WHEN TRIM(b.inv_item_id) is null THEN sc.spend_cat ELSE ' ' END
                                                                AS "Resource Category",

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
    ' '                                                         AS "Tax Option 52",
    ' '                                                         AS "Tax Recoverability 6",
    ' '                                                         AS "Tax Option 6",
    ' '                                                         AS "Packaging String",

    b.qty_po                                                   AS "*Quantity",
    b.unit_of_measure                                           AS "*Unit of Measure",
    b.price_po                                                  AS "Unit Cost",
    ' '                                                         AS "Requested as No Charge",
    b.extended_amt                                              AS "Extended Amount",

    ' '                                                         AS "Lot Serial Information Reference",
    ' '                                                         AS "Lot Number",
    ' '                                                         AS "Serial Number",
    TO_CHAR(b.due_dt, 'YYYY-MM-DD')                             AS "Due Date",

    CASE WHEN ppt.has_inventory_dept = 1 THEN 'Inventory_Replenishment' ELSE ' ' END
                                                                AS "Delivery Type",
    CASE WHEN b.cntrct_style = 'PPD_AMORT' THEN 'Y' ELSE 'N' END AS "Prepaid",

    ' '                                                         AS "Down Payment",
    ' '                                                         AS "Retention",
    ' '                                                         AS "Requested Delivery Date",
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
      || '_' || b.shipto_id                                     AS "Ship To Address",

    ' '                                                         AS "Ship To Global Location Number",
    ' '                                                         AS "Ship To Location Identifier",
    ' '                                                         AS "Ship To Contact Is Employee",
    ' '                                                         AS "Ship To Contact Worker ID",
    ' '                                                         AS "Requester Is Employee",
    ' '                                                         AS "Requester Worker ID",

    CASE WHEN ppt.has_inventory_dept = 1
         THEN ilt.inv_loc_type
         ELSE dl.del_loc
    END                                                         AS "Deliver To Location",

    ' '                                                         AS "Deliver To Location GLN",
    ' '                                                         AS "Deliver To Location Location Id",
    TRIM(b.cntrct_id)                                           AS "Supplier Contract",
    ' '                                                         AS "Storage Location",
   ' '                                         AS "Close Status"
FROM base b
LEFT JOIN location_eff sh_loc
  ON sh_loc.setid    = b.shipto_setid
 AND sh_loc.location = b.shipto_id
LEFT JOIN Deliver_location dl
  ON dl.setid    = b.shipto_setid
 AND dl.location = b.shipto_id
LEFT JOIN ou_comp_xlat x
  ON x.bhvalue = b.operating_unit
LEFT JOIN spend_cat_xwlk sc
  ON sc.bh_xwlk_s1 = b.account
LEFT JOIN po_dist_flags ppt
  ON ppt.business_unit = b.business_unit
 AND ppt.po_id         = b.po_id
LEFT JOIN inv_site_loc_type ilt
  ON ilt.bh_xwlk_s2 = b.business_unit_in
WHERE (b.extended_amt > 0 and  b.qty_po>0)
ORDER BY b.po_no, b.line_nbr

