# README for lorcan

This server uses the e1000e NIC, which is apparently a big ol' piece of junk.

I had to edit /etc/network/interfaces and add this post-up line for ethtool:

```
iface nic0 inet manual
        # Adding because of e1000e hardware unit hang error
        post-up /sbin/ethtool -K nic0 tso off gso off
```

# Host

Proxmox host for `worclustershire2`. SSH: `ssh root@192.168.8.9`.

|         |                                                                                                    |
| ------- | -------------------------------------------------------------------------------------------------- |
| Proxmox | pve-manager 9.2.21, kernel 7.0.14-25-pve                                                           |
| Disk    | 1x Samsung 970 EVO Plus NVMe, 931.5G (`/dev/nvme0n1`), the only disk                               |
| LVM     | VG `pve` on `nvme0n1p3`: `root` 96G, `swap` 8G, thin pool `data` (`local-lvm`) 809.3G, ~1G VG free |
| VMs     | `100` `worclustershire2` - the only VM on this host                                                |

VM 100 has the same disk layout as on ilona: `efidisk0` (`vm-100-disk-0`), `tpmstate0` (`vm-100-disk-2`, holds the
LUKS keys - do not delete), and the 800G Talos system disk `scsi0` (`vm-100-disk-1`), all in `local-lvm`.

# Storage

The same thin-pool rule and TRIM limitation apply as on ilona. See
[README.ilona.md](README.ilona.md#rule-the-thin-pool-must-be-larger-than-the-vm-disk) and
[runbooks/thin-pool-full.md](runbooks/thin-pool-full.md).

The pool was 794.3G behind an 800G disk (79% used). It was extended on 2026-11-01:

```
lvextend -L +15G pve/data        # 794.3G -> 809.3G
qm set 100 --scsi0 local-lvm:vm-100-disk-1,iothread=1,size=800G,discard=on,ssd=1
```

`discard=on,ssd=1` was applied by a VM stop/start on 2026-11-01 (see
[runbooks/node-restart.md](runbooks/node-restart.md)); the guest's `sda` now reports discard support. It frees nothing until Talos allows discards through
LUKS, but it needs to be in place first.

# History

| Date (UTC) | Event                                                                                                    |
| ---------- | -------------------------------------------------------------------------------------------------------- |
| 2026-11-01 | Found pool 794.3G < 800G disk, 79% used; extended to 809.3G; `discard=on,ssd=1` queued (pending restart) |
| 2026-11-01 | VM 100 stopped/started; `discard=on,ssd=1` now active                                                    |
