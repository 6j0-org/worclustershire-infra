# Proxmox thin pool full

# Overview

Each node's Talos system disk is a thin-provisioned Proxmox volume. Longhorn, inside the VM, only sees the
virtual disk's size, not how much space the host's thin pool actually has. If the pool runs out, the VM's
writes fail, Proxmox pauses the VM with `io-error`, and the host itself can hang. Host-specific details for
`worclustershire3` are in [README.ilona.md](../README.ilona.md).

# Symptoms

- Longhorn: a volume stuck `degraded` with `Replica Scheduling Failure` /
  `precheck new replica failed: insufficient storage`. Or a replica rebuild that dies partway, often with the
  node going `NotReady` a few minutes into the rebuild.
- Kubernetes: `Kubelet stopped posting node status`, and the node doesn't answer ping.
- Proxmox: the VM status is `io-error` (or the host is unreachable too).
- Host kernel log:
  ```
  dmeventd: WARNING: Thin pool pve-data-tpool data is now 100.00% full.
  device-mapper: thin: 252:4: switching pool to out-of-data-space (queue IO) mode
  device-mapper: thin: 252:4: switching pool to out-of-data-space (error IO) mode
  watchdog: BUG: soft lockup - CPU#6 stuck for 26s! ... Workqueue: writeback wb_workfn
  ```

# Diagnosis

On the Proxmox host:

```
pvesm status
lvs -a -o lv_name,lv_size,data_percent,metadata_percent pve
qm config <vmid> | grep -E '^(scsi|virtio|sata)'
journalctl -b -1 -k | grep -E 'thin|out-of-data-space|soft lockup'
```

The pool is the problem if `data` (`local-lvm`) is at or near 100% Data%, or if the pool's size is less than the
VM disk's size. If **Meta%** is the one that's full instead, extend the metadata
(`lvextend --poolmetadatasize +1G pve/data`) rather than following the steps below.

Don't trust the guest's free space. `df` inside the VM can show hundreds of GB free while the pool is full,
because TRIM doesn't pass through Talos's LUKS volumes (see README.ilona.md → Discard / TRIM).

# Recovery

1. **Keep the VM stopped**, and stop Longhorn from writing to that node as soon as it boots:
   ```
   kubectl -n longhorn-system patch nodes.longhorn.io <node> --type merge -p '{"spec":{"allowScheduling":false}}'
   # and drop the replica count on whichever volume was rebuilding there, e.g.:
   kubectl -n longhorn-system patch volumes.longhorn.io <pvc-...> --type merge -p '{"spec":{"numberOfReplicas":2}}'
   ```
1. **Make the pool larger than the VM disk.** Use VG free space (`vgs`), or add a disk to the VG. An LVM thin
   pool can't be shrunk later.
   ```
   lvextend -L +<N>G pve/data
   ```
   If there isn't enough VG space, free pool space instead: delete VM snapshots (`qm listsnapshot`), unused
   disks (`unusedN:` in `qm config`), or other VMs' disks on `local-lvm`. Package cache and `/var/lib/vz` are on
   `pve-root`, not the pool, so cleaning them doesn't help.
1. **Make sure discard is on** for the disk (takes effect on the next VM start):
   ```
   qm set <vmid> --scsi0 local-lvm:vm-<vmid>-disk-1,iothread=1,size=<size>,discard=on,ssd=1
   ```
1. Start the VM (`qm start <vmid>`, or `qm resume <vmid>` if it's paused rather than stopped), and wait for the
   node to be `Ready`.
1. **Delete the partial replica a failed rebuild leaves behind.** Longhorn doesn't track it as a Replica *or*
   an Orphan, so it won't clean it up. Compare the directories on disk with the live replicas:
   ```
   kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=<pvc-...> \
     -o jsonpath='{range .items[*]}{.spec.nodeID} {.spec.dataDirectoryName}{"\n"}{end}'
   IM=$(kubectl -n longhorn-system get pod -l longhorn.io/component=instance-manager \
     --field-selector spec.nodeName=<node> -o name | head -1)
   kubectl -n longhorn-system exec $IM -- sh -c 'du -sh /host/var/lib/longhorn/replicas/<pvc-...>-*'
   # rm -rf only the directory that no live replica lists
   ```
   This frees space inside the guest only, not in the pool (no TRIM passthrough).
1. Re-enable scheduling (`allowScheduling: true`) and restore the replica count. If Longhorn's own
   `storage-minimal-available-percentage` (25%) check blocks the rebuild, it can be lowered temporarily.
   The pool can no longer overflow once it's larger than the disk.

# History

| Date (UTC)              | Event                                                                                                                                                                                                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-10-31 – 2026-11-01 | worclustershire3 on ilona: two immich-library replica rebuilds (~500GB) filled a 794.6G pool behind an 800G disk; VM io-error, host soft lockup and crash. Pool extended to 809.6G, `discard=on` set, TRIM found blocked by LUKS. Details in README.ilona.md. |
