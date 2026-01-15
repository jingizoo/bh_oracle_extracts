
WITH
shipto_setid_by_bu AS (
  SELECT
    r.setcntrlvalue AS business_unit,
    MAX(r.setid)    AS shipto_setid
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
agg AS (
  SELECT
    rls.business_unit,
    rls.receiver_id,
    rls.recv_ln_nbr,
    rls.recv_ship_seq_nbr,

    rls.business_unit_po,
    rls.po_id,
    rls.line_nbr,
    rls.sched_nbr,


    CASE
      WHEN SUBSTR(TRIM(rls.po_id), 1, 3) = 'PO-' THEN TRIM(rls.po_id)
      WHEN TRANSLATE(TRIM(rls.po_id), '0123456789', '') IS NULL
           THEN 'PO-' || LPAD(TRIM(rls.po_id), 8, '0')
      ELSE 'PO-' || TRIM(rls.po_id)
    END AS po_no,


    MAX(rls.inv_item_id)        AS inv_item_id,
    MAX(rls.qty_sh_recvd)       AS qty_sh_recvd,
    MAX(rls.receive_uom)        AS receive_uom,
    MAX(rls.shipto_id)          AS shipto_id,
    MAX(rls.descr254_mixed)     AS recv_descr,

    MAX(pl.cntrct_id)           AS cntrct_id,
    MAX(pl.cntrct_line_nbr)     AS cntrct_line_nbr,
    MAX(pl.physical_nature)     AS physical_nature,


    MAX(rld.business_unit_gl) KEEP (DENSE_RANK FIRST ORDER BY rld.distrib_line_num) AS business_unit_gl,
    MAX(rld.location)         KEEP (DENSE_RANK FIRST ORDER BY rld.distrib_line_num) AS location,
    MAX(NULLIF(TRIM(rld.delivery_feedback),'')) KEEP (DENSE_RANK FIRST ORDER BY rld.distrib_line_num) AS delivery_feedback

  FROM ps_recv_ln_ship rls
  JOIN ps_recv_ln_distrib rld
    ON rld.business_unit      = rls.business_unit
   AND rld.receiver_id        = rls.receiver_id
   AND rld.recv_ln_nbr        = rls.recv_ln_nbr
   AND rld.recv_ship_seq_nbr  = rls.recv_ship_seq_nbr

  LEFT JOIN ps_po_line pl
    ON pl.business_unit = rls.business_unit_po
   AND pl.po_id         = rls.po_id
   AND pl.line_nbr      = rls.line_nbr

  WHERE 1=1
    AND rls.recv_ship_status <> 'X'
    AND rld.recv_ds_status   <> 'X'
    AND rld.dst_acct_type    = 'DST'


  GROUP BY
    rls.business_unit,
    rls.receiver_id,
    rls.recv_ln_nbr,
    rls.recv_ship_seq_nbr,
    rls.business_unit_po,
    rls.po_id,
    rls.line_nbr,
    rls.sched_nbr
),
numbered AS (
  SELECT
    a.*,
    ROW_NUMBER() OVER (
      PARTITION BY a.receiver_id
      ORDER BY a.recv_ln_nbr, a.recv_ship_seq_nbr
    ) AS line_seq
  FROM agg a
)

SELECT
  n.receiver_id                                                AS "*No.",
  n.line_seq                                                   AS "*Item Receipt Line Replacement Line No",

  n.po_no || '-' || TO_CHAR(n.line_nbr)                        AS "Purchase Order Line",

  CASE
    WHEN TRIM(n.cntrct_id) IS NOT NULL AND TRIM(n.cntrct_id) <> ''
      THEN TRIM(n.cntrct_id) || '-' || TO_CHAR(n.cntrct_line_nbr)
    ELSE ' '
  END                                                          AS "Supplier Contract Line",

  n.business_unit_gl                                            AS "Line Company",
  ' '                                                          AS "Packaging String",
  n.inv_item_id                                                 AS "Purchase Item",
  n.qty_sh_recvd                                                AS "Quantity",
  n.receive_uom                                                 AS "Unit of Measure",
  'Delivery'                                                    AS "Delivery Type",

  CASE
    WHEN st.descr IS NOT NULL THEN n.shipto_id || ' - ' || st.descr
    ELSE n.shipto_id
  END                                                          AS "Ship To Address",

  ' '                                                          AS "Ship To Contact Worker Type",
  ' '                                                          AS "Ship To Contact Worker ID",

  n.location                                                    AS "Deliver To",
  ' '                                                          AS "Commodity Code",

  COALESCE(n.delivery_feedback, NULLIF(TRIM(n.recv_descr),''), ' ') AS "Memo",

  
  CASE
    WHEN n.physical_nature = 'G'
      THEN n.receiver_id || '-' || TO_CHAR(n.line_seq)
    ELSE ' '
  END                                                          AS "Goods Delivery Line"

FROM numbered n
LEFT JOIN shipto_setid_by_bu sb
  ON sb.business_unit = n.business_unit_po
LEFT JOIN shipto_ed st
  ON st.setid     = sb.shipto_setid
 AND st.shipto_id = n.shipto_id
ORDER BY n.receiver_id, n.line_seq;
