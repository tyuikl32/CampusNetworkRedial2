/* Compile-only layout probe.  NEVER LOADED on the device.
 *
 * Each `char cr_<field>[offsetof(struct net_device, <field>)];` lands in .bss
 * with SIZE == the field offset, so `readelf -sW` prints the offsets without us
 * ever executing anything.  Gives the exact struct layout a build produces,
 * to be compared against the vendor modules running on the device.
 *
 * Build with -DCR_QSDK against the Qualcomm QSDK tree (vendor fields exist);
 * omit it for upstream linux-5.4.164 (those fields are vendor-only).
 */
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>

#define DUMP(f) char cr_##f[offsetof(struct net_device, f)];
DUMP(name)
DUMP(ifindex)
DUMP(dev_list)
DUMP(napi_list)
DUMP(features)
DUMP(hw_features)
DUMP(netdev_ops)
DUMP(ethtool_ops)
DUMP(header_ops)
DUMP(flags)
DUMP(priv_flags)
#ifdef CR_QSDK
DUMP(priv_flags_ext)
DUMP(local_addr_mask)
DUMP(wireless_handlers)
DUMP(wireless_data)
#endif
DUMP(gflags)
DUMP(mtu)
DUMP(type)
DUMP(hard_header_len)
DUMP(min_header_len)
DUMP(addr_len)
DUMP(neigh_priv_len)
DUMP(dev_id)
DUMP(addr_list_lock)
DUMP(uc)
DUMP(mc)
DUMP(dev_addrs)
DUMP(perm_addr)
DUMP(dev_addr)
DUMP(min_mtu)
DUMP(max_mtu)
DUMP(pcpu_refcnt)
DUMP(_rx)
DUMP(num_rx_queues)
DUMP(gro_flush_timeout)
DUMP(rx_handler)
DUMP(ingress_queue)

/* not fields: raw sizes, read back the same way */
char cr_sizeof_net_device[sizeof(struct net_device)];
char cr_sizeof_net_device_ops[sizeof(struct net_device_ops)];
char cr_netdev_align[NETDEV_ALIGN];

static int __init cr_offdump_init(void) { return 0; }
static void __exit cr_offdump_exit(void) { }
module_init(cr_offdump_init);
module_exit(cr_offdump_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("layout probe, compile-only");
