WITH
/* 1) Drive set */

params AS (
  /* Set :p_asof_dt if you want repeatable cutover testing */
  SELECT
    TRUNC(SYSDATE)                  AS asof_dt,
    ADD_MONTHS(TRUNC(SYSDATE), -12) AS lookback_dt
  FROM dual
),

/* ------------------------------------------------------------------------
   PO conversion scope (open POs with activity in last 12 months)
   Used to determine which PO-invoices to bring over.
   ------------------------------------------------------------------------ */
po_hdr_candidates AS (
  SELECT /*+ MATERIALIZE */
         h.business_unit,
         h.po_id,
         h.po_dt,
         h.po_status
    FROM ps_po_hdr h
    CROSS JOIN params p
   WHERE h.po_dt <= p.asof_dt
     AND h.po_status NOT IN ('C','X')
),
recv_agg AS (
  SELECT
      r.business_unit_po AS business_unit,
      r.po_id,
      r.line_nbr,
      r.sched_nbr,
      SUM(NVL(r.qty_sh_recvd_suom, 0))  AS qty_rcvd_suom,
      SUM(NVL(r.merchandise_amt_po, 0)) AS merch_amt_rcvd_po
  FROM ps_recv_ln_ship r
  JOIN po_hdr_candidates hc
    ON hc.business_unit = r.business_unit_po
   AND hc.po_id         = r.po_id
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm < CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id, r.line_nbr, r.sched_nbr
),
sched_open AS (
  SELECT
      s.business_unit,
      s.po_id,
      s.line_nbr,
      s.sched_nbr,
      s.cancel_status,
      s.qty_po,
      s.merchandise_amt,
      s.liquidate_method,
      NVL(r.qty_rcvd_suom, 0)      AS qty_rcvd_suom,
      NVL(r.merch_amt_rcvd_po, 0)  AS merch_amt_rcvd_po,
      CASE
        WHEN NVL(s.cancel_status,' ') IN ('C','X') THEN 0
        WHEN s.liquidate_method = 'A' THEN
             CASE WHEN NVL(s.merchandise_amt,0) > NVL(r.merch_amt_rcvd_po,0) THEN 1 ELSE 0 END
        ELSE
             CASE WHEN NVL(s.qty_po,0) > NVL(r.qty_rcvd_suom,0) THEN 1 ELSE 0 END
      END AS is_open
  FROM ps_po_line_ship s
  JOIN po_hdr_candidates hc
    ON hc.business_unit = s.business_unit
   AND hc.po_id         = s.po_id
  LEFT JOIN recv_agg r
    ON r.business_unit  = s.business_unit
   AND r.po_id          = s.po_id
   AND r.line_nbr       = s.line_nbr
   AND r.sched_nbr      = s.sched_nbr
),
po_rcv_activity AS (
  SELECT
      r.business_unit_po AS business_unit,
      r.po_id,
      MAX(r.receipt_dttm) AS last_receipt_dttm
  FROM ps_recv_ln_ship r
  CROSS JOIN params p
  WHERE r.recv_ship_status <> 'X'
    AND r.receipt_dttm >= CAST(p.lookback_dt AS TIMESTAMP)
    AND r.receipt_dttm <  CAST(p.asof_dt + 1 AS TIMESTAMP)
  GROUP BY r.business_unit_po, r.po_id
),
po_inv_activity AS (
  SELECT
      vl.business_unit_po AS business_unit,
      vl.po_id,
      MAX(NVL(v.invoice_dt, v.entered_dt)) AS last_invoice_dt
  FROM ps_voucher_line vl
  JOIN ps_voucher v
    ON v.business_unit = vl.business_unit
   AND v.voucher_id    = vl.voucher_id
  CROSS JOIN params p
  WHERE vl.business_unit_po IS NOT NULL
    AND vl.po_id IS NOT NULL
    AND TRIM(vl.po_id) <> ''
    AND v.entry_status <> 'X'
    AND v.close_status <> 'C'
    AND NVL(v.invoice_dt, v.entered_dt) >= p.lookback_dt
    AND NVL(v.invoice_dt, v.entered_dt) <= p.asof_dt
  GROUP BY vl.business_unit_po, vl.po_id
),
open_pos AS (
  /* Open POs in scope = open schedules AND activity within lookback */
  SELECT /*+ MATERIALIZE */
         hc.business_unit,
         hc.po_id
    FROM po_hdr_candidates hc
    CROSS JOIN params p
    LEFT JOIN po_rcv_activity pra
      ON pra.business_unit = hc.business_unit
     AND pra.po_id         = hc.po_id
    LEFT JOIN po_inv_activity pia
      ON pia.business_unit = hc.business_unit
     AND pia.po_id         = hc.po_id
   WHERE EXISTS (
         SELECT 1
           FROM sched_open so
          WHERE so.business_unit = hc.business_unit
            AND so.po_id         = hc.po_id
            AND so.is_open       = 1
       )
     AND (
          hc.po_dt >= p.lookback_dt
       OR pra.last_receipt_dttm IS NOT NULL
       OR pia.last_invoice_dt   IS NOT NULL
     )
),

