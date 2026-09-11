// SPDX-License-Identifier: GPL-2.0
/*
 * cr_abicheck.ko - read-only net_device ABI canary for the campus-redial project.
 *
 * Why this exists
 * ---------------
 * The AX3000 runs a QSDK vendor kernel (5.4-qsdk-11.5.0.5-1) built with
 * CONFIG_MODVERSIONS=n and CONFIG_MODULE_SIG=n.  The kernel therefore happily
 * loads a module whose struct layouts differ, and only explodes when that module
 * dereferences a field.  That is exactly how the community-prebuilt macvlan.ko
 * panicked: it read struct net_device::dev_addr at ITS OWN compile-time offset,
 * got the garbage value 0x1, and handed that to get_random_bytes() as a buffer.
 * vermagic matched, so nothing warned us.
 *
 * What this module does
 * ---------------------
 * It is strictly READ-ONLY and performs NO pointer dereference taken out of the
 * struct, so a layout mismatch can only produce wrong numbers - never a crash:
 *
 *   1. prints this build's compile-time offsetof()/sizeof() for struct net_device
 *   2. reads a set of scalar fields of the already-allocated "lo" device through
 *      those offsets and checks them against the values the kernel source
 *      guarantees for loopback (name "lo", ifindex 1, mtu 65536, type 772,
 *      addr_len 6, flags IFF_LOOPBACK, hard_header_len 14, tx_queue_len 1000)
 *   3. dumps the raw bytes of the lo struct (bounded to the size this build
 *      believes the struct has) so the HOST can locate the true field offsets
 *      offline, where pointer chasing is free
 *
 * Verdict to look for in dmesg:
 *   cr_abicheck: RESULT=ABI_OK        -> safe to load macvlan.ko
 *   cr_abicheck: RESULT=ABI_MISMATCH  -> do NOT load macvlan.ko
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/netdevice.h>
#include <linux/net_namespace.h>
#include <linux/etherdevice.h>
#include <linux/if_arp.h>
#include <linux/printk.h>

#define DUMP_CAP 2048

static unsigned int dump_len;

static void dump_struct(struct net_device *dev)
{
	unsigned long want = ALIGN((unsigned long)sizeof(struct net_device), NETDEV_ALIGN);
	unsigned int n = (want > DUMP_CAP) ? DUMP_CAP : (unsigned int)want;

	/* Allocation size is at least ALIGN(sizeof,NETDEV_ALIGN)+NETDEV_ALIGN-1,
	 * so reading `n <= ALIGN(sizeof,...)` bytes is in-bounds by construction
	 * (when this build's sizeof is the right one, which is the hypothesis). */
	dump_len = n;
	pr_info("cr_abicheck: ---- raw dump of the lo struct (%u bytes) ----\n", n);
	print_hex_dump(KERN_INFO, "cr_abicheck: ", DUMP_PREFIX_OFFSET, 16, 4, dev, n, false);
}

