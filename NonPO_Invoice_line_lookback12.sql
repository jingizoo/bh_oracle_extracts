/* ============================================================================
   Workday EIB – Non‑PO Invoice Lines – 12‑month lookback
   Slide alignment:
   - Non‑PO invoices: convert approved/unpaid invoice lines within last 12 months
   - Exclude any voucher that has PO on ANY voucher line
   - Exclude adjustments
   ============================================================================ */

WITH
params AS (
  SELECT TRUNC(SYSDATE) AS asof_dt,
         ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

nonpo_vouchers AS (
  SELECT /*+ MATERIALIZE */ v.business_unit, v.voucher_id
  FROM ps_voucher v
  JOIN params p ON 1=1
  WHERE v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND v.voucher_style <> 'ADJ'
    AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
    AND NVL(v.po_id,' ') = ' '
    AND NOT EXISTS (
      SELECT 1
      FROM ps_voucher_line vlx
      WHERE vlx.business_unit = v.business_unit
        AND vlx.voucher_id    = v.voucher_id
        AND vlx.po_id IS NOT NULL
        AND vlx.po_id <> ' '
    )
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
    vl.merchandise_amt
  FROM ps_voucher v
  JOIN nonpo_vouchers nv
    ON nv.business_unit = v.business_unit
   AND nv.voucher_id    = v.voucher_id
  JOIN ps_voucher_line vl
    ON vl.business_unit = v.business_unit
   AND vl.voucher_id    = v.voucher_id
  WHERE NVL(vl.po_id,' ') = ' '
)

SELECT
  b.voucher_id                                      AS "*No.",
  b.voucher_id || '-' || b.voucher_line_num         AS "*Invoice Line Replacement Data Line No",
  ' '                                               AS "Supplier Invoice Line ID",
  b.voucher_line_num                                AS "Line Order",
  'operating unit that maps to Company in WD'       AS "*Intercompany Affiliate",
  ' '                                               AS "Purchase Item",
  NVL(NULLIF(TRIM(b.descr254_mixed),''), TRIM(b.descr)) AS "Item Description",
  ' '                                               AS "Purchase Order Line",
  CASE
    WHEN TRIM(b.cntrct_id) IS NOT NULL AND TRIM(b.cntrct_id) <> ''
    THEN TO_CHAR(b.cntrct_line_nbr)
    ELSE ' '
  END                                               AS "Supplier Contract Line",
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
LEFT JOIN shipto_setid_by_bu ss
  ON ss.business_unit_po = b.business_unit_po
LEFT JOIN shipto_ed st
  ON st.setid     = ss.shipto_setid
 AND st.shipto_id = b.shipto_id
ORDER BY b.voucher_id, b.voucher_line_num
;