/* ------------------------------------------------------------------------
   Voucher driver set per conversion approach
   - PO invoices: only those tied to OPEN POs in-scope (via VOUCHER_LINE.BUSINESS_UNIT_PO/PO_ID),
                 and exclude any voucher that has SERVICE PO lines (per “do not convert partial service PO invoices”)
   - Non-PO invoices: approved/unpaid (open) invoices in the last 12 months
   ------------------------------------------------------------------------ */
voucher_base AS (
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
      AND NVL(v.invoice_dt, v.entered_dt) >= p.lookback_dt
      AND NVL(v.invoice_dt, v.entered_dt) <= p.asof_dt
      AND (
            /* A) PO-Invoices for OPEN POs in-scope (goods only) */
            (
              EXISTS (
                SELECT 1
                FROM ps_voucher_line vl
                JOIN open_pos op
                  ON op.business_unit = vl.business_unit_po
                 AND op.po_id         = vl.po_id
                JOIN ps_po_line pl
                  ON pl.business_unit = vl.business_unit_po
                 AND pl.po_id         = vl.po_id
                 AND pl.line_nbr      = vl.line_nbr
                 AND pl.physical_nature = 'G'
                WHERE vl.business_unit = v.business_unit
                  AND vl.voucher_id    = v.voucher_id
                  AND NVL(TRIM(vl.po_id),'') <> ''
              )
              AND NOT EXISTS (
                /* exclude vouchers touching SERVICE PO lines */
                SELECT 1
                FROM ps_voucher_line vl2
                JOIN ps_po_line pl2
                  ON pl2.business_unit = vl2.business_unit_po
                 AND pl2.po_id         = vl2.po_id
                 AND pl2.line_nbr      = vl2.line_nbr
                WHERE vl2.business_unit = v.business_unit
                  AND vl2.voucher_id    = v.voucher_id
                  AND NVL(TRIM(vl2.po_id),'') <> ''
                  AND pl2.physical_nature = 'S'
              )
            )
            OR
            /* B) Non-PO invoices: no PO at header AND no PO on lines */
            (
              NVL(TRIM(v.po_id),'') = ''
              AND NOT EXISTS (
                SELECT 1
                FROM ps_voucher_line vl3
                WHERE vl3.business_unit = v.business_unit
                  AND vl3.voucher_id    = v.voucher_id
                  AND NVL(TRIM(vl3.po_id),'') <> ''
              )
            )
      )
),

lines_base AS (
    SELECT /*+ MATERIALIZE */
        vl.business_unit,
        vl.voucher_id,
        vl.voucher_line_num,
        vl.shipto_id,
        vl.po_id,
        vl.cntrct_id,
        vl.descr254_mixed
    FROM ps_voucher_line vl
    WHERE EXISTS (
        SELECT 1
        FROM voucher_base vb
        WHERE vb.business_unit = vl.business_unit
          AND vb.voucher_id   = vl.voucher_id
    )
),

/* first line's shipto_id */
line_first AS (
    SELECT
        business_unit,
        voucher_id,
        MAX(shipto_id) KEEP (DENSE_RANK FIRST ORDER BY voucher_line_num) AS shipto_id
    FROM lines_base
    GROUP BY business_unit, voucher_id
),

