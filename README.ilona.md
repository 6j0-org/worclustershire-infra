# README for ilona

Proxmox host for `worclustershire3`. SSH: `ssh root@192.168.8.8`.

|         |                                                                                                      |
| ------- | ---------------------------------------------------------------------------------------------------- |
| Proxmox | pve-manager 9.2.21, kernel 7.0.14-25-pve                                                             |
| Disk    | 1x Sabrent Rocket Q NVMe, 931.5G (`/dev/nvme0n1`), the only disk                                     |
| LVM     | VG `pve` on `nvme0n1p3`: `root` 96G, `swap` 7.7G, thin pool `data` (`local-lvm`) 809.6G, ~1G VG free |
| VMs     | `100` `worclustershire3` - the only VM on this host                                                  |

## VM 100 (worclustershire3) disks

All three disks live in the `local-lvm` thin pool:

| Disk        | Volume          | Size | Purpose                                                                      |
| ----------- | --------------- | ---- | ---------------------------------------------------------------------------- |
| `efidisk0`  | `vm-100-disk-0` | 4M   | OVMF vars                                                                    |
| `tpmstate0` | `vm-100-disk-2` | 4M   | TPM state - holds the LUKS keys for Talos `STATE`/`EPHEMERAL`, do not delete |
| `scsi0`     | `vm-100-disk-1` | 800G | Talos system disk; `/var` (and so `/var/lib/longhorn`) is on it              |

Current `scsi0` line (changed 2026-11-01, see below):

```
scsi0: local-lvm:vm-100-disk-1,discard=on,iothread=1,size=800G,ssd=1
```

## Rule: the thin pool must be larger than the VM disk

The 800G `scsi0` disk is thin-provisioned. Inside the VM, Longhorn sees an ~856GB disk and schedules replicas
against it. It has no idea how much space the *host* actually has. If the pool is smaller than the disk, a
large Longhorn write (a replica rebuild, ~500GB for the immich library) fills the pool. The VM then goes into
`io-error`, and the host can soft-lock in writeback. See
[runbooks/thin-pool-full.md](runbooks/thin-pool-full.md).

Keep `pve/data` larger than the sum of every disk in it (today: 809.6G pool vs ~800G of disks). Don't grow
`scsi0`, and don't add VMs or disks to `local-lvm`, unless the pool grows first. The VG has ~1G free, so
growing the pool means adding a physical disk.

Thin pool autoextend is effectively off (`thin_pool_autoextend_threshold=100`), and there's no VG space for it
to use anyway.

## Discard / TRIM

Setting `discard=on` on `scsi0` makes the virtual disk accept TRIM (the guest's `sda` reports
`discard_max_bytes=1073741824`, and the pool has `Discards: passdown`). **TRIM still doesn't reach the pool.**
Talos opens the `STATE` and `EPHEMERAL` LUKS2 volumes (`sda3-encrypted`, `sda4-encrypted`) without
allow-discards, so they report `discard_max=0` and `fstrim` fails:

```
fstrim: /host/var: the discard operation is not supported
```

So space freed inside the VM (deleted replicas, images, logs) is never returned to the pool. The pool stays at
~98% allocated, even though the guest's `/var` is only ~20% used. That is safe *only* because of the rule above:
the most the pool can still grow is the disk's unallocated remainder (~4G).

To fix it properly: Talos `VolumeConfig` has `encryption.allowDiscards: true` (documented in the
[v1.14 reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/block/volumeconfig.md), not in
v1.11). This needs a Talos upgrade from v1.11.5 first, one minor version at a time with `--preserve`. Then set it
for `EPHEMERAL` (and `STATE`) in place of the `systemDiskEncryption` block in `tpm-disk-encryption.yaml`. The
docs describe it as applying when the volume is opened, so a reboot should be enough (untested). Afterwards
verify with:

```
# from a privileged pod on the node, e.g. the Longhorn instance-manager on worclustershire3
cat /sys/block/dm-1/queue/discard_max_bytes    # must be > 0
fstrim -v /host/var
# then on ilona - Data% should drop toward the guest's real usage
lvs -o lv_name,data_percent pve/data pve/vm-100-disk-1
```

## Checking it

```
pvesm status                                                  # local-lvm % used
lvs -o lv_name,lv_size,data_percent,metadata_percent,discards pve
qm config 100 | grep ^scsi0
qm status 100 --verbose | grep -E '^(status|qmpstatus|io-status)'
journalctl -k | grep -E 'thin|out-of-data-space'
```

## History

| Date (UTC)              | Event                                                                                                                    |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| 2026-10-31 23:48        | Longhorn rebuild of the immich library replica fills the thin pool (pool 794.6G < 800G disk); worclustershire3 goes down |
| 2026-11-01 00:53, 01:13 | Host reboots; pool still `100.00% full` at boot                                                                          |
| 2026-11-01 02:55        | Second rebuild: `switching pool to out-of-data-space (error IO) mode`; VM io-error                                       |
| 2026-11-01 03:41        | Host `soft lockup ... Workqueue: writeback`, then crash; rebooted 04:31                                                  |
| 2026-11-01              | `lvextend -L +15G pve/data` (794.6G → 809.6G); `qm set 100 --scsi0 ...,discard=on,ssd=1`; `fstrim` found blocked by LUKS |
