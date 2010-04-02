/*
 *  Atheros AP91 reference board PCI initialization
 *
 *  Copyright (C) 2009 Gabor Juhos <juhosg@openwrt.org>
 *
 *  This program is free software; you can redistribute it and/or modify it
 *  under the terms of the GNU General Public License version 2 as published
 *  by the Free Software Foundation.
 */

#ifndef _AR71XX_DEV_AP91_PCI_H
#define _AR71XX_DEV_AP91_PCI_H

#if defined(CONFIG_AR71XX_DEV_AP91_PCI)
void ap91_pci_init(u8 *cal_data, u8 *mac_addr) __init;
#else
static inline void ap91_pci_init(u8 *cal_data, u8 *mac_addr) { }
#endif

#endif /* _AR71XX_DEV_AP91_PCI_H */

