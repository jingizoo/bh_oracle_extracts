/* Workday EIB – Non-PO Invoice Lines – approved + unpaid + 12‑month lookback
   Output unchanged vs your current file.
*/

/* High‑level logic:
   - Select approved, open, non‑journal vouchers from the last ~12 months.
   - Exclude vouchers that: have any PO lines, are already fully paid (or zero‑paid but selected for payment),
     or are in excluded departments (for example, department 99999).
   - For the remaining non‑PO vouchers, take each invoice line and pick a single “best” accounting distribution
     (company / operating unit / department) to drive Workday worktags.
   - Output one row per invoice line in the exact Workday “Non‑PO Invoice Line Replacement Data” EIB column layout. */
WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

/* 1) Voucher candidates (date filter without TRUNC; same result set) */
voucher_candidates AS (
  SELECT /*+ MATERIALIZE */
         v.business_unit,
         v.voucher_id,
         v.vendor_id,
         v.vendor_setid,
         v.business_unit_gl,
         v.txn_currency_cd,
         v.invoice_dt,
         v.entered_dt,
         v.due_dt,
         v.saletx_amt,
         v.usetax_amt,
         v.vat_inv_amt,
         v.vat_noninv_amt,
         v.freight_amt,
         v.misc_amt,
         v.invoice_id,
         v.po_id,
         v.cntrct_id,
         v.pymnt_terms_cd,
         v.voucher_style,
         v.prepaid_ref
  FROM ps_voucher v
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND v.voucher_style <> 'ADJ' -- AND V.VOUCHER_ID='05312504'
    AND v.appr_status = 'A'
    AND v.voucher_style<>'JRNL'
    AND NVL(v.invoice_dt, v.entered_dt) >= p.lookback_dt
    AND NVL(v.invoice_dt, v.entered_dt) <  (p.asof_dt + 1)
    AND NVL(v.po_id,' ') = ' '              -- Non-PO header PO blank
),

/* 2) Vouchers that have ANY PO on ANY voucher line (restricted) */
has_po_line AS (
  SELECT /*+ MATERIALIZE */ DISTINCT vl.business_unit, vl.voucher_id
  FROM ps_voucher_line vl
  JOIN voucher_candidates vc
    ON vc.business_unit = vl.business_unit
   AND vc.voucher_id    = vl.voucher_id
  WHERE vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
),

/* 3) Paid vouchers (restricted to candidates; avoids full scan of xref) */
paid_xref AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN voucher_candidates vc
    ON vc.business_unit = px.business_unit
   AND vc.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND ABS(NVL(px.paid_amt,0)) > 0
),

/* 3) Paid zero amount vouchers (restricted to candidates; avoids full scan of xref) */
paid_zero_amt_xref AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN voucher_candidates vc
    ON vc.business_unit = px.business_unit
   AND vc.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND ABS(NVL(px.paid_amt,0)) = 0 and pymnt_selct_status='P'
),

/*exclude vouchers having department =99999*/
exclude_dept AS (
  SELECT DISTINCT
         d.business_unit,
         d.voucher_id
  FROM ps_distrib_line d
  JOIN voucher_candidates vc
    ON vc.business_unit = d.business_unit
   AND vc.voucher_id    = d.voucher_id
  JOIN ps_voucher_line k
    ON k.business_unit     = d.business_unit
   AND k.voucher_id        = d.voucher_id
   AND k.voucher_line_num  = d.voucher_line_num
  WHERE d.deptid = '99999'
),

/* 4) Final drive set: approved + unpaid + nonpo (no PO lines) */
nonpo_vouchers AS (
  SELECT /*+ MATERIALIZE */ vc.*
  FROM voucher_candidates vc
  LEFT JOIN has_po_line hp
    ON hp.business_unit = vc.business_unit
   AND hp.voucher_id    = vc.voucher_id
  LEFT JOIN paid_xref px
    ON px.business_unit = vc.business_unit
   AND px.voucher_id    = vc.voucher_id
    left join paid_zero_amt_xref npx
    ON npx.business_unit = vc.business_unit
   AND npx.voucher_id    = vc.voucher_id
  LEFT JOIN exclude_dept DL
   ON DL.business_unit = vc.business_unit
   AND DL.voucher_id    = vc.voucher_id
  WHERE hp.voucher_id IS NULL          -- exclude any voucher with PO on any line
    AND px.voucher_id IS NULL          -- unpaid
    AND npx.voucher_id IS NULL          -- unpaid
    AND DL.voucher_id IS NULL          -- Exclude deptid = '99999' vouchers
),

