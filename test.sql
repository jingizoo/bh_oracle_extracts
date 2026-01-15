and (
        remit_vndr.vendor_id = itm_vndr.vendor_id
     or (
            remit_vndr.remit_vendor = itm_vndr.vendor_id
        and 0 = (
              select count(1)
              from ps_itm_vndr_uom@FSRPTPRD iv1
              where iv1.inv_item_id      = nvl(to_char(c.hfh_item), ' ')
                and iv1.setid           = remit_vndr.setid
                and iv1.conversion_rate = c.source_conv_rate
                and iv1.vendor_id       = remit_vndr.vendor_id
        )
     )
)
