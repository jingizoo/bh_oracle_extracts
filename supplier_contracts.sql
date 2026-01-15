WITH
/* 1) Current contract headers */
cntrct_cur AS (
  SELECT /*+ MATERIALIZE */
    ch.setid,
    ch.cntrct_id,
    ch.vendor_setid,
    ch.vendor_id,
    ch.cntrct_status,
    ch.cntrct_proc_opt,
    ch.descr,
    ch.cntrct_begin_dt,
    ch.cntrct_end_dt,
    ch.oprid_entered_by
  FROM ps_cntrct_hdr ch
  WHERE ch.version_status = 'C'       -- current version
),
/* 2) Latest release header per contract */
rls_latest AS (
  SELECT /*+ MATERIALIZE */
    setid,
    cntrct_id,
    business_unit,
    vndr_loc,
    buyer_id,
    currency_cd,
    pymnt_terms_cd
  FROM (
    SELECT
      r.setid,
      r.cntrct_id,
      r.business_unit,
      r.vndr_loc,
      r.buyer_id,
      r.currency_cd,
      r.pymnt_terms_cd,
      ROW_NUMBER() OVER (
        PARTITION BY r.setid, r.cntrct_id
        ORDER BY NVL(r.trans_date, DATE '1900-01-01') DESC, r.seq_num DESC
      ) AS rn
    FROM ps_cntrct_rls_hdr r
  )
  WHERE rn = 1
),
/* 3) Signed date from activity */
signed_dt AS (
  SELECT /*+ MATERIALIZE */
    a.setid,
    a.cntrct_id,
    MAX(a.signed_dt) AS signed_dt
  FROM ps_cntrct_activity a
  WHERE a.signed_off = 'Y'
  GROUP BY a.setid, a.cntrct_id
)

SELECT
  /* keys */
  c.cntrct_id                                     AS "*No.",
  'Y'                                             AS "Add Only",
  ' '                                             AS "Supplier Contract Reference For Updates",
  c.cntrct_id                                     AS "Supplier Contract ID",
  ' '                                             AS "External System ID",
  ' '                                             AS "External Contract Reference ID",

  /* org/supplier */
  NVL(r.business_unit, ' ')                       AS "Company",
  ' '                                             AS "Company Hierarchy",
  c.vendor_id                                     AS "*Supplier",
  NVL(r.vndr_loc, ' ')                            AS "Order From Connection",

  /* owners */
  'Y'                                             AS "*Contract Specialist Is Employee",
  NVL(c.oprid_entered_by, ' ')                    AS "*Contract Specialist ID",
  'Y'                                             AS "*Buyer Is Employee",
  NVL(r.buyer_id, ' ')                            AS "*Buyer ID",

  /* contract attrs */
  NVL(c.cntrct_proc_opt, ' ')                     AS "*Contract Type",

  /* Document Status from CNTRCT_STATUS (A/C/H/O/P/X) */
  CASE c.cntrct_status
    WHEN 'A' THEN 'Approved'
    WHEN 'C' THEN 'Closed'
    WHEN 'H' THEN 'On Hold'
    WHEN 'O' THEN 'Open'
    WHEN 'P' THEN 'Pre-Approved'
    WHEN 'X' THEN 'Canceled'
    ELSE NVL(c.cntrct_status,' ')
  END                                             AS "Document Status",

  NVL(c.descr, ' ')                               AS "*Contract Name",
  ' '                                             AS "Contract Reference",
  ' '                                             AS "GPO Contract Reference",
  ' '                                             AS "Contract Document Link",

  /* dates */
  TO_CHAR(c.cntrct_begin_dt,'YYYY-MM-DD')         AS "*Contract Start Date",
  CASE WHEN s.signed_dt IS NOT NULL
       THEN TO_CHAR(s.signed_dt,'YYYY-MM-DD')
       ELSE ' '
  END                                             AS "Contract Signed Date",
  CASE WHEN c.cntrct_end_dt IS NOT NULL
       THEN TO_CHAR(c.cntrct_end_dt,'YYYY-MM-DD')
       ELSE ' '
  END                                             AS "Contract End Date",

  /* amounts (leave NULL unless you confirm the correct PS fields for thresholds/total) */
  NULL                                            AS "Minimum Charge Control Amount",
  NULL                                            AS "Maximum Charge Control Amount",
  NULL                                            AS "Total Contract Amount",
  NULL                                            AS "Original Contract Amount",

  /* currency / terms */
  NVL(r.currency_cd, ' ')                         AS "*Currency",
  ' '                                             AS "Default Tax Code",
  NVL(r.pymnt_terms_cd, ' ')                      AS "Payment Terms",
  ' '                                             AS "Override Payment Type",
  ' '                                             AS "Credit Card"

FROM cntrct_cur c
LEFT JOIN rls_latest r
  ON r.setid     = c.setid
 AND r.cntrct_id = c.cntrct_id
LEFT JOIN signed_dt s
  ON s.setid     = c.setid
 AND s.cntrct_id = c.cntrct_id

ORDER BY c.cntrct_id;
