/* Driving parameters:
   - asof_dt: reporting “as of” date for the extract
   - lookback_dt: 12‑month window start, used to limit POs and activity */
WITH
params AS (
  SELECT TRUNC(to_date('15-01-2026','DD-MM-YYYY')) AS asof_dt,
         ADD_MONTHS(TRUNC(To_date('15-01-2026','DD-MM-YYYY')), -12) AS lookback_dt
  FROM dual
),

/* ============================================================
   PO header candidates:
   - Find all open (non‑cancelled) POs for valid vendors and business units
   - Limited to the as‑of date; later CTEs will further narrow to “open” POs
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

/* Flags from the PO line:
   - recv_req: is receiving required
   - amt_only_flg: is this an amount‑only line
   - physical_nature: goods vs service */
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

/* Service PO flag at PO level:
   Looks at distribution accounts and a crosswalk to decide if the PO behaves as a “service” PO */
service_flags AS (
  SELECT /*+ LEADING(hc d) USE_NL(d) INDEX(d) */ d.business_unit,
         d.po_id,
         CASE WHEN MAX(x.BH_XWLK_t1) IS NOT NULL THEN 'Y' ELSE 'N' END AS has_service
    FROM po_hdr_candidates hc
    JOIN ps_po_line_distrib d
      ON d.business_unit = hc.business_unit
     AND d.po_id         = hc.po_id
    LEFT JOIN PS_BH_XWLK_VAL_TBL x
      ON x.LONGNAME        = 'WD_ACCT_TO_PO_TYPE'
     AND x.bh_xwlk_module  = 'PO'
     AND x.bh_xwlk_track   = 'SCM'
     AND x.BH_XWLK_S2      = d.account
   GROUP BY d.business_unit, d.po_id
),

/* Core “open schedule” logic:
   - Uses amount or quantity comparison (depending on line flags) to decide if a PO schedule is still open
   - Carries through ship‑to, due date, and pricing needed later in the extract */
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
     -- x.qty_rcvd_suom,
    --  x.merch_amt_rcvd_po,
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
        --NVL(r.qty_rcvd_suom, 0)     AS qty_rcvd_suom,
       -- NVL(r.merch_amt_rcvd_po, 0) AS merch_amt_rcvd_po,
        NVL(vs.merch_amt_vchr, 0)   AS merch_amt_vchr,
        NVL(s.merchandise_amt, NVL(s.qty_po,0) * NVL(s.price_po,0)) AS sched_amt,
           NVL (vs.qty_vchr,0) as qty_vchr
    FROM ps_po_line_ship s
    JOIN po_hdr_candidates hc
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
  ) x
) ,

/* Additional PO‑level filter:
   - Ensures the PO has a positive remaining amount or quantity (same gate as the line extract)
   - Treats service and goods POs according to the flags from service_flags and po_line_flags */
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

/* POs that have at least one open schedule AND at least one active line/distribution:
   This is the base “eligible PO” set that all later logic builds on */
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

/* Final list of POs included in this extract:
   - Within the lookback period
   - Eligible/open per above
   - Have a Workday supplier mapping and valid purchasing BU
   - Also satisfy the “positive amount/qty” gate */
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

/* Specific PO lines/schedules in scope:
   - Non‑cancelled PO lines and shipments on included POs
   - Schedules that are still open
   - With at least one active distribution row */
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

/* Voucher candidates for PO invoices:
   - Approved, non‑adjustment vouchers in the lookback window
   - Must touch at least one of the included PO goods lines */
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
   /* AND NOT EXISTS (
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

/* Paid vouchers (restricted to the candidate set; avoids scanning the entire xref table) */
paid_xref AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN po_vouchers_pre pv
    ON pv.business_unit = px.business_unit
   AND pv.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND NVL(px.paid_amt,0) > 0
),