/* distinct PO list from lines (index-friendly predicate; trim only in projection) */
/* LISTAGG overflow protection: ON OVERFLOW TRUNCATE prevents ORA-01489 (requires Oracle 12.2+) */
po_list AS (
    SELECT
        business_unit,
        voucher_id,
        LISTAGG(po_id, ';' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) WITHIN GROUP (ORDER BY po_id) AS po_list
    FROM (
        SELECT DISTINCT
            business_unit,
            voucher_id,
            TRIM(po_id) AS po_id
        FROM lines_base
        WHERE po_id IS NOT NULL
          AND po_id <> ' '
    )
    GROUP BY business_unit, voucher_id
),

/* distinct Contract list from lines */
/* LISTAGG overflow protection: ON OVERFLOW TRUNCATE prevents ORA-01489 (requires Oracle 12.2+) */
cntrct_list AS (
    SELECT
        business_unit,
        voucher_id,
        LISTAGG(cntrct_id, ';' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) WITHIN GROUP (ORDER BY cntrct_id) AS cntrct_list
    FROM (
        SELECT DISTINCT
            business_unit,
            voucher_id,
            TRIM(cntrct_id) AS cntrct_id
        FROM lines_base
        WHERE cntrct_id IS NOT NULL
          AND cntrct_id <> ' '
    )
    GROUP BY business_unit, voucher_id
),

/* memo aggregation - ORDER BY removed to reduce PGA usage */
/* If memo ordering is required, uncomment ORDER BY but expect higher PGA usage */
memo_agg AS (
    SELECT
        business_unit,
        voucher_id,
        RTRIM(
            XMLCAST(
                XMLAGG(
                    XMLELEMENT(
                        e,
                        REGEXP_REPLACE(
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(NVL(TRIM(descr254_mixed), ''), '[^[:print:]]', ' '),
                                '-{2,}',
                                ' '
                            ),
                            '\s+',
                            ' '
                        ) || ' | '
                    )
                    -- ORDER BY voucher_line_num  -- COMMENTED OUT: Removed to reduce PGA usage
                ).EXTRACT('//text()') AS CLOB
            ),
            ' | '
        ) AS memo_text
    FROM lines_base
    WHERE descr254_mixed IS NOT NULL
      AND descr254_mixed <> ' '
    GROUP BY business_unit, voucher_id
),

/* payment row (pymnt_cnt=1) */
pymnt1 AS (
    SELECT /*+ MATERIALIZE */ x.*
    FROM ps_pymnt_vchr_xref x
    WHERE x.pymnt_cnt = 1
      AND EXISTS (
          SELECT 1
          FROM voucher_base vb
          WHERE vb.business_unit = x.business_unit
            AND vb.voucher_id   = x.voucher_id
      )
),

/* restrict vendor tables to vendors in voucher_base */
vendor_keys AS (
    SELECT /*+ MATERIALIZE */ DISTINCT
        vendor_setid AS setid,
        vendor_id
    FROM voucher_base
),

vendor_addr_eff AS (
    SELECT setid, vendor_id, address_seq_num
    FROM (
        SELECT
            a.setid,
            a.vendor_id,
            a.address_seq_num,
            ROW_NUMBER() OVER (
                PARTITION BY a.setid, a.vendor_id, a.address_seq_num
                ORDER BY a.effdt DESC
            ) rn
        FROM ps_vendor_addr a
        JOIN vendor_keys vk
          ON vk.setid     = a.setid
         AND vk.vendor_id = a.vendor_id
        WHERE a.effdt <= SYSDATE
    )
    WHERE rn = 1
),

vendor_pay_eff AS (
    SELECT setid, vendor_id, vndr_loc, eft_layout_cd
    FROM (
        SELECT
            p.setid,
            p.vendor_id,
            p.vndr_loc,
            p.eft_layout_cd,
            ROW_NUMBER() OVER (
                PARTITION BY p.setid, p.vendor_id, p.vndr_loc
                ORDER BY p.effdt DESC
            ) rn
        FROM ps_vendor_pay p
        JOIN vendor_keys vk
          ON vk.setid     = p.setid
         AND vk.vendor_id = p.vendor_id
        WHERE p.effdt <= SYSDATE
    )
    WHERE rn = 1
),

vendor_loc_eff AS (
    SELECT setid, vendor_id, vndr_loc
    FROM (
        SELECT
            l.setid,
            l.vendor_id,
            l.vndr_loc,
            ROW_NUMBER() OVER (
                PARTITION BY l.setid, l.vendor_id, l.vndr_loc
                ORDER BY l.effdt DESC
            ) rn
        FROM ps_vendor_loc l
        JOIN vendor_keys vk
          ON vk.setid     = l.setid
         AND vk.vendor_id = l.vendor_id
        WHERE l.effdt <= SYSDATE
    )
    WHERE rn = 1
),

