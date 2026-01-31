WITH
params AS (
  SELECT TRUNC(DATE '2026-01-15') AS asof_dt,
         ADD_MONTHS(TRUNC(DATE '2026-01-15'), -12) AS lookback_dt
  FROM dual
),

-- First, let's get all the PO headers that could potentially be included
-- We filter out cancelled/closed POs and exclude a specific vendor
hdr_candidates AS (
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

-- Get the list of vouchers that have actually been paid
-- Using the payment voucher xref table to find ones with paid amounts
paid_vouchers AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  WHERE px.pymnt_action <> 'X'
    AND NVL(px.paid_amt,0) > 0
),

-- Sum up how much has been vouchered/paid for each PO line and schedule
-- Only counting matched vouchers that have been paid, up to our as-of date
vchr_sum_match AS (
  SELECT
      vl.business_unit_po AS business_unit,
      vl.po_id,
      vl.line_nbr,
      NVL(vl.sched_nbr,1) AS sched_nbr,
      SUM(NVL(vl.merchandise_amt,0)) AS merch_amt_vchr,
      SUM(NVL(vl.qty_vchr,0))        AS qty_vchr
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  JOIN paid_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
  JOIN hdr_candidates hc
    ON hc.business_unit = vl.business_unit_po
   AND hc.po_id         = vl.po_id
  CROSS JOIN params p
  WHERE v.entry_status <> 'X'
    AND v.match_status_vchr = 'M'
    AND vl.po_id IS NOT NULL
    AND vl.po_id <> ' '
    AND NVL(v.invoice_dt, v.entered_dt) < (p.asof_dt + 1)
  GROUP BY vl.business_unit_po, vl.po_id, vl.line_nbr, NVL(vl.sched_nbr,1)
),

-- Grab some flags from the PO line table that we'll need later
-- These tell us if receiving is required and if it's amount-only
po_line_flags AS (
  SELECT l.business_unit,
         l.po_id,
         l.line_nbr,
         NVL(l.recv_req,'Y')     AS recv_req,
         NVL(l.amt_only_flg,'N') AS amt_only_flg
  FROM ps_po_line l
  JOIN hdr_candidates hc
    ON hc.business_unit = l.business_unit
   AND hc.po_id         = l.po_id
),

-- Figure out which schedules are still "open" (not fully received/paid)
-- Using a $1 tolerance so tiny rounding differences don't keep things open
sched_open AS (
  SELECT
      s.business_unit,
      s.po_id,
      s.line_nbr,
      s.sched_nbr,
      s.cancel_status,
      lf.recv_req,
      lf.amt_only_flg,
      s.qty_po,
      s.price_po,
      NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) AS sched_amt,
      NVL(vs.merch_amt_vchr,0) AS merch_amt_vchr,
      NVL(vs.qty_vchr,0)       AS qty_vchr,
      CASE
        WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
        WHEN lf.amt_only_flg = 'Y' THEN
          CASE WHEN GREATEST(NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0),0) > 1 THEN 1 ELSE 0 END
        WHEN lf.recv_req = 'Y' THEN
          CASE WHEN NVL(s.qty_po,0) > NVL(vs.qty_vchr,0) THEN 1 ELSE 0 END
        ELSE
          CASE WHEN GREATEST(NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0),0) > 1 THEN 1 ELSE 0 END
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

-- A PO is eligible if it has at least one open schedule AND the line and distrib are active
-- This is basically checking that all the pieces are in place
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

-- Final list of POs we actually want to include
-- Must be within the lookback period, have open eligible items, have a Workday vendor mapping, and be a valid BU
included_po AS (
  SELECT /*+ MATERIALIZE */ DISTINCT hc.business_unit, hc.po_id
  FROM hdr_candidates hc
  CROSS JOIN params p
  WHERE hc.po_dt >= p.lookback_dt
    AND EXISTS (SELECT 1 FROM open_po_eligible ope
                WHERE ope.business_unit = hc.business_unit AND ope.po_id = hc.po_id)
    AND EXISTS (SELECT 1 FROM ps_bh_wd_sup_1to1 wd
                WHERE wd.bh_wd_ps_vendor_id = hc.vendor_id)
    AND EXISTS (SELECT 1 FROM ps_bus_unit_tbl_pm bu
                WHERE bu.business_unit = hc.business_unit)
),

