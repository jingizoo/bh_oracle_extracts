WITH
params AS (
  SELECT TRUNC(to_date('01-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('01-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),
shipto_setid_by_bu AS (
    SELECT /*+ MATERIALIZE */
        r.setcntrlvalue AS business_unit,
        MAX(r.setid) AS shipto_setid
    FROM ps_set_cntrl_rec r
    WHERE r.recname = 'SHIPTO_TBL'
    GROUP BY r.setcntrlvalue
),
/* LISTAGG overflow protection: ON OVERFLOW TRUNCATE prevents ORA-01489 (requires Oracle 12.2+) */
po_list AS (
    SELECT
        business_unit,
        voucher_id,
        LISTAGG(po_id, ';' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) WITHIN GROUP (ORDER BY po_id) AS external_po_number
    FROM (
        SELECT DISTINCT
            business_unit,
            voucher_id,
            TRIM(po_id) AS po_id
        FROM ps_voucher_line
        WHERE TRIM(po_id) IS NOT NULL
          AND TRIM(po_id) <> ''
    )
    GROUP BY business_unit, voucher_id
),

/*Voucher List*/
vchr_list as (
select distinct v.*
FROM ps_voucher v
JOIN params p
  ON 1=1
JOIN ps_bh_wd_sup_1to1 wd
  ON v.vendor_id = wd.bh_wd_ps_vendor_id
JOIN ps_voucher_line vl
  ON vl.business_unit = v.business_unit
 AND vl.voucher_id    = v.voucher_id
WHERE v.gross_amt < 0 and v.voucher_style<>'JRNL' and v.origin <> 'FAV'
  AND v.appr_status = 'A'
  AND v.entry_status <> 'X'
  AND v.close_status <> 'C'
  AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt
AND vl.merchandise_amt <>0
),

/* Paid negative amount vouchers (restricted to candidates; avoids full scan of xref) */
paid_zero_amt_xref AS (
    SELECT /*+ MATERIALIZE */
           px.business_unit,
           px.voucher_id
    FROM ps_pymnt_vchr_xref px
    JOIN vchr_list vc
      ON vc.business_unit = px.business_unit
     AND vc.voucher_id   = px.voucher_id
    WHERE px.pymnt_action <> 'X'
    GROUP BY px.business_unit, px.voucher_id
    HAVING
        SUM(CASE WHEN px.pymnt_selct_status <> 'P' THEN 1 ELSE 0 END) = 0
    AND SUM(CASE WHEN px.paid_amt < 0 THEN 1 ELSE 0 END) > 0
),

/* AT THIS POINT WE EXCLUDE THE PAID VOUCHERS*/

vchr_base AS (
  SELECT pv.*
  FROM vchr_list pv
  WHERE  NOT EXISTS (
      SELECT 1 FROM paid_zero_amt_xref px1
      WHERE px1.business_unit = pv.business_unit
        AND px1.voucher_id    = pv.voucher_id
    )
)


SELECT
    v.voucher_id         AS "*No.",
    'Y'                  AS "Add Only",
    ' '                  AS "Supplier Invoice Adjustment Reference For Update",
    ' '                  AS "Supplier Invoice Adjustment ID",
    'Y'                  AS "Submit",
    ' '                  AS "Locked in Workday",
    ' '                  AS "Invoice Number",
    ' '                  AS "Gapless Document Number",
    ' '                  AS "External Supplier Invoice Source",
    'Approved'           AS "Invoice Document Status",
    ' '                  AS "Invoice Cancel Reason",

    v.business_unit_gl   AS "*Company",
    ' '                  AS "Payment Practices",
    v.txn_currency_cd    AS "*Currency",
    wd.bh_wd_supplier_id AS "*Supplier",
    ' '                  AS "Contingent Worker ID",
    ' '                  AS "Supplier Connection",
    ' '                  AS "Use Default Supplier Connection",

    'N'                  AS "*Increase Liability",
    'Conversion Credit Memo' AS "*Adjustment Reason",

    TO_CHAR(v.invoice_dt, 'YYYY-MM-DD') AS "*Adjustment Date",
    TO_CHAR(v.entered_dt, 'YYYY-MM-DD') AS "Adjustment Received Date",
    ' '                  AS "Invoice Delivery Date",

    ' '                  AS "Invoice Billing Start Date",
    ' '                  AS "Invoice Billing End Date",
    ' '                  AS "Due Date Override",
    ' '                  AS "Accounting Date Override",
    ' '                  AS "Invoice Accounting Date",
    ' '                  AS "Cancel Accounting Date",
    ' '                  AS "Budget Date",
    ' '                  AS "Default Tax Option",

    ' '                  AS "Ship-To Address",
    ' '                  AS "Ship-To Address ID",
    ' '                  AS "Tax Code",
    ' '                  AS "Default Withholding Tax Code",

    ' '                  AS "Control Total Amount",
    ' '                  AS "Tax Amount",
    ' '                  AS "Withholding Tax Amount",
    abs(v.freight_amt)                  AS "Freight Amount",
    ' '                  AS "Other Charges",
    ' '                  AS "Worktag Split Template",

    v.invoice_id	 AS "Original Invoice",
    ' '                  AS "Original Invoice Supplier Reference Number",

    'Immediate'          AS "*Payment Terms",
    ' '                  AS "Discount Amount Override",
    ' '                  AS "Override Payment Type",
    ' '                  AS "Additional Type",
    ' '                  AS "Additional Reference Number",
    ' '                  AS "Originating Country Payment Purpose",
    ' '                  AS "Receiving Country Payment Purpose",

    ' '                  AS "Handling Code",
    ' '                  AS "Discount Date",
    ' '                  AS "Discount Date Override",
    ' '                  AS "Discount Taken",
    ' '                  AS "Discounts Not Taken",
    ' '                  AS "On Hold",
    ' '                  AS "Supplier Document Received",

    v.invoice_id         AS "Suppliers Invoice Number",
    NVL(pl.external_po_number, ' ') AS "External PO Number",

    ' '                  AS "Supplier Contract",
    ' '                  AS "Document Link",
    ' '                  AS "Statutory Invoice Type",
    ' '                  AS "Document Memo",
    ' '                  AS "Approver Is Employee",
    ' '                  AS "Approver Worker ID",

    ' '                  AS "Currency Rate Type Override",
    ' '                  AS "Currency Rate Date Override",
    ' '                  AS "Currency Rate Manual Override",
    ' '                  AS "Document Currency Conversion Rate",
    ' '                  AS "Rate Override",
    ' '                  AS "Currency Rate Lookup Override",
    ' '                  AS "Manual Override Percent",
    ' '                  AS "Rate Basis Date",
    ' '                  AS "Default Currency Rate"

FROM vchr_base v
JOIN params p
  ON 1=1
LEFT JOIN po_list pl
  ON pl.business_unit = v.business_unit
 AND pl.voucher_id    = v.voucher_id
LEFT JOIN ps_bh_wd_sup_1to1 wd
  ON v.vendor_id = wd.bh_wd_ps_vendor_id

WHERE v.gross_amt < 0 and v.voucher_style<>'JRNL' and v.origin <> 'FAV'
  AND v.entry_status <> 'X'
  AND v.close_status <> 'C'
  AND TRUNC(NVL(v.invoice_dt, v.entered_dt)) BETWEEN p.lookback_dt AND p.asof_dt

ORDER BY v.voucher_id
