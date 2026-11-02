# README for basima

Proxmox host for `worclustershire1`. SSH: `ssh root@192.168.8.3`.

|         |                                                                                               |
| ------- | --------------------------------------------------------------------------------------------- |
| Proxmox | pve-manager 9.2.24, kernel 7.0.14-26-pve                                                      |
| Disk    | 1x Crucial MX500 SATA SSD, 931.5G (`/dev/sda`), the only disk                                 |
| LVM     | VG `pve` on `sda3`: `root` 96G, `swap` 8G, thin pool `data` (`local-lvm`) 808.8G, ~1G VG free |
| VMs     | `100` `worclustershire1` - the only VM on this host                                           |

VM 100 has the same disk layout as on ilona: `efidisk0` (`vm-100-disk-0`), `tpmstate0` (`vm-100-disk-2`, holds the
LUKS keys - do not delete), and the 800G Talos system disk `scsi0` (`vm-100-disk-1`), all in `local-lvm`.

## Storage

The same thin-pool rule and TRIM limitation apply as on ilona. See
[README.ilona.md](README.ilona.md#rule-the-thin-pool-must-be-larger-than-the-vm-disk) and
[runbooks/thin-pool-full.md](runbooks/thin-pool-full.md).

The pool was 793.8G behind an 800G disk, and at 93% (~56G free) while Longhorn inside the VM thought ~220G was
free. It was the closest of the three hosts to the failure that took down ilona. It was extended on 2026-11-01:

```
lvextend -L +15G pve/data        # 793.8G -> 808.8G
qm set 100 --scsi0 local-lvm:vm-100-disk-1,iothread=1,size=800G,discard=on,ssd=1
```

`discard=on,ssd=1` was applied by a VM stop/start on 2026-11-01 (see
[runbooks/node-restart.md](runbooks/node-restart.md)); the guest's `sda` now reports discard support. It frees nothing until Talos allows discards through
LUKS, but it needs to be in place first.

## History

| Date (UTC) | Event                                                                                                    |
| ---------- | -------------------------------------------------------------------------------------------------------- |
| 2026-11-01 | Found pool 793.8G < 800G disk, 93% used; extended to 808.8G; `discard=on,ssd=1` queued (pending restart) |
| 2026-11-01 | VM 100 stopped/started; `discard=on,ssd=1` now active                                                    |
