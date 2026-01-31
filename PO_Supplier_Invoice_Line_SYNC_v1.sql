/* ============================================================================
   Workday EIB – PO Invoice Lines – synced to latest PO selection criteria
   - Open PO scope = MATCHED+PAID voucher consumption (no receipt SUOM dependency)
   - Voucher scope = approved + unpaid + touches included open GOODS PO lines
   ============================================================================ */

WITH
params AS (
  SELECT TRUNC(to_date('15-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),
/* ============================================================
   SYNC PO SCOPE (latest) – eliminates receipt SUOM dependency
   - Open by MATCHED+PAID voucher consumption (qty_vchr/merch_amt_vchr)
   - Requires active PO_LINE + active PO_LINE_DISTRIB on the open sched
   - Lookback = PO_DT >= lookback_dt
   - Supplier + BU gates enforced
   ============================================================ */

po_hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status,
         h.vendor_id,
         h.currency_cd
  FROM ps_po_hdr h
  CROSS JOIN params p
  WHERE h.po_dt <= p.asof_dt
    AND h.po_status NOT IN ('C','X')
    AND h.vendor_id <> '2000017041'
),

paid_vouchers AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  WHERE px.pymnt_action <> 'X'
    AND NVL(px.paid_amt,0) > 0
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
  JOIN paid_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
  JOIN po_hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.match_status_vchr = 'M'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr, 1)
),

po_line_flags AS (
  SELECT
      l.business_unit,
      l.po_id,
      l.line_nbr,
      NVL(l.recv_req,'Y')     AS recv_req,
      NVL(l.amt_only_flg,'N') AS amt_only_flg,
      l.physical_nature
  FROM ps_po_line l
  JOIN po_hdr_candidates hc
    ON hc.business_unit = l.business_unit
   AND hc.po_id         = l.po_id
),

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
) ,

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

open_po_eligible AS (
  SELECT /*+ MATERIALIZE */ so.business_unit, so.po_id
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

included_po AS (
  SELECT /*+ MATERIALIZE */ DISTINCT hc.business_unit, hc.po_id
  FROM po_hdr_candidates hc
  CROSS JOIN params p
  WHERE hc.po_dt >= p.lookback_dt
    AND EXISTS (
      SELECT 1 FROM open_po_eligible ope
      WHERE ope.business_unit = hc.business_unit
        AND ope.po_id         = hc.po_id
    )
    AND EXISTS (
      SELECT 1 FROM ps_bh_wd_sup_1to1 wd
      WHERE wd.bh_wd_ps_vendor_id = hc.vendor_id
    )
    AND EXISTS (
      SELECT 1 FROM ps_bus_unit_tbl_pm bu
      WHERE bu.business_unit = hc.business_unit
    )
	  and exists(
  		select 1 from po_has_pos_amt_and_qty p
  		 WHERE p.business_unit = hc.business_unit
      		 AND p.po_id         = hc.po_id
		)

),

included_goods_lines AS (
  SELECT /*+ MATERIALIZE */ DISTINCT
         l.business_unit,
         l.po_id,
         l.line_nbr,
         s.sched_nbr
  FROM included_po ip
  JOIN ps_po_line l
    ON l.business_unit = ip.business_unit
   AND l.po_id         = ip.po_id
   --AND l.physical_nature = 'G'
   AND l.cancel_status <> 'X'
  JOIN ps_po_line_ship s
    ON s.business_unit = l.business_unit
   AND s.po_id         = l.po_id
   AND s.line_nbr      = l.line_nbr
   AND s.cancel_status <> 'X'
  JOIN sched_open so
    ON so.business_unit = s.business_unit
   AND so.po_id         = s.po_id
   AND so.line_nbr      = s.line_nbr
   AND so.sched_nbr     = s.sched_nbr
   AND so.is_open       = 1
  WHERE EXISTS (
    SELECT 1
    FROM ps_po_line_distrib d
    WHERE d.business_unit      = s.business_unit
      AND d.po_id              = s.po_id
      AND d.line_nbr           = s.line_nbr
      AND d.sched_nbr          = s.sched_nbr
      AND d.distrib_ln_status <> 'X'
  )
),

po_vouchers_pre AS (
  SELECT DISTINCT v.business_unit, v.voucher_id
  FROM ps_voucher v
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND v.voucher_style <> 'ADJ'
    AND NVL(v.invoice_dt, v.entered_dt) >= p.lookback_dt
    AND NVL(v.invoice_dt, v.entered_dt) <  (p.asof_dt + 1)
    AND EXISTS (
      SELECT 1
      FROM ps_voucher_line vl
      JOIN included_goods_lines gl
        ON gl.business_unit = vl.business_unit_po
       AND gl.po_id         = vl.po_id
       AND gl.line_nbr      = vl.line_nbr
       AND gl.sched_nbr     = NVL(vl.sched_nbr, gl.sched_nbr)
      WHERE vl.business_unit = v.business_unit
        AND vl.voucher_id    = v.voucher_id
        AND vl.po_id IS NOT NULL
        AND vl.po_id <> ' '
    )
  /*  AND NOT EXISTS (
      SELECT 1
      FROM ps_voucher_line vl2
      JOIN ps_po_line pl2
        ON pl2.business_unit = vl2.business_unit_po
       AND pl2.po_id         = vl2.po_id
       AND pl2.line_nbr      = vl2.line_nbr
      WHERE vl2.business_unit = v.business_unit
        AND vl2.voucher_id    = v.voucher_id
        AND vl2.po_id IS NOT NULL
        AND vl2.po_id <> ' '
        AND pl2.physical_nature = 'S'
    )*/
),

paid_xref AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN po_vouchers_pre pv
    ON pv.business_unit = px.business_unit
   AND pv.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND NVL(px.paid_amt,0) > 0
),