/* pick 1 address + 1 location per vendor to prevent cartesian explosion */
vendor_addr_pick AS (
    SELECT setid, vendor_id, MIN(address_seq_num) AS address_seq_num
    FROM vendor_addr_eff
    GROUP BY setid, vendor_id
),

vendor_loc_pick AS (
    SELECT setid, vendor_id,
           MIN(vndr_loc) KEEP (DENSE_RANK FIRST ORDER BY has_pay DESC, vndr_loc) AS vndr_loc
    FROM (
        SELECT
            l.setid,
            l.vendor_id,
            l.vndr_loc,
            CASE WHEN p.setid IS NOT NULL THEN 1 ELSE 0 END AS has_pay
        FROM vendor_loc_eff l
        LEFT JOIN vendor_pay_eff p
          ON p.setid     = l.setid
         AND p.vendor_id = l.vendor_id
         AND p.vndr_loc  = l.vndr_loc
    )
    GROUP BY setid, vendor_id
),

/* 
 * supp_conn: Ensures 1 row per voucher by picking ONE address + ONE location per vendor
 * This prevents cartesian explosion that causes PGA blowup
 * vendor_addr_pick: MIN(address_seq_num) per vendor = 1 row per vendor
 * vendor_loc_pick: MIN(vndr_loc) per vendor = 1 row per vendor
 * Result: 1 row per voucher (no multiplication)
 */
supp_conn AS (
    SELECT
        vb.business_unit,
        vb.voucher_id,
        ( ven.name1
          || '_' || vap.address_seq_num
          || '_' || CASE vpp.eft_layout_cd
                      WHEN 'CCD+' THEN 'ACH_CCD'
                      WHEN 'CTX'  THEN 'ACH_CTX'
                      WHEN 'SUA'  THEN 'SUA'
                      ELSE 'Check'
                    END
        ) AS supplier_connection_id
    FROM voucher_base vb
    JOIN ps_vendor ven
      ON ven.setid     = vb.vendor_setid
     AND ven.vendor_id = vb.vendor_id
    JOIN vendor_addr_pick vap
      ON vap.setid     = ven.setid
     AND vap.vendor_id = ven.vendor_id
    JOIN vendor_loc_pick vlp
      ON vlp.setid     = ven.setid
     AND vlp.vendor_id = ven.vendor_id
    LEFT JOIN vendor_pay_eff vpp
      ON vpp.setid     = vlp.setid
     AND vpp.vendor_id = vlp.vendor_id
     AND vpp.vndr_loc  = vlp.vndr_loc
)

SELECT /*+ LEADING(v) */
    -- USE_HASH hint removed for PGA safety (can increase PGA usage on large batches)
    -- If you need to force join method, consider USE_NL for nested loops (lower PGA, slower)
    v.voucher_id                AS "*No.",
    'Y' AS "Add Only",
    ' ' AS "Supplier Invoice Reference For Update",
    v.voucher_id                AS "Supplier Invoice ID",
    'Y' AS "Submit",
    ' ' AS "Locked in Workday",
    ' ' AS "Invoice Number",
    ' ' AS "Gapless Document Number",
    ' ' AS "Invoice Document Status",
    'Peoplesoft' AS "External Supplier Invoice Source",
    ' ' AS "Cancel Accounting Date",
    ' ' AS "Invoice Accounting Date",
    v.business_unit_gl          AS "*Company",
    ' ' AS "Payment Practices",
    v.txn_currency_cd           AS "*Currency",
    wd.bh_wd_supplier_id        AS "Supplier",
    ' ' AS "Contingent Worker ID",
    sc.supplier_connection_id   AS "Supplier Connection",
    ' ' AS "Use Default Supplier Connection",
