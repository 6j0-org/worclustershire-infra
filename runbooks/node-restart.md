# Restarting a node

# Overview

Use this for a planned stop/start of one node's VM, for example to apply a pending Proxmox disk change
(`qm pending 100`) or for host maintenance. Each node is VM 100 on its own Proxmox host (see `AGENTS.md` →
Host notes). Restart **one node at a time**, and don't start the next until every Longhorn volume is healthy
again.

A plain `qm shutdown && qm start` is not enough, because of two things:

- **Single-instance databases block the drain.** CloudNativePG gives a 1-instance cluster a primary PDB with
  `ALLOWED DISRUPTIONS 0`, so `kubectl drain` can never evict it. If you shut the VM down anyway, Talos
  takes more than 5 minutes to stop Postgres. Then Longhorn's iSCSI device goes away *before* the database
  filesystem is unmounted:
  ```
  dmcrypt_write/2: attempt to access beyond end of device
  Aborting journal on device dm-3-8.
  JBD2: I/O error when updating journal superblock for dm-3-8.
  ```
  Postgres then starts with `database system was not properly shut down; automatic recovery in progress`.
  On 2026-11-01 it recovered cleanly, but don't rely on that.
- **The volume stays attached to the stopped node.** Until that node's kubelet comes back and confirms the
  unmount, the rescheduled database pod sits in `Init` with
  `Multi-Attach error ... Volume is already exclusively attached to one node`.

# Before you start

1. Every Longhorn volume is healthy and no rebuild is running:
   ```
   kubectl -n longhorn-system get volumes.longhorn.io --no-headers -o custom-columns=R:.status.robustness | sort | uniq -c
   ```
1. Find PDBs that can never be satisfied (`ALLOWED DISRUPTIONS 0`). Longhorn's `instance-manager-*` PDBs
   are expected to be in this list. Longhorn drops them during the drain, once the node holds no volume
   that would lose its last replica.
   ```
   kubectl get pdb -A --no-headers | awk '$5==0'
   ```
1. Find the CloudNativePG clusters with a primary on the node you're restarting:
   ```
   kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,INST:.spec.instances,PRIMARY:.status.currentPrimary
   kubectl get pods -A -l cnpg.io/instanceRole=primary -o wide
   ```
1. Check that the large snapshots have checksums. If any snapshot listed here has an empty `sum=`, the
   rebuild of that volume will copy the whole snapshot (about an hour for `immich-library-pvc`) instead of
   taking seconds. See Notes → Fast rebuilds.
   ```
   kubectl -n longhorn-system get snapshots.longhorn.io -o json \
     | jq -r '.items[]|select(.status.size>10737418240)|"\(.spec.volume) \(.metadata.name) \(.status.size/1073741824|floor)GiB sum=\(.status.checksum//"")"'
   ```

# Procedure

`<node>` is `worclustershire{1,2,3}`; `<host>` is that node's Proxmox host IP.

1. **Put every affected 1-instance CloudNativePG cluster into maintenance mode.** This removes its PDB, so
   the drain can delete the pod and it restarts on another node, reusing the same PVC. The app is down
   while that happens (a minute or two), but Postgres shuts down cleanly first.
   ```
   kubectl -n immich patch clusters.postgresql.cnpg.io immich-database --type merge \
     -p '{"spec":{"nodeMaintenanceWindow":{"inProgress":true,"reusePVC":true}}}'
   ```
   These clusters are managed by Flux (`worclustershire-deploy`), but it applies with server-side apply and
   doesn't own this field, so the patch stays until you remove it (step 6).
1. **Drain:**
   ```
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=10m
   ```
   - `Cannot evict pod as it would violate the pod's disruption budget` for `instance-manager-*` or envoy
     pods is normal at first. The drain retries every 5s, and they go once their dependants have moved.
   - If the drain times out waiting on a pod that has a `deletionTimestamp` from long ago and a container
     that has already exited (a pod object the kubelet never removed), check its replacement is running
     elsewhere, then
     `kubectl -n <ns> delete pod <pod> --force --grace-period=0`.
   - Check that only DaemonSet and control-plane pods are left:
     `kubectl get pods -A --field-selector spec.nodeName=<node>`
1. **Stop and start the VM.** Use `;`, not `&&`, so the start still runs if the shutdown times out. If you
   use `&&` and the shutdown fails (`VM quit/powerdown failed`), the start is skipped and the VM ends up
   stopped.
   ```
   ssh root@<host> 'qm shutdown 100 --timeout 600; qm status 100; qm start 100; qm pending 100 | grep scsi0'
   ```
   A reboot from inside the guest does *not* apply pending Proxmox config. It needs a real stop and start.
   `swtpm_setup: Not overwriting existing state file.` is expected: the TPM state, which holds the LUKS
   keys, is kept.