-- Now aggregate the contract lines from our included POs
-- We're looking for prepaid amortization contracts and summing up the remaining open amounts
prepaid_lines AS (
  SELECT
      l.cntrct_id,
      NVL(l.cntrct_line_nbr, 1) AS cntrct_line_nbr,

      -- Try to get a good description - use descr254_mixed2 if available, otherwise fall back to descr254_mixed
      MAX(NVL(NULLIF(TRIM(l.descr254_mixed2),''), l.descr254_mixed)) AS line_descr,

      -- Calculate the remaining open amount (what's left after vouchers)
      -- Same logic we used to determine if something is "open"
      SUM(
        CASE
          WHEN GREATEST( NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0), 0 ) > 1
          THEN GREATEST( NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0), 0 )
          ELSE 0
        END
      ) AS extended_amt,

      -- Use the earliest and latest PO dates as the contract line date range
      MIN(h.po_dt) AS start_dt,
      MAX(h.po_dt) AS end_dt,

      -- Try to pick a location from the distribution lines (just grab the first one we find)
      MAX(d.location) KEEP (DENSE_RANK FIRST ORDER BY d.distrib_line_num) AS location

  FROM included_po ip
  JOIN ps_po_hdr h
    ON h.business_unit = ip.business_unit
   AND h.po_id         = ip.po_id
  JOIN ps_po_line l
    ON l.business_unit = h.business_unit
   AND l.po_id         = h.po_id
  JOIN ps_cntrct_hdr cnt
    ON cnt.setid = 'SHARE'
   AND cnt.cntrct_id = l.cntrct_id
   AND cnt.cntrct_style = 'PPD_AMORT'

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

  LEFT JOIN vchr_sum_match vs
    ON vs.business_unit = s.business_unit
   AND vs.po_id         = s.po_id
   AND vs.line_nbr      = s.line_nbr
   AND vs.sched_nbr     = s.sched_nbr

  LEFT JOIN ps_po_line_distrib d
    ON d.business_unit = s.business_unit
   AND d.po_id         = s.po_id
   AND d.line_nbr      = s.line_nbr
   AND d.sched_nbr     = s.sched_nbr
   AND d.distrib_ln_status <> 'X'

  WHERE l.cntrct_id IS NOT NULL
    AND NVL(TRIM(l.cntrct_id),'') <> ''
    AND l.cancel_status <> 'X'
  GROUP BY l.cntrct_id, NVL(l.cntrct_line_nbr,1)
  HAVING SUM(
           CASE
             WHEN GREATEST( NVL(s.merchandise_amt, NVL(s.qty_po,0)*NVL(s.price_po,0)) - NVL(vs.merch_amt_vchr,0), 0 ) > 1
             THEN 1 ELSE 0
           END
         ) > 0
)

SELECT
  pl.cntrct_id AS "No",
  pl.cntrct_id || '-' || TO_CHAR(pl.cntrct_line_nbr) AS "Service_Lines_Replacement_Data_Line_No",
  pl.cntrct_line_nbr AS "Line_Number",
  'CO_80800' AS "Company_for_Invoices",
  ' ' AS "Line_On_Hold",
  ' ' AS "Item",
  pl.line_descr AS "Description",
  ' ' AS "Spend_Category",
  ' ' AS "Tax_Applicability",
  ' ' AS "Tax_Code",
  ' ' AS "Tax_Rate_1",
  ' ' AS "Tax_Recoverability_1",
  ' ' AS "Tax_Option_1",
  ' ' AS "Tax_Recoverability_2",
  ' ' AS "Tax_Option_2",
  ' ' AS "Tax_Recoverability_3",
  ' ' AS "Tax_Option_3",
  ' ' AS "Tax_Recoverability_4",
  ' ' AS "Tax_Option_4",
  ' ' AS "Tax_Recoverability_5",
  ' ' AS "Tax_Option_5",
  ' ' AS "Tax_Recoverability_6",
  ' ' AS "Tax_Option_6",
  pl.extended_amt AS "Extended_Amount",
  ' ' AS "Minimum_Charge_Control_Amount",
  ' ' AS "Maximum_Charge_Control_Amount",
  TO_CHAR(pl.start_dt,'YYYY-MM-DD') AS "Start_Date",
  TO_CHAR(pl.end_dt,'YYYY-MM-DD') AS "End_Date",
  ' ' AS "Do_Not_AutoRenew",
  ' ' AS "Renewal_Amount",
  ' ' AS "Renewal_Quantity",
  ' ' AS "Renews_Line_Number",
  ' ' AS "Renewed_By_Line_Number",
  ' ' AS "Retention",
  ' ' AS "Ship_To_Address",
  ' ' AS "Ship_To_Contact_Is_Employee",
  ' ' AS "Ship_To_Contact_ID",
  pl.cntrct_id AS "Memo",
  NVL(pl.location,' ') AS "Location"
FROM prepaid_lines pl
ORDER BY pl.cntrct_id, pl.cntrct_line_nbr;