NVL( NVL(v.saletx_amt, 0) + NVL(v.usetax_amt, 0) + NVL(v.vat_inv_amt, 0) + NVL(v.vat_noninv_amt, 0),0) AS "Default Tax Option",
    ' ' AS "Ship-To Address",
    NVL(lf.shipto_id, ' ')      AS "Ship-To Address ID",
    ' ' AS "Tax Code",
    ' ' AS "Default Withholding Tax Code",
    TO_CHAR(v.invoice_dt,  'YYYY-MM-DD') AS "*Invoice Date",
    TO_CHAR(v.entered_dt,  'YYYY-MM-DD') AS "Invoice Received Date",
    ' ' AS "Invoice Delivery Date",
    ' ' AS "Invoice Billing Start Date",
    ' ' AS "Invoice Billing End Date",
    ' ' AS "Discount Amount Override",
    ' ' AS "Discount Date Override",
    TO_CHAR(v.due_dt,      'YYYY-MM-DD') AS "Due Date Override",
    ' ' AS "Accounting Date Override",
    ' ' AS "Budget Date",
    NVL(p.pymnt_hold, 'N')      AS "On Hold",
    ' ' AS "Control Amount Total",
    ( NVL(v.saletx_amt, 0) + NVL(v.usetax_amt, 0) + NVL(v.vat_inv_amt, 0) + NVL(v.vat_noninv_amt, 0) ) AS "Tax Amount",
    ' ' AS "Withholding Tax Amount",
    v.freight_amt               AS "Freight Amount",
    v.misc_amt                  AS "Other Charges",
    ' ' AS "Worktag Split Template",
    ' ' AS "Tax Only",
    ' ' AS "Down Payment",
    ' ' AS "Down Payment Purchase Order Reference",
    ' ' AS "Supplier Document Received",
    v.invoice_id                AS "Suppliers Invoice Number",
    CASE
        WHEN v.po_id IS NOT NULL AND v.po_id <> ' ' THEN TRIM(v.po_id)
        ELSE NVL(pl.po_list, ' ')
    END AS "External PO Number",
    CASE
        WHEN v.cntrct_id IS NOT NULL AND v.cntrct_id <> ' ' THEN TRIM(v.cntrct_id)
        ELSE NVL(cl.cntrct_list, ' ')
    END AS "Supplier Contract",
    ' ' AS "Document Link",
    ' ' AS "Supplier Invoice Request",
    ' ' AS "Requester Worker Type",
    ' ' AS "Requester ID",
    ' ' AS "Statutory Invoice Type",
    NVL(ma.memo_text, ' ')      AS "Memo",
    ' ' AS "Approver Worker Type",
    ' ' AS "Approver ID",
    v.pymnt_terms_cd            AS "*Payment Terms",
    'check remit to'            AS "Override Payment Type",
    ' ' AS "Additional Type",
    ' ' AS "Additional Reference Number",
    NVL(p.pymnt_handling_cd, ' ') AS "Handling Code",
    CASE
        WHEN v.voucher_style = 'PPAY' OR TRIM(v.prepaid_ref) <> '' THEN 'Y'
        ELSE 'N'
    END AS "Prepaid",
    CASE
        WHEN v.voucher_style = 'PPAY' OR TRIM(v.prepaid_ref) <> '' THEN 'SCHEDULE'
        ELSE ' '
    END AS "Prepayment Release Type",
    ' ' AS "Release Date",
    ' ' AS "Frequency",
    ' ' AS "Number of Installments",
    ' ' AS "Use Invoice Date",
    ' ' AS "From Date",
    ' ' AS "Gross Invoice Amount",
    ' ' AS "Total Amount Retained",
    ' ' AS "Total Amount Released",
    ' ' AS "Retention Memo",
    ' ' AS "Total Down Payment Applied Amount",
    ' ' AS "Net Supplier Invoice Amount"
FROM voucher_base v
LEFT JOIN pymnt1       p  ON p.business_unit = v.business_unit AND p.voucher_id = v.voucher_id
LEFT JOIN line_first   lf ON lf.business_unit = v.business_unit AND lf.voucher_id = v.voucher_id
LEFT JOIN po_list      pl ON pl.business_unit = v.business_unit AND pl.voucher_id = v.voucher_id
LEFT JOIN cntrct_list  cl ON cl.business_unit = v.business_unit AND cl.voucher_id = v.voucher_id
LEFT JOIN memo_agg     ma ON ma.business_unit = v.business_unit AND ma.voucher_id = v.voucher_id
LEFT JOIN supp_conn    sc ON sc.business_unit = v.business_unit AND sc.voucher_id = v.voucher_id
LEFT JOIN ps_bh_wd_sup_1to1 wd ON v.vendor_id = wd.bh_wd_ps_vendor_id