po_vouchers AS (
  SELECT pv.business_unit, pv.voucher_id
  FROM po_vouchers_pre pv
  JOIN ps_voucher v
    ON v.business_unit = pv.business_unit
   AND v.voucher_id    = pv.voucher_id
  WHERE NVL(v.appr_status,' ') = 'A'
    AND NOT EXISTS (
      SELECT 1 FROM paid_xref px
      WHERE px.business_unit = pv.business_unit
        AND px.voucher_id    = pv.voucher_id
    )
),

/* Restrict distrib_line pick to only the voucher lines we will output */
vl_keys AS (
  SELECT /*+ MATERIALIZE */ DISTINCT
         vl.business_unit,
         vl.voucher_id,
         vl.voucher_line_num
  FROM ps_voucher_line vl
  JOIN po_vouchers pv
    ON pv.business_unit = vl.business_unit
   AND pv.voucher_id    = vl.voucher_id
  JOIN included_goods_lines gl
    ON gl.business_unit = vl.business_unit_po
   AND gl.po_id         = vl.po_id
   AND gl.line_nbr      = vl.line_nbr
   AND gl.sched_nbr     = NVL(vl.sched_nbr, gl.sched_nbr)
  WHERE vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
),

dl_pick AS (
  SELECT business_unit, voucher_id, voucher_line_num, operating_unit, business_unit_gl
  FROM (
    SELECT
      d.business_unit,
      d.voucher_id,
      d.voucher_line_num,
      d.operating_unit,
      d.business_unit_gl,
      ROW_NUMBER() OVER (
        PARTITION BY d.business_unit, d.voucher_id, d.voucher_line_num
        ORDER BY CASE WHEN d.business_unit_gl = vh.business_unit_gl THEN 0 ELSE 1 END,
                 ABS(d.foreign_amount) DESC,
                 d.distrib_line_num
      ) AS rn
    FROM ps_distrib_line d
    JOIN vl_keys k
      ON k.business_unit     = d.business_unit
     AND k.voucher_id        = d.voucher_id
     AND k.voucher_line_num  = d.voucher_line_num
    JOIN ps_voucher vh
      ON vh.business_unit = d.business_unit
     AND vh.voucher_id    = d.voucher_id
  )
  WHERE rn = 1
),
shipto_setid_by_bu AS (
  SELECT r.setcntrlvalue AS business_unit_po, MAX(r.setid) AS shipto_setid
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

base AS (
  SELECT
    v.business_unit,
    v.voucher_id,
    v.voucher_style,
    ( NVL(v.saletx_amt, 0) + NVL(v.usetax_amt, 0) + NVL(v.vat_inv_amt, 0) + NVL(v.vat_noninv_amt, 0) ) AS taxable,
    vl.voucher_line_num,
    vl.descr,
    vl.descr254_mixed,
    vl.inv_item_id,
    vl.po_id,
    vl.line_nbr,
    vl.sched_nbr,
    vl.business_unit_po,
    vl.cntrct_id,
    vl.cntrct_line_nbr,
    vl.shipto_id,
    vl.tax_cd_sut,
    vl.wthd_cd,
    vl.sut_applicability,
    vl.receipt_dt,
    vl.qty_vchr,
    vl.unit_of_measure,
    vl.unit_price,
    vl.merchandise_amt,
    dl.operating_unit,
    dl.business_unit_gl,
    v.vendor_id,
    'PO-' || vl.po_id AS po_no
  FROM ps_voucher v
  JOIN po_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
  JOIN ps_voucher_line vl
    ON vl.business_unit = v.business_unit
   AND vl.voucher_id    = v.voucher_id
  JOIN included_goods_lines gl
    ON gl.business_unit = vl.business_unit_po
   AND gl.po_id         = vl.po_id
   AND gl.line_nbr      = vl.line_nbr
   AND gl.sched_nbr     = NVL(vl.sched_nbr, gl.sched_nbr)
  LEFT JOIN dl_pick dl
    ON dl.business_unit    = vl.business_unit
   AND dl.voucher_id       = vl.voucher_id
   AND dl.voucher_line_num = vl.voucher_line_num
  WHERE vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
),

SELECT
  b.voucher_id                                      AS "*No.",
  b.voucher_id || '-' || b.voucher_line_num         AS "*Invoice Line Replacement Data Line No",
  ' '                                               AS "Supplier Invoice Line ID",
  b.voucher_line_num                                AS "Line Order",
   x.bhxlat       AS "*Intercompany Affiliate",
  ' '                                               AS "Purchase Item",
  ' '                                               AS "Item Description",
  CASE
    WHEN b.po_no IS NOT NULL THEN b.po_no || '-' || TO_CHAR(b.line_nbr)
    ELSE ' '
  END                                               AS "Purchase Order Line",
  CASE
    WHEN TRIM(b.cntrct_id) IS NOT NULL AND TRIM(b.cntrct_id) <> ''
    THEN TO_CHAR(b.cntrct_line_nbr)
    ELSE ' '
  END                                               AS "Supplier Contract Line",
  ' '                                               AS "Customer Invoice Line",
  ' '                                               AS "Supplier Invoice Line to Adjust",
  ' '                                               AS "Spend Category",
  ' '                                               AS "Commodity Code",
  ' '                                               AS "Ship To Address",
  ' '                                               AS "Ship To Contact Worker Type",
  ' '                                               AS "Ship To Contact Worker ID",
  ' '                                               AS "Accounting Treatment",
  ' '                                               AS "Trackable Item",
  CASE WHEN b.taxable > 0 THEN 'Taxable' ELSE ' ' END AS "Tax Applicability",
  NVL(b.tax_cd_sut,' ')                             AS "Tax Code",
  NVL(b.wthd_cd,' ')                                AS "Withholding Tax Code",
  ' '                                               AS "Tax Point Date Type",
  ' '                                               AS "Tax Point Date",
  ' '                                               AS "Tax Rate 1",
  ' '                                               AS "Tax Recoverability 1",
  ' '                                               AS "Tax Option 1",
  ' '                                               AS "Tax Recoverability 2",
  ' '                                               AS "Tax Option 2",
  ' '                                               AS "Tax Recoverability 3",
  ' '                                               AS "Tax Option 3",
  ' '                                               AS "Tax Recoverability 4",
  ' '                                               AS "Tax Option 4",
  ' '                                               AS "Tax Recoverability 5",
  ' '                                               AS "Tax Option 5",
  ' '                                               AS "Tax Recoverability 6",
  ' '                                               AS "Tax Option 6",
  ' '                                               AS "Packaging String",
  b.qty_vchr                                        AS "Quantity",
  b.unit_of_measure                                 AS "Unit of Measure",
  b.unit_price                                      AS "Unit Cost",
  b.merchandise_amt                                 AS "Extended Amount",
  NULL                                              AS "Retention Amount",
  NULL                                              AS "Payment Amount",
  ' '                                               AS "Budget Date",
  CASE WHEN b.voucher_style = 'PPAY' THEN 'Y' ELSE 'N' END AS "Prepaid",
  NVL(b.cntrct_id,' ')                              AS "Supplier Contract",
  CASE
    WHEN b.receipt_dt IS NOT NULL THEN TO_CHAR(b.receipt_dt,'YYYY-MM-DD')
    ELSE ' '
  END                                               AS "Invoice Line Delivery Date",
  ' '                                               AS "Invoice Line Billing Start Date",
  ' '                                               AS "Invoice Line Billing End Date",
  NVL(NULLIF(TRIM(b.descr254_mixed),''), TRIM(b.descr)) AS "Memo",
  ' '                                               AS "Billable",
  ' '                                               AS "Worktag Split Template"
FROM base b
 JOIN ps_bh_wd_sup_1to1 wd ON b.vendor_id = wd.bh_wd_ps_vendor_id
LEFT JOIN shipto_setid_by_bu ss
  ON ss.business_unit_po = b.business_unit_po
LEFT JOIN shipto_ed st
  ON st.setid     = ss.shipto_setid
 AND st.shipto_id = b.shipto_id
 left join PS_BHXLATITEM x on x.fieldname='BH_WD_FDM_OU_COMP' and x.bhvalue=b.operating_unit
 --WHERE B.VOUCHER_ID='05323003'
ORDER BY b.voucher_id, b.voucher_line_num

