# Rotating expired admin certificates

# Overview

Talos issues two long-lived *client* certificates when the cluster is first generated, and **neither one
auto-rotates**:

| Credential                                               | Certificate subject          | Issued by                           | Lifetime |
| -------------------------------------------------------- | ---------------------------- | ----------------------------------- | -------- |
| `talosconfig.sops.yaml`                                  | `O=os:admin`                 | the `os` CA in `secrets.sops.yaml`  | 1 year   |
| `~/.kube/worclustershire` (merged into `~/.kube/config`) | `O=system:masters, CN=admin` | the `k8s` CA in `secrets.sops.yaml` | 1 year   |

Everything else on the cluster *does* rotate by itself - kube-apiserver serving certs, etcd peer certs and
kubelet certs are all managed by Talos and are good for years. So when access breaks roughly a year after
bootstrap, it is almost always these two client certs and nothing else.

Because both CAs live in `secrets.sops.yaml`, rotation is an **offline** operation. You do not need working
credentials to fix broken credentials, and you do not need to touch the nodes.

# Symptoms

`kubectl` fails with a 401 - the apiserver rejects the expired client cert, falls back to anonymous, and
asks for credentials that were in fact supplied:

```
E0923 12:24:50.645055   74219 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list: the server has asked for the client to provide credentials"
error: You must be logged in to the server (the server has asked for the client to provide credentials)
```

`talosctl` fails separately, with a TLS error rather than a 401, because its cert expired at the same time.

# Diagnosis

1. Check the Kubernetes admin cert in the merged kubeconfig:
   ```
   kubectl config view --raw -o jsonpath='{.users[?(@.name=="admin@worclustershire")].user.client-certificate-data}' \
     | base64 -d | openssl x509 -noout -subject -issuer -dates
   ```
1. Check the Talos admin cert, without decrypting to disk:
   ```
   sops -d talosconfig.sops.yaml | grep -oP '(?<=crt: ).*' | head -1 \
     | base64 -d | openssl x509 -noout -subject -dates
   ```
1. Confirm the cluster itself is healthy before rotating anything. The serving certs should be valid for
   years, and the Talos API should answer on every node:
   ```
   for ip in 192.168.8.4 192.168.8.5 192.168.8.6 192.168.8.7; do
     printf '%-14s ' "$ip"
     timeout 5 openssl s_client -connect ${ip}:6443 -servername kubernetes </dev/null 2>/dev/null \
       | openssl x509 -noout -subject -enddate | tr '\n' ' '
     echo
   done

   for ip in 192.168.8.4 192.168.8.5 192.168.8.6; do
     printf 'talos-api %-14s ' "$ip"
     timeout 4 bash -c "</dev/tcp/$ip/50000" 2>/dev/null && echo open || echo unreachable
   done
   ```
   If the serving certs are valid and the ports are open, the nodes are fine and only your client
   credentials need replacing.

# Rotation

Do these in order. The talosconfig must be rotated **first**, because step 2 authenticates to the Talos API
with it.

1. Regenerate `talosconfig.sops.yaml` from the `os` CA. Piping through `sops encrypt` with
   `--filename-override` means plaintext never lands on disk - the override is what lets sops match the
   `^.*\.sops\.yaml$` creation rule in `.sops.yaml` while reading from stdin:
   ```
   talosctl gen config --with-secrets <(sops -d secrets.sops.yaml) \
     -t talosconfig -o - worclustershire https://192.168.8.7:6443 \
     | sops encrypt --filename-override talosconfig.sops.yaml /dev/stdin > /tmp/tc.new \
     && mv /tmp/tc.new talosconfig.sops.yaml
   ```
   Write to a temp file and `mv` rather than redirecting straight onto `talosconfig.sops.yaml`; a failure
   mid-pipeline would otherwise truncate the only copy you have outside git.
1. Regenerate the kubeconfig from a live node, using the talosconfig you just rebuilt:
   ```
   talosctl kubeconfig --talosconfig <(sops -d talosconfig.sops.yaml) \
     -n 192.168.8.4 -e 192.168.8.4 ~/.kube/worclustershire --force
   ```
1. Re-merge into `~/.kube/config` (same command as the bootstrap flow in `README.md`):
   ```
   cp ~/.kube/config ~/.kube/config.$(date +%s) && export KUBECONFIG=$(find "${HOME}/.kube" -maxdepth 1 -type f ! -name config ! -name 'config.*' | tr "\n" ":"); kubectl config view --flatten > ~/.kube/config; chmod 600 ~/.kube/config; unset KUBECONFIG;
   ```
1. Verify both new certs and the restored access:
   ```
   sops -d talosconfig.sops.yaml | grep -oP '(?<=crt: ).*' | head -1 | base64 -d | openssl x509 -noout -dates
   kubectl config view --raw -o jsonpath='{.users[?(@.name=="admin@worclustershire")].user.client-certificate-data}' | base64 -d | openssl x509 -noout -dates
   kubectl get ns
   ```
1. Commit the new `talosconfig.sops.yaml`. Confirm with `git status` that nothing else is staged and that no
   file in the tree is sitting decrypted - `.gitignore` is empty, so nothing stops a plaintext CA from being
   committed.

# Notes

- The regenerated talosconfig keeps `endpoints: []`, same as the original, so `talosctl` still needs an
  explicit `-e`/`--endpoints` on every invocation.
- `talosctl gen config` only reads `secrets.sops.yaml`; the cluster name and endpoint arguments must match
  what the cluster was bootstrapped with (`worclustershire`, `https://192.168.8.7:6443`) or you will mint a
  config for a cluster that does not exist. The other `gen config` flags (install image, disk, patches) are
  irrelevant here because `-t talosconfig` only emits the client config.
- Step 3 rebuilds `~/.kube/config` from every sibling file in `~/.kube`, so contexts that exist only in
  `config` itself would be dropped. It backs up to `~/.kube/config.<epoch>` first - check the context list
  afterwards with `kubectl config get-contexts`.
- The node-side certs are not involved. There is no need to `apply-config`, reboot, or upgrade anything.

# History

| Date       | Event                                                                         |
| ---------- | ----------------------------------------------------------------------------- |
| 2025-09-22 | Cluster bootstrapped; both admin certs issued, expiring 2026-09-22            |
| 2026-09-22 | Both certs expired ~4 minutes apart; `kubectl` and `talosctl` both locked out |
| 2026-09-23 | Rotated per the procedure above; both certs now expire 2027-09-23             |

**Next expiry: 2027-09-23.**
