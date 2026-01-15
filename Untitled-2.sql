/* Workday EIB – Supplier Contract Line (Service Lines Replacement Data)
   Output columns per Supplier Contract Line.txt :contentReference[oaicite:3]{index=3}

   Sources (verified):
   - PS_CNTRCT_LINE: CNTRCT_ID, VERSION_NBR, CNTRCT_LINE_NBR, LINE_STATUS, INV_ITEM_ID,
                     DESCR254_MIXED, CATEGORY_ID, TAX_CD, MERCHANDISE_AMT,
                     AMT_LINE_MIN, AMT_LINE_MAX, INCLUDE_FOR_RELS :contentReference[oaicite:4]{index=4}
   - PS_CNTRCT_RLS_HDR: BUSINESS_UNIT, TRANS_DATE, SEQ_NUM, BILL_LOCATION :contentReference[oaicite:5]{index=5}
*/

WITH
/* pick latest release header row per contract (used for Company for Invoices + Location) */
rls_latest AS (
  SELECT *
  FROM (
    SELECT
      r.setid,
      r.cntrct_id,
      r.business_unit,
      r.bill_location,
      r.trans_date,
      r.seq_num,
      ROW_NUMBER() OVER (
        PARTITION BY r.setid, r.cntrct_id
        ORDER BY NVL(r.trans_date, DATE '1900-01-01') DESC, r.seq_num DESC
      ) AS rn
    FROM ps_cntrct_rls_hdr r
  )
  WHERE rn = 1
),

/* choose “current” contract version as the max VERSION_NBR per contract */
line_cur_ver AS (
  SELECT
    cl.*,
    MAX(cl.version_nbr) OVER (PARTITION BY cl.setid, cl.cntrct_id) AS max_version_nbr
  FROM ps_cntrct_line cl
),

base AS (
  SELECT
    cl.setid,
    cl.cntrct_id,
    cl.version_nbr,
    cl.cntrct_line_nbr,
    cl.line_status,
    cl.inv_item_id,
    cl.descr254_mixed,
    cl.category_id,
    cl.tax_cd,
    cl.merchandise_amt,
    cl.amt_line_min,
    cl.amt_line_max
  FROM line_cur_ver cl
  WHERE cl.version_nbr = cl.max_version_nbr
    AND cl.include_for_rels = 'Y'
    AND cl.line_status <> 'C'   -- exclude cancelled lines :contentReference[oaicite:6]{index=6}
)

SELECT
  /* keys */
  b.cntrct_id                               AS "*No.",
  b.cntrct_line_nbr                         AS "*Service Lines Replacement Data Line No",
  b.cntrct_line_nbr                         AS "*Line Number",

  /* Company for Invoices: from latest release header (Business Unit) */
  NVL(r.business_unit, ' ')                 AS "Company for Invoices",

  /* Line On Hold: map Pending/Inactive to Y (tweak if your Workday values differ) */
  CASE WHEN b.line_status IN ('P','I') THEN 'Y' ELSE 'N' END AS "Line On Hold",  -- :contentReference[oaicite:7]{index=7}

  /* Item: from contract line item id (if you want “service lines item must be blank”, change to ' ') */
  NVL(NULLIF(TRIM(b.inv_item_id),''), ' ')  AS "Item",

  NVL(NULLIF(TRIM(b.descr254_mixed),''), ' ') AS "Description",

  /* Spend Category: best PS source is CATEGORY_ID */
  NVL(NULLIF(TRIM(b.category_id),''), ' ')  AS "Spend Category",

  ' '                                       AS "Tax Applicability",

  /* Tax Code exists on CNTRCT_LINE; keep if you want to carry it, else set ' ' */
  NVL(NULLIF(TRIM(b.tax_cd),''), ' ')       AS "Tax Code",

  ' '                                       AS "Tax Rate 1",
  ' '                                       AS "Tax Recoverability 1",
  ' '                                       AS "Tax Option 1"
