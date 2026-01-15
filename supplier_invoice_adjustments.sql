

WITH
shipto_setid_by_bu AS (
  SELECT /*+ MATERIALIZE */
    r.setcntrlvalue AS business_unit, 
    MAX(r.setid) AS shipto_setid
  FROM ps_set_cntrl_rec r
  WHERE r.recname = 'SHIPTO_TBL'
  GROUP BY r.setcntrlvalue
),
shipto_ed AS (
  SELECT /*+ MATERIALIZE */
    st.setid, st.shipto_id, st.descr
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

line_first AS (
  SELECT /*+ MATERIALIZE */
    vl.business_unit,
    vl.voucher_id,
    MAX(vl.tax_cd_sut) KEEP (DENSE_RANK FIRST ORDER BY vl.voucher_line_num) AS tax_cd_sut,
    MAX(vl.wthd_cd)    KEEP (DENSE_RANK FIRST ORDER BY vl.voucher_line_num) AS wthd_cd,
    MAX(vl.shipto_id)  KEEP (DENSE_RANK FIRST ORDER BY vl.voucher_line_num) AS shipto_id
  FROM ps_voucher_line vl
  GROUP BY vl.business_unit, vl.voucher_id
),

/* LISTAGG overflow protection: ON OVERFLOW TRUNCATE prevents ORA-01489 (requires Oracle 12.2+) */
po_list AS (
  SELECT business_unit, voucher_id,
         LISTAGG(po_id, ';' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) WITHIN GROUP (ORDER BY po_id) AS external_po_number
  FROM (
    SELECT DISTINCT business_unit, voucher_id, TRIM(po_id) AS po_id
    FROM ps_voucher_line
    WHERE TRIM(po_id) IS NOT NULL AND TRIM(po_id) <> ''
  )
  GROUP BY business_unit, voucher_id
),

/* LISTAGG overflow protection: ON OVERFLOW TRUNCATE prevents ORA-01489 (requires Oracle 12.2+) */
cntrct_list AS (
  SELECT business_unit, voucher_id,
         LISTAGG(cntrct_id, ';' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) WITHIN GROUP (ORDER BY cntrct_id) AS supplier_contract
  FROM (
    SELECT DISTINCT business_unit, voucher_id, TRIM(cntrct_id) AS cntrct_id
    FROM ps_voucher_line
    WHERE TRIM(cntrct_id) IS NOT NULL AND TRIM(cntrct_id) <> ''
  )
  GROUP BY business_unit, voucher_id
),

/* Memo safe-agg: no XMLCDATA to avoid ORA-19011 on '--' */
memo_agg AS (
  SELECT /*+ MATERIALIZE */
    vl.business_unit,
    vl.voucher_id,
    RTRIM(
      XMLCAST(
        XMLAGG(
          XMLELEMENT(
            e,
            REGEXP_REPLACE(
              REGEXP_REPLACE(NVL(TRIM(vl.descr254_mixed), TRIM(vl.descr)), '-{2,}', ' '),
              '\s+', ' '
            ) || ' | '
          )
          ORDER BY vl.voucher_line_num
        ).EXTRACT('//text()') AS CLOB
      ),
      ' | '
    ) AS document_memo
  FROM ps_voucher_line vl
  GROUP BY vl.business_unit, vl.voucher_id
),

wthd_sum AS (
  SELECT /*+ MATERIALIZE */
    w.business_unit, w.voucher_id, SUM(NVL(w.wthd_amt,0)) AS wthd_amt
  FROM ps_pymnt_vchr_wthd w
  GROUP BY w.business_unit, w.voucher_id
),

pymnt1 AS (
  SELECT /*+ MATERIALIZE */
    x.business_unit, x.voucher_id, x.pymnt_hold, x.pymnt_handling_cd
  FROM ps_pymnt_vchr_xref x
  WHERE x.pymnt_cnt = 1
)

SELECT
  /* keys / controls */
  v.voucher_id                                   AS "*No.",
  'Y'                                            AS "Add Only",
  ' '                                            AS "Supplier Invoice Adjustment Reference For Update",
  v.voucher_id                                   AS "Supplier Invoice Adjustment ID",
  'Y'                                            AS "Submit",
  ' '                                            AS "Locked in Workday",
  ' '                                            AS "Invoice Number",
  v.doc_seq_nbr                                  AS "Gapless Document Number",
  v.origin                                       AS "External Supplier Invoice Source",
  v.entry_status                                 AS "Invoice Document Status",
  ' '                                            AS "Invoice Cancel Reason",

  /* required header dims */
  v.business_unit_gl                             AS "*Company",
  ' '                                            AS "Payment Practices",
  v.txn_currency_cd                              AS "*Currency",
  v.vendor_id                                    AS "*Supplier",

  ' '                                            AS "Contingent Worker ID",
  ' '                                            AS "Supplier Connection",
  ' '                                            AS "Use Default Supplier Connection",

  /* required adjustment flags */
  CASE WHEN v.gross_amt >= 0 THEN 'Y' ELSE 'N' END AS "*Increase Liability",

  /* REQUIRED: you may need to map these to Workday allowed values */
  CASE
    WHEN v.gross_amt < 0 THEN 'Credit Adjustment'
    ELSE 'Debit Adjustment'
  END                                            AS "*Adjustment Reason",

  TO_CHAR(v.invoice_dt,'YYYY-MM-DD')             AS "*Adjustment Date",
  TO_CHAR(v.entered_dt,'YYYY-MM-DD')             AS "Adjustment Received Date",

  ' '                                            AS "Invoice Delivery Date",

  /* best-fit dates (optional) */
  TO_CHAR(v.perform_start_dt,'YYYY-MM-DD')       AS "Invoice Billing Start Date",
  TO_CHAR(v.perform_end_dt,'YYYY-MM-DD')         AS "Invoice Billing End Date",

  TO_CHAR(v.due_dt,'YYYY-MM-DD')                 AS "Due Date Override",
  TO_CHAR(v.accounting_dt,'YYYY-MM-DD')          AS "Accounting Date Override",
  TO_CHAR(v.accounting_dt,'YYYY-MM-DD')          AS "Invoice Accounting Date",
  ' '                                            AS "Cancel Accounting Date",
  ' '                                            AS "Budget Date",

  ' '                                            AS "Default Tax Option",

  /* ship-to + tax defaults from first voucher line */
  CASE
    WHEN lf.shipto_id IS NULL OR TRIM(lf.shipto_id) = '' THEN ' '
    WHEN st.descr IS NOT NULL THEN lf.shipto_id || ' - ' || st.descr
    ELSE lf.shipto_id
  END                                            AS "Ship-To Address",
  NVL(lf.shipto_id,' ')                          AS "Ship-To Address ID",
  NVL(lf.tax_cd_sut,' ')                         AS "Tax Code",
  NVL(lf.wthd_cd,' ')                            AS "Default Withholding Tax Code",

  /* amounts (use ABS so Workday can use Increase Liability flag) */
  ABS(v.gross_amt)                               AS "Control Total Amount",
  ABS( NVL(v.saletx_amt,0)
     + NVL(v.usetax_amt,0)
     + NVL(v.vat_inv_amt,0)
     + NVL(v.vat_noninv_amt,0)
  )                                              AS "Tax Amount",
  ABS(NVL(ws.wthd_amt,0))                        AS "Withholding Tax Amount",
  ABS(NVL(v.freight_amt,0))                      AS "Freight Amount",
  ABS(NVL(v.misc_amt,0))                         AS "Other Charges",

  ' '                                            AS "Worktag Split Template",

  /* original invoice linkage */
  NVL(v.voucher_id_related,' ')                  AS "Original Invoice",
  NVL(vo.invoice_id,' ')                         AS "Original Invoice Supplier Reference Number",

  v.pymnt_terms_cd                               AS "*Payment Terms",
  ABS(NVL(v.dscnt_amt,0))                        AS "Discount Amount Override",
  ' '                                            AS "Override Payment Type",
  ' '                                            AS "Additional Type",
  ' '                                            AS "Additional Reference Number",
  ' '                                            AS "Originating Country Payment Purpose",
  ' '                                            AS "Receiving Country Payment Purpose",

  NVL(p.pymnt_handling_cd,' ')                   AS "Handling Code",
  TO_CHAR(v.dscnt_due_dt,'YYYY-MM-DD')           AS "Discount Date",
  TO_CHAR(v.dscnt_due_dt,'YYYY-MM-DD')           AS "Discount Date Override",
  ' '                                            AS "Discount Taken",
  ' '                                            AS "Discounts Not Taken",

  NVL(p.pymnt_hold,'N')                          AS "On Hold",

  ' '                                            AS "Supplier Document Received",
  v.invoice_id                                   AS "Suppliers Invoice Number",

  NVL(pl.external_po_number,' ')                 AS "External PO Number",
  NVL(cl.supplier_contract,' ')                  AS "Supplier Contract",

  ' '                                            AS "Document Link",
  ' '                                            AS "Statutory Invoice Type",
  NVL(ma.document_memo,' ')                      AS "Document Memo",
  ' '                                            AS "Approver Is Employee",
  ' '                                            AS "Approver Worker ID",

  /* currency rate fields (best-effort) */
  v.rt_type                                      AS "Currency Rate Type Override",
  TO_CHAR(v.accounting_dt,'YYYY-MM-DD')          AS "Currency Rate Date Override",
  ' '                                            AS "Currency Rate Manual Override",

  CASE WHEN NVL(v.rate_div,0) <> 0 THEN (v.rate_mult / v.rate_div) ELSE NULL END
                                                 AS "Document Currency Conversion Rate",

  ' '                                            AS "Rate Override",
  ' '                                            AS "Currency Rate Lookup Override",
  ' '                                            AS "Manual Override Percent",
  TO_CHAR(v.accounting_dt,'YYYY-MM-DD')          AS "Rate Basis Date",

  CASE WHEN NVL(v.rate_div,0) <> 0 THEN (v.rate_mult / v.rate_div) ELSE NULL END
                                                 AS "Default Currency Rate"

FROM ps_voucher v
LEFT JOIN ps_voucher vo
  ON vo.business_unit = v.business_unit
 AND vo.voucher_id    = v.voucher_id_related

LEFT JOIN line_first lf
  ON lf.business_unit = v.business_unit
 AND lf.voucher_id    = v.voucher_id

LEFT JOIN shipto_setid_by_bu sb
  ON sb.business_unit = v.business_unit
LEFT JOIN shipto_ed st
  ON st.setid     = sb.shipto_setid
 AND st.shipto_id = lf.shipto_id

LEFT JOIN wthd_sum ws
  ON ws.business_unit = v.business_unit
 AND ws.voucher_id    = v.voucher_id

LEFT JOIN pymnt1 p
  ON p.business_unit = v.business_unit
 AND p.voucher_id    = v.voucher_id

LEFT JOIN po_list pl
  ON pl.business_unit = v.business_unit
 AND pl.voucher_id    = v.voucher_id

LEFT JOIN cntrct_list cl
  ON cl.business_unit = v.business_unit
 AND cl.voucher_id    = v.voucher_id

LEFT JOIN memo_agg ma
  ON ma.business_unit = v.business_unit
 AND ma.voucher_id    = v.voucher_id

WHERE v.voucher_style = 'ADJ'
  AND v.entry_status <> 'X'
ORDER BY v.voucher_id;