/* 5) Voucher lines to output (NonPO lines only) */
vl_keys AS (
  SELECT /*+ MATERIALIZE */ DISTINCT
         vl.business_unit,
         vl.voucher_id,
         vl.voucher_line_num
  FROM ps_voucher_line vl
  JOIN nonpo_vouchers v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  WHERE NVL(vl.po_id,' ') = ' '        -- NonPO line
),

/* 6) Pick distrib_line once per voucher line (same ordering as your KEEP...) */
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
        ORDER BY
          CASE WHEN d.business_unit_gl = vh.business_unit_gl THEN 0 ELSE 1 END,
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

/* 7) Base rows (same columns as your base CTE) */
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
    v.vendor_id
  FROM nonpo_vouchers v
  JOIN ps_voucher_line vl
    ON vl.business_unit = v.business_unit
   AND vl.voucher_id    = v.voucher_id
  LEFT JOIN dl_pick dl
    ON dl.business_unit    = vl.business_unit
   AND dl.voucher_id       = vl.voucher_id
   AND dl.voucher_line_num = vl.voucher_line_num
  WHERE NVL(vl.po_id,' ') = ' '
),

/* 8) De-dupe OU->Company xlat to avoid accidental dup joins */
ou_comp_xlat AS (
  SELECT bhvalue, MAX(bhxlat) AS bhxlat
  FROM PS_BHXLATITEM
  WHERE fieldname = 'BH_WD_FDM_OU_COMP'
  GROUP BY bhvalue
)

SELECT
  b.voucher_id                                      AS "*No.",
  b.voucher_id || '-' || b.voucher_line_num         AS "*Invoice Line Replacement Data Line No",
  ' '                                               AS "Supplier Invoice Line ID",
  b.voucher_line_num                                AS "Line Order",
  x.bhxlat                                          AS "*Intercompany Affiliate",
  ' '                                               AS "Purchase Item",
  NVL(NULLIF(TRIM(b.descr254_mixed),''), TRIM(b.descr)) AS "Item Description",
  ' '                                               AS "Purchase Order Line",
  ' '                                               AS "Supplier Contract Line",
  ' '                                               AS "Customer Invoice Line",
  ' '                                               AS "Supplier Invoice Line to Adjust",
  'Conversion'                                      AS "Spend Category",
  ' '                                               AS "Commodity Code",
  ' '                                               AS "Ship To Address",
  ' '                                               AS "Ship To Contact Worker Type",
  ' '                                               AS "Ship To Contact Worker ID",
  ' '                                               AS "Accounting Treatment",
  ' '                                               AS "Trackable Item",
  CASE WHEN b.taxable > 0 THEN 'Taxable' ELSE ' ' END AS "Tax Applicability",
  ' '                                               AS "Tax Code",
  ' '                                               AS "Withholding Tax Code",
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
  ' '                                               AS "Supplier Contract",
  CASE WHEN b.receipt_dt IS NOT NULL THEN TO_CHAR(b.receipt_dt,'YYYY-MM-DD') ELSE ' ' END AS "Invoice Line Delivery Date",
  ' '                                               AS "Invoice Line Billing Start Date",
  ' '                                               AS "Invoice Line Billing End Date",
  NVL(NULLIF(TRIM(b.descr254_mixed),''), TRIM(b.descr)) AS "Memo",
  ' '                                               AS "Billable",
  ' '                                               AS "Worktag Split Template"
FROM base b
JOIN ps_bh_wd_sup_1to1 wd
  ON b.vendor_id = wd.bh_wd_ps_vendor_id
LEFT JOIN ou_comp_xlat x
  ON x.bhvalue = b.operating_unit
ORDER BY b.voucher_id, b.voucher_line_num