/* Zero‑amount “paid” vouchers (e.g. selected with net zero paid), also restricted to candidates */
paid_zero_amt_xref AS (
  SELECT /*+ MATERIALIZE */ DISTINCT px.business_unit, px.voucher_id
  FROM ps_pymnt_vchr_xref px
  JOIN po_vouchers_pre vc
    ON vc.business_unit = px.business_unit
   AND vc.voucher_id    = px.voucher_id
  WHERE px.pymnt_action <> 'X'
    AND ABS(NVL(px.paid_amt,0)) = 0 and pymnt_selct_status='P'
),
/* Final voucher set for this extract:
   - Approved, PO‑backed, within lookback window
   - Excludes vouchers with any payment (positive or zero) */
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
     AND NOT EXISTS (
      SELECT 1 FROM paid_zero_amt_xref px1
      WHERE px1.business_unit = pv.business_unit
        AND px1.voucher_id    = pv.voucher_id
    )
),

/* Core voucher header data:
   Pulls the columns we need for joins and for the final Supplier Invoice header output */
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
  JOIN po_vouchers pv
    ON pv.business_unit = v.business_unit
   AND pv.voucher_id    = v.voucher_id
),

/* All lines for the in‑scope vouchers:
   Used to derive ship‑to, PO list, contract list and memo text for each voucher */
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

/* First ship‑to per voucher (by first line):
   So the header can carry a single ship‑to ID if required */
line_first AS (
    SELECT
        business_unit,
        voucher_id,
        MAX(shipto_id) KEEP (DENSE_RANK FIRST ORDER BY voucher_line_num) AS shipto_id
    FROM lines_base
    GROUP BY business_unit, voucher_id
),

/* Distinct PO list per voucher:
   - Builds a semicolon‑separated list of POs referenced on lines
   - Uses LISTAGG with overflow protection to avoid ORA‑01489 */
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

/* Distinct contract list per voucher:
   Same pattern as the PO list, but for contracts referenced on voucher lines */
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

/* Memo aggregation:
   - Cleans and concatenates line‑level descriptions into a single memo per voucher
   - ORDER BY is commented out on purpose to keep PGA usage under control on large volumes */
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

/* Payment row (pymnt_cnt = 1):
   Used for header‑level fields such as “On Hold” and “Handling Code” */
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

/* Limit vendor lookups to only the vendors in our voucher_base:
   Keeps all downstream vendor CTEs much smaller and faster */
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

/* Pick ONE address per vendor to avoid multiplying rows when we join vendor address later */
vendor_addr_pick AS (
    SELECT setid, vendor_id, MIN(address_seq_num) AS address_seq_num
    FROM vendor_addr_eff
    GROUP BY setid, vendor_id
),

/* Pick ONE vendor location per vendor, preferring those that have payment setup:
   This, together with vendor_addr_pick, guarantees a single supplier connection row per voucher */
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

/* Supplier connection ID for Workday:
   - Combines vendor name, chosen address and chosen location/payment layout
   - Because we have exactly one address and one location per vendor, this produces one row per voucher */
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
CASE
    WHEN NVL(v.saletx_amt, 0)
       + NVL(v.usetax_amt, 0)
       + NVL(v.vat_inv_amt, 0)
       + NVL(v.vat_noninv_amt, 0) <> 0
    THEN 'Enter Tax Due to Supplier'
    ELSE ''
END   AS "Default Tax Option",

    ' ' AS "Ship-To Address",
    --NVL(lf.shipto_id, ' ')      AS "Ship-To Address ID",
    ' '      AS "Ship-To Address ID",
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
    ' '            AS "Override Payment Type",
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
 JOIN ps_bh_wd_sup_1to1 wd ON v.vendor_id = wd.bh_wd_ps_vendor_id
LEFT JOIN pymnt1       p  ON p.business_unit = v.business_unit AND p.voucher_id = v.voucher_id
LEFT JOIN line_first   lf ON lf.business_unit = v.business_unit AND lf.voucher_id = v.voucher_id
LEFT JOIN po_list      pl ON pl.business_unit = v.business_unit AND pl.voucher_id = v.voucher_id
LEFT JOIN cntrct_list  cl ON cl.business_unit = v.business_unit AND cl.voucher_id = v.voucher_id
LEFT JOIN memo_agg     ma ON ma.business_unit = v.business_unit AND ma.voucher_id = v.voucher_id
LEFT JOIN supp_conn    sc ON sc.business_unit = v.business_unit AND sc.voucher_id = v.voucher_id