1. **Wait for the node, then uncordon it.** Longhorn's instance-manager won't start on the node while it's
   cordoned.
   ```
   kubectl wait --for=condition=Ready node/<node> --timeout=10m && kubectl uncordon <node>
   ```
1. **Wait for Longhorn to catch up.** Every volume with a replica on that node is `degraded` until the
   replica is rebuilt. With checksums in place this takes seconds. Without them, small volumes take
   minutes and `immich-library-pvc` (~500GB) takes about an hour (see Notes → Fast rebuilds).
   ```
   kubectl -n longhorn-system get engines.longhorn.io -o json \
     | jq -c '.items[] | select(.status.rebuildStatus != {}) | {v:.spec.volumeName, r:[.status.rebuildStatus[]|{progress,error}]}'
   ```
1. **Take the CloudNativePG clusters out of maintenance mode:**
   ```
   kubectl -n immich patch clusters.postgresql.cnpg.io immich-database --type json \
     -p '[{"op":"remove","path":"/spec/nodeMaintenanceWindow"}]'
   ```

# Notes

- **Fast rebuilds.** Longhorn's fast replica rebuild (`fast-replica-rebuild-enabled: true`) skips any
  snapshot whose checksum matches on both sides, so only data written since that snapshot is copied. On
  2026-11-02, `immich-library-pvc` rebuilt in **5 seconds** with a checksum on its 465GiB snapshot,
  against about an hour without one, when every block is compared over the 1Gbps LAN.
- **When checksums are calculated.** The weekly checksum run is Saturday 20:00 UTC
  (`snapshotDataIntegrityCronjob: "0 20 * * 6"` in `worclustershire-deploy` `apps/longhorn/values.yaml`).
  Hashing `immich-library-pvc` takes about 1-2 hours per node: on 2026-11-01 it took 54 minutes on lorcan
  and about 1h50m on basima and ilona, all three hashing at once.
- **The daily backup removes the checksums.** The `daily-backup` recurring job runs at 16:00 UTC and
  finishes by about 16:20. It takes a new snapshot and deletes the previous one
  (`auto-cleanup-recurring-job-backup-snapshot`). Deleting a snapshot merges its data into a neighbour that
  has no checksum. (Confirmed on 2026-11-02, when the backup still ran at 02:00 UTC: by 02:07Z, the 465GiB
  and 37GiB snapshots checksummed the day before had been merged into new `daily-ba-*` snapshots with no
  checksum.) So fast rebuilds are only possible from when the Saturday run finishes until the Sunday
  16:00 UTC backup. Plan updates for that window: see [updating.md](updating.md).
- **For an unplanned restart, start a run by hand.** After the day's backup has finished, set the cron to a
  minute or two from now (for example `23 16 * * *` for 16:23 UTC). Wait for every large snapshot to show a
  `sum=` (step 4 of Before you start), then set it back to `0 20 * * 6`. The Helm chart now sets this
  value in the `longhorn-default-setting` ConfigMap, and Longhorn may reapply that over a hand edit. If
  hashing never starts, check the setting again
  (`kubectl -n longhorn-system get settings.longhorn.io snapshot-data-integrity-cronjob -o jsonpath='{.value}'`).
  ```
  kubectl -n longhorn-system patch settings.longhorn.io snapshot-data-integrity-cronjob --type merge \
    -p '{"value":"{\"v1\":\"23 16 * * *\",\"v2\":\"23 16 * * *\"}"}'
  ```
  `instance-manager` logs on each node show the run's progress (`Starting hashing snapshot <name>`, then
  `Snapshot <name> checksum <sum>` when done). A snapshot CR's checksum stays blank until every replica's
  hash matches. See [updating.md](updating.md) → Is the checksum done?
- Never restart two nodes at once. Every volume has 3 replicas, one per node, so two nodes down leaves a
  single copy.

# History

| Date (UTC) | Event                                                                                                                                                                                                                                                                                                     |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-11-01 | worclustershire1 and worclustershire2 restarted to apply `discard=on,ssd=1`. On worclustershire2, the immich-database PDB blocked the drain; `qm shutdown` timed out, `&&` skipped `qm start`, the database's ext4 journal was aborted, and Postgres crash-recovered. This runbook was written from that. |
| 2026-11-01 | Snapshot checksums started by hand (cron set to `23 16 * * *`, then put back to `0 0 */7 * *`). Hashing the 465GiB immich snapshot took 54 minutes to 1h50m per node.                                                                                                                                     |
| 2026-11-02 | lorcan/worclustershire2 restarted with checksums in place: `immich-library-pvc` rebuilt in 5 s (00:56:53-00:56:58 UTC).                                                                                                                                                                                   |
| 2026-11-02 | ilona host rebooted at 01:20 UTC for a package update without a drain. The immich database crash-recovered. All 15 volumes stayed degraded because worclustershire3's disk was under the 25% minimum; after lowering it to 20%, every volume rebuilt by 02:02:46, and immich in 5 s.                      |
