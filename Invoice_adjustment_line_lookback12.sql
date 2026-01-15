/* ============================================================================
   Workday EIB – Supplier Invoice Adjustment LINES (Invoice Line Replacement Data)
   Update for slide criteria:
   - ONLY adjustment vouchers in last 12 months
   - ONLY open/not-cancelled vouchers
   - Lines driven from PS_VOUCHER_LINE for those vouchers
   ============================================================================
   Criteria:
     v.voucher_style = 'ADJ'
     v.entry_status <> 'X'
     v.close_status <> 'C'
     TRUNC(NVL(v.invoice_dt, v.entered_dt)) between lookback_dt and asof_dt
   ============================================================================ */

WITH
params AS (
  SELECT
    TRUNC(SYSDATE)                  AS asof_dt,
    ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

voucher_base AS (
  SELECT /*+ MATERIALIZE */
      v.business_unit,
      v.voucher_id
  FROM ps_voucher v
  JOIN params p
    ON 1=1
  WHERE v.voucher_style = 'ADJ'
    AND v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
),

/* Optional: PO list if you later decide to populate PO-related columns */
po_list AS (
  SELECT
      vl.business_unit,
      vl.voucher_id,
      LISTAGG(TRIM(vl.po_id), ';' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT)
        WITHIN GROUP (ORDER BY TRIM(vl.po_id)) AS external_po_number
  FROM ps_voucher_line vl
  WHERE EXISTS (
    SELECT 1
    FROM voucher_base vb
    WHERE vb.business_unit = vl.business_unit
      AND vb.voucher_id    = vl.voucher_id
  )
    AND TRIM(vl.po_id) IS NOT NULL
    AND TRIM(vl.po_id) <> ''
  GROUP BY vl.business_unit, vl.voucher_id
)

SELECT
    /* Keys */
    v.voucher_id                                      AS "*No.",
    vl.voucher_line_num                               AS "*Invoice Line Replacement Data Line No",
    v.voucher_id || '-' || TO_CHAR(vl.voucher_line_num) AS "Supplier Invoice Line ID",
    vl.voucher_line_num                               AS "Line Order",

    /* Required (per your template) – keep as your xwalk placeholder */
    'xwalk'                                           AS "*Intercompany Affiliate",

    /* Line attributes */
    ' '                                               AS "Purchase Item",
    /* You can populate this with NVL(vl.descr254_mixed, vl.descr) if desired */
    ' '                                               AS "Item Description",
    ' '                                               AS "Purchase Order Line",
    ' '                                               AS "Supplier Contract Line",
    ' '                                               AS "Customer Invoice Line",
    ' '                                               AS "Supplier Invoice Line to Adjust",

    /* Required Spend Category (per your prior file) */
    'Conversion'                                      AS "*Spend Category",

    ' '                                               AS "Commodity Code",
    ' '                                               AS "Ship To Address",
    ' '                                               AS "Ship To Contact Is Employee",
    ' '                                               AS "Ship To Contact Worker ID",
    ' '                                               AS "Accounting Treatment",
    ' '                                               AS "Trackable Item",

    ' '                                               AS "Tax Applicability",
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

    /* Quantities/pricing not used for these adjustments in your template */
    ' '                                               AS "Quantity",
    ' '                                               AS "Unit of Measure",
    ' '                                               AS "Unit Cost",

    /* Amount – keep signed amount as stored on the voucher line */
    vl.merchandise_amt                                AS "Extended Amount",

    ' '                                               AS "Retention Amount",
    ' '                                               AS "Payment Amount",
    ' '                                               AS "Budget Date",
    ' '                                               AS "Prepaid",
    ' '                                               AS "Supplier Contract",

    ' '                                               AS "Invoice Line Delivery Date",
    ' '                                               AS "Invoice Line Billing Start Date",
    ' '                                               AS "Invoice Line Billing End Date",

    /* Memo – keep blank per prior file; can also use line description */
    ' '                                               AS "Memo",

    ' '                                               AS "Billable",
    ' '                                               AS "Worktag Split Template"

FROM voucher_base vb
JOIN ps_voucher v
  ON v.business_unit = vb.business_unit
 AND v.voucher_id    = vb.voucher_id
JOIN ps_voucher_line vl
  ON vl.business_unit = v.business_unit
 AND vl.voucher_id    = v.voucher_id
LEFT JOIN po_list pl
  ON pl.business_unit = v.business_unit
 AND pl.voucher_id    = v.voucher_id

ORDER BY v.voucher_id, vl.voucher_line_num;