static int __init cr_abicheck_init(void)
{
	struct net_device *dev;
	int fails = 0;

#define CK(cond, msg, ...)						\
	do {								\
		if (cond) {						\
			pr_info("cr_abicheck:  ok   " msg "\n", ##__VA_ARGS__);	\
		} else {						\
			fails++;					\
			pr_err("cr_abicheck:  FAIL " msg "\n", ##__VA_ARGS__);	\
		}							\
	} while (0)

	pr_info("cr_abicheck: ================= net_device ABI check =================\n");
	pr_info("cr_abicheck: sizeof(net_device)=%zu NETDEV_ALIGN=%d IFNAMSIZ=%d FIB=%d\n",
		sizeof(struct net_device), NETDEV_ALIGN, IFNAMSIZ, IFNAMSIZ - 1);
	pr_info("cr_abicheck: offsetof name=%zu ifindex=%zu mtu=%zu min_mtu=%zu max_mtu=%zu\n",
		offsetof(struct net_device, name), offsetof(struct net_device, ifindex),
		offsetof(struct net_device, mtu), offsetof(struct net_device, min_mtu),
		offsetof(struct net_device, max_mtu));
	pr_info("cr_abicheck: offsetof type=%zu hard_header_len=%zu min_header_len=%zu addr_len=%zu\n",
		offsetof(struct net_device, type), offsetof(struct net_device, hard_header_len),
		offsetof(struct net_device, min_header_len), offsetof(struct net_device, addr_len));
	pr_info("cr_abicheck: offsetof flags=%zu priv_flags=%zu features=%zu hw_features=%zu\n",
		offsetof(struct net_device, flags), offsetof(struct net_device, priv_flags),
		offsetof(struct net_device, features), offsetof(struct net_device, hw_features));
	pr_info("cr_abicheck: offsetof tx_queue_len=%zu state=%zu perm_addr=%zu dev_addr=%zu\n",
		offsetof(struct net_device, tx_queue_len), offsetof(struct net_device, state),
		offsetof(struct net_device, perm_addr), offsetof(struct net_device, dev_addr));
	pr_info("cr_abicheck: offsetof netdev_ops=%zu dev_addrs=%zu broadcast=%zu dev_list=%zu\n",
		offsetof(struct net_device, netdev_ops), offsetof(struct net_device, dev_addrs),
		offsetof(struct net_device, broadcast), offsetof(struct net_device, dev_list));

	dev = dev_get_by_name(&init_net, "lo");
	if (!dev) {
		pr_err("cr_abicheck: RESULT=ERROR (lo not found)\n");
		return -ENODEV;
	}

	pr_info("cr_abicheck: ---- values read through those offsets ----\n");
	pr_info("cr_abicheck: name='%s' ifindex=%d mtu=%u min_mtu=%u max_mtu=%u\n",
		dev->name, dev->ifindex, dev->mtu, dev->min_mtu, dev->max_mtu);
	pr_info("cr_abicheck: type=%u hard_header_len=%u min_header_len=%u addr_len=%u tx_queue_len=%u\n",
		dev->type, dev->hard_header_len, dev->min_header_len,
		dev->addr_len, dev->tx_queue_len);
	pr_info("cr_abicheck: flags=0x%x priv_flags=0x%x features=0x%llx hw_features=0x%llx\n",
		dev->flags, dev->priv_flags,
		(unsigned long long)dev->features, (unsigned long long)dev->hw_features);
	pr_info("cr_abicheck: state=0x%lx reg_state=%d operstate=%u\n",
		(unsigned long)READ_ONCE(dev->state), (int)dev->reg_state, dev->operstate);
	pr_info("cr_abicheck: netdev_ops=%px dev_addr=%px perm_addr=%*phN\n",
		dev->netdev_ops, (void *)dev->dev_addr,
		(int)sizeof(dev->perm_addr), dev->perm_addr);

	CK(!strncmp(dev->name, "lo", IFNAMSIZ), "name == 'lo' (got '%s')", dev->name);
	CK(dev->ifindex == 1, "ifindex == 1 (got %d)", dev->ifindex);
	CK(dev->mtu == 65536, "lo mtu == 65536 (got %u)", dev->mtu);
	CK(dev->type == ARPHRD_LOOPBACK, "lo type == ARPHRD_LOOPBACK/772 (got %u)", dev->type);
	CK(dev->addr_len == ETH_ALEN, "lo addr_len == 6 (got %u)", dev->addr_len);
	CK(dev->hard_header_len == ETH_HLEN, "lo hard_header_len == 14 (got %u)", dev->hard_header_len);
	CK(dev->min_header_len == ETH_HLEN, "lo min_header_len == 14 (got %u)", dev->min_header_len);
	CK(dev->flags == IFF_LOOPBACK, "lo flags == IFF_LOOPBACK/0x8 (got 0x%x)", dev->flags);
	CK(dev->tx_queue_len == 1000, "lo tx_queue_len == 1000 (got %u)", dev->tx_queue_len);
	CK(dev->min_mtu == 0, "lo min_mtu == 0 (got %u)", dev->min_mtu);
	CK(dev->max_mtu == 65536, "lo max_mtu == 65536 (got %u)", dev->max_mtu);
	CK(dev->reg_state == NETREG_REGISTERED, "lo reg_state == NETREG_REGISTERED/1 (got %d)",
	   (int)dev->reg_state);
	CK(dev->operstate == IF_OPER_UNKNOWN || dev->operstate == IF_OPER_UP,
	   "lo operstate is sane (got %u)", dev->operstate);
	/* the exact field that broke the community macvlan.ko build */
	CK((unsigned long)dev->dev_addr >= 0xc0000000UL && !((unsigned long)dev->dev_addr & 3),
	   "dev_addr is a plausible ARM kernel pointer (got %px)", (void *)dev->dev_addr);

	/* ---- the decisive check -------------------------------------------
	 * net/core/dev_addr_lists.c:dev_addr_init() does
	 *     ha = list_first_entry(&dev->dev_addrs.list, struct netdev_hw_addr, list);
	 *     dev->dev_addr = ha->addr;
	 * so for every alloc_netdev() device:
	 *     dev->dev_addr == dev->dev_addrs.list.next + offsetof(netdev_hw_addr, addr)
	 * This is pure pointer arithmetic on two values read straight out of the
	 * struct - nothing is dereferenced - yet it pins down the offset of BOTH
	 * dev_addr and dev_addrs at once, deep in the tail of struct net_device,
	 * which is exactly where a layout divergence would shift things.
	 */
	{
		unsigned long expect = (unsigned long)dev->dev_addrs.list.next +
				       offsetof(struct netdev_hw_addr, addr);
		pr_info("cr_abicheck: dev_addrs.list.next=%px count=%d -> expected dev_addr=%lx, actual=%lx\n",
			(void *)dev->dev_addrs.list.next, dev->dev_addrs.count,
			expect, (unsigned long)dev->dev_addr);
		CK((unsigned long)dev->dev_addr == expect,
		   "dev_addr == dev_addrs.list.next + %zu (RELATIONAL: both late offsets correct)",
		   (size_t)offsetof(struct netdev_hw_addr, addr));
		CK(dev->dev_addrs.count == 1, "dev_addrs.count == 1 for lo (got %d)",
		   dev->dev_addrs.count);
		pr_info("cr_abicheck: info uc.count=%d mc.count=%d (not part of the verdict)\n",
			dev->uc.count, dev->mc.count);
	}

	dump_struct(dev);

	dev_put(dev);

	if (fails)
		pr_err("cr_abicheck: RESULT=ABI_MISMATCH fails=%d -- do NOT load macvlan.ko\n", fails);
	else
		pr_info("cr_abicheck: RESULT=ABI_OK -- net_device layout matches the running kernel\n");

#undef CK
	return 0;
}

static void __exit cr_abicheck_exit(void)
{
	pr_info("cr_abicheck: unloaded (dumped %u bytes)\n", dump_len);
}

module_init(cr_abicheck_init);
module_exit(cr_abicheck_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("campus-redial read-only net_device ABI canary");
MODULE_VERSION("1.0");
