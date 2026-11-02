# Updating the cluster

# Overview

Use this for anything that restarts nodes: Proxmox host package updates (which usually need a host reboot), Talos
upgrades, and Kubernetes upgrades. Every update restarts each node once, and each restart makes Longhorn rebuild
that node's replicas.

When you do it matters. Rebuilding `immich-library-pvc` (~500GB) takes **about 5 seconds** when its big snapshot
has a checksum, and **about an hour** when it doesn't. Fast replica rebuild skips any snapshot whose checksum
matches on both sides. Checksums only exist for part of each week, so schedule updates for that window.

# When to update

**Saturday afternoon, once the weekly checksum run has finished, until Sunday 08:00 Pacific.**

Both jobs are defined in `worclustershire-deploy` (`apps/longhorn/`) and scheduled in UTC:

| UTC             | Pacific (PST; PDT is +1h) | Event                                                                                                        |
| --------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Daily 16:00     | Daily 08:00               | `daily-backup` recurring job. Done by about 08:20.                                                           |
| Saturday 20:00  | Saturday 12:00            | Snapshot checksum run (`snapshotDataIntegrityCronjob`, `0 20 * * 6`). Takes 1-2 hours per node.              |
| Saturday ~22:00 | Saturday ~14:00           | **Window opens**, once the checksum check below passes.                                                      |
| Sunday 16:00    | Sunday 08:00              | **Window closes.** The backup's cleanup merges the checksummed snapshot into a new one that has no checksum. |

Start the last node restart by about Sunday 07:00 Pacific, so its rebuild finishes before the backup. Never
restart a node while a backup is running.

The window fits all three nodes. A replica rebuild doesn't remove the checksum, so after the first node restarts
the next one still rebuilds in seconds. On 2026-11-02, lorcan and then ilona were restarted an hour apart, and
both rebuilt the immich volume in about 5 seconds.

Outside the window, an update still works, but expect about an hour of rebuilding per node. If an update can't
wait, run the checksum by hand first; see Notes → Fast rebuilds in [node-restart.md](node-restart.md).

# Is the checksum done?

1. Every large snapshot has a checksum:

   ```
   kubectl -n longhorn-system get snapshots.longhorn.io -o json \
     | jq -r '.items[]|select(.status.size>10737418240)|"\(.spec.volume) \(.metadata.name) \(.status.size/1073741824|floor)GiB sum=\(.status.checksum//"")"'
   ```

   Every line needs a value after `sum=`. A blank `sum=` means either hashing is still running, or this
   snapshot was created after the last checksum run, in which case the window has closed.

   The snapshot CR's checksum stays blank until every replica has finished hashing and all the hashes match.
   The immich snapshot takes about 1 hour on lorcan and about 2 hours on basima and ilona.

1. If it's still blank, check that hashing is actually running. Each node's `instance-manager` logs
   `Starting hashing snapshot <name>` when it starts, and `Snapshot <name> checksum <sum>` when it's done:

   ```
   for n in worclustershire1 worclustershire2 worclustershire3; do
     IM=$(kubectl -n longhorn-system get pod -l longhorn.io/component=instance-manager --field-selector spec.nodeName=$n -o name | head -1)
     echo "== $n"; kubectl -n longhorn-system logs $IM --since=6h | grep -E 'Starting hashing snapshot|checksum [0-9a-f]{16}' | tail -4
   done
   ```

   A node that logged `Starting` but not `checksum` is still hashing. Nothing in the logs on any node since
   Saturday 20:00 UTC means the run didn't start. Check the setting:
   `kubectl -n longhorn-system get settings.longhorn.io snapshot-data-integrity-cronjob -o jsonpath='{.value}'`

1. No backup is running:

   ```
   kubectl -n longhorn-system get backups.longhorn.io --no-headers -o custom-columns=N:.metadata.name,S:.status.state | grep -v Completed
   ```

1. Every volume is healthy:

   ```
   kubectl -n longhorn-system get volumes.longhorn.io --no-headers -o custom-columns=R:.status.robustness | sort | uniq -c
   ```

# Updating

One node at a time. Repeat the snapshot check above before each node, and don't start the next node until every
volume is healthy again.

Every update follows [node-restart.md](node-restart.md). Only step 3, which restarts the VM, changes depending on
what you're updating:

- **Proxmox host packages:** do node-restart steps 1-2 (CloudNativePG maintenance window, drain). Then, on the host,
  shut the VM down cleanly before rebooting, rather than leaving that to the host's shutdown:

  ```
  ssh root@<host> 'apt update && apt full-upgrade'
  ssh root@<host> 'qm shutdown 100 --timeout 600; qm status 100; reboot'
  ```

  VM 100 has `onboot: 1`, so it starts again when the host comes back. Continue with node-restart steps 4-6.
  Rebooting a host without draining first is what happened on ilona on 2026-11-02 01:20 UTC: the immich database
  crash-recovered, and every volume was degraded until the replicas were rebuilt.

- **Talos:** do node-restart steps 1-2, then run the upgrade from README.md → Upgrading Talos
  (`talosctl upgrade ... --preserve`, one minor version at a time). The node reboots itself. Continue with
  node-restart steps 4-6.

- **Proxmox VM config** (anything `qm pending 100` shows): node-restart as written.

Once all three nodes are done, run node-restart step 6 (end the CloudNativePG maintenance window) if you haven't
already, and do a final volume health check.

# History

| Date (UTC) | Event                                                                                                                                                                                         |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-11-02 | Backup moved from 02:00 to 16:00 UTC, and the checksum run from `0 0 */7 * *` to Saturday 20:00 UTC, so checksums survive long enough to use. Runbook written after ilona's unplanned reboot. |
