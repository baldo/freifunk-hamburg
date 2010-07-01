/*
 * Realtek RTL8366 SMI interface driver defines
 *
 * Copyright (C) 2009-2010 Gabor Juhos <juhosg@openwrt.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 as published
 * by the Free Software Foundation.
 */

#ifndef _RTL8366_SMI_H
#define _RTL8366_SMI_H

#include <linux/phy.h>

struct rtl8366_smi_ops;
struct rtl8366_vlan_ops;
struct mii_bus;
struct dentry;
struct inode;
struct file;

struct rtl8366_smi {
	struct device		*parent;
	unsigned int		gpio_sda;
	unsigned int		gpio_sck;
	spinlock_t		lock;
	struct mii_bus		*mii_bus;
	int			mii_irq[PHY_MAX_ADDR];

	unsigned int		cpu_port;
	unsigned int		num_ports;
	unsigned int		num_vlan_mc;

	struct rtl8366_smi_ops	*ops;

	char			buf[4096];
#ifdef CONFIG_RTL8366S_PHY_DEBUG_FS
	struct dentry           *debugfs_root;
	u16			dbg_reg;
#endif
};

struct rtl8366_vlan_mc {
	u16	vid;
	u8	priority;
	u8	untag;
	u8	member;
	u8	fid;
};

struct rtl8366_vlan_4k {
	u16	vid;
	u8	untag;
	u8	member;
	u8	fid;
};

struct rtl8366_smi_ops {
	int	(*detect)(struct rtl8366_smi *smi);

	int	(*mii_read)(struct mii_bus *bus, int addr, int reg);
	int	(*mii_write)(struct mii_bus *bus, int addr, int reg, u16 val);

	int	(*get_vlan_mc)(struct rtl8366_smi *smi, u32 index,
			       struct rtl8366_vlan_mc *vlanmc);
	int	(*set_vlan_mc)(struct rtl8366_smi *smi, u32 index,
			       const struct rtl8366_vlan_mc *vlanmc);
	int	(*get_vlan_4k)(struct rtl8366_smi *smi, u32 vid,
			       struct rtl8366_vlan_4k *vlan4k);
	int	(*set_vlan_4k)(struct rtl8366_smi *smi,
			       const struct rtl8366_vlan_4k *vlan4k);
	int	(*get_mc_index)(struct rtl8366_smi *smi, int port, int *val);
	int	(*set_mc_index)(struct rtl8366_smi *smi, int port, int index);
};

int rtl8366_smi_init(struct rtl8366_smi *smi);
void rtl8366_smi_cleanup(struct rtl8366_smi *smi);
int rtl8366_smi_write_reg(struct rtl8366_smi *smi, u32 addr, u32 data);
int rtl8366_smi_read_reg(struct rtl8366_smi *smi, u32 addr, u32 *data);
int rtl8366_smi_rmwr(struct rtl8366_smi *smi, u32 addr, u32 mask, u32 data);

int rtl8366_set_vlan(struct rtl8366_smi *smi, int vid, u32 member, u32 untag,
		     u32 fid);
int rtl8366_reset_vlan(struct rtl8366_smi *smi);
int rtl8366_get_pvid(struct rtl8366_smi *smi, int port, int *val);
int rtl8366_set_pvid(struct rtl8366_smi *smi, unsigned port, unsigned vid);

#ifdef CONFIG_RTL8366S_PHY_DEBUG_FS
int rtl8366_debugfs_open(struct inode *inode, struct file *file);
#endif

#endif /*  _RTL8366_SMI_H */
