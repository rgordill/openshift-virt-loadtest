# OpenShift Virt Load Test — Azure Bootstrap

Bootstrap an Azure OpenShift Container Platform (OCP) cluster for OpenShift Virtualization load testing:

1. Dedicated **infra** nodes (router, registry, monitoring, GitOps)
2. OpenShift **GitOps** (Argo CD) on infra nodes
3. Dedicated **storage** nodes and **OpenShift Data Foundation** (ODF)
4. Regular **worker** nodes for kube-burner / OpenShift Virtualization load tests
5. Root **app-of-apps** with cluster-agnostic configuration (ingress domain, default storage class, OCP version)

Start from a clean **installer-provisioned infrastructure (IPI)** cluster on Microsoft Azure.

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| OCP cluster | Azure IPI, healthy (`oc get co` all Available) |
| `oc` / `kubectl` | Client compatible with the cluster |
| `az` CLI | Prefer OpenShift installer SP at `~/.azure/osServicePrincipal.json` (used automatically); otherwise `az login` on the cluster subscription |
| `python3` | Used by setup scripts for MachineSet generation / JSON parsing |
| `kustomize` | For app-of-apps bootstrap (or `oc` / `kubectl` with kustomize support) |
| Cluster admin | Kubeconfig with `cluster-admin` |

```bash
export KUBECONFIG=/path/to/kubeconfig
```

Validated against **OCP 4.20** on Azure (`eastus`). Scripts discover region and zones from the live cluster.

## Architecture after bootstrap

```
┌─────────────────────────────────────────────────────────────┐
│  Control plane (masters) — 3 nodes                          │
│  Platform operators stay here                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Infra nodes — 1 per AZ (default)                           │
│  Taint: node-role.kubernetes.io/infra=reserved:NoSchedule   │
│  • Ingress routers                                          │
│  • Image registry                                           │
│  • Monitoring stack                                         │
│  • OpenShift GitOps / Argo CD                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Storage nodes — 1 per AZ (default)                         │
│  Label: cluster.ocs.openshift.io/openshift-storage          │
│  Taint: node.ocs.openshift.io/storage=true:NoSchedule       │
│  • ODF / Ceph OSDs, MONs, MCG                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Worker nodes — 1 per AZ (default), untainted               │
│  Label: node-role.kubernetes.io/worker                      │
│  SKU default: Standard_E32as_v6 (AMD memory-opt, 32 vCPU)   │
│  Nested virt: MachineConfig 80-enable-nested-virt           │
│  • kube-burner-ocp virt workloads / KubeVirt VMs            │
└─────────────────────────────────────────────────────────────┘
```

Default Azure VM sizes (overridable):

| Role | Parameter | Default |
|------|-----------|---------|
| Infra | `INFRA_VM_SIZE` | `Standard_D8s_v6` |
| Storage (ODF) | `ODF_VM_SIZE` | `Standard_D16s_v6` |
| Worker (kube-burner) | `WORKER_VM_SIZE` | `Standard_E32as_v6` (AMD, 32 vCPU / 256 GiB) |

Installer worker MachineSets are **scaled to 0 and deleted** after infra workloads move to infra nodes. Recreate capacity with `setup/workers/install.sh` before running kube-burner.

> **Subscription note:** Infra nodes are intended only for platform infrastructure workloads (router, registry, monitoring, GitOps, and similar). Under Red Hat OpenShift subscription rules, scheduling **user applications** on infra-labeled nodes can cause those nodes to be counted as normal **workers**. In production, keep apps (including Elasticsearch, Grafana, and other test tooling) off infra and on worker/application MachineSets. **This repository places Elasticsearch and Grafana on infra anyway** to simplify the load-test lab topology—treat that as a PoC convenience, not a recommended production pattern.

## Repository layout

```
setup/
  infra/          # Out-of-band: infra MachineSets + move platform workloads
  gitops/         # Out-of-band: OpenShift GitOps Operator (pinned to infra)
  storage/        # Out-of-band: ODF storage MachineSets + managed-csi-v2
  workers/        # Out-of-band: untainted workers for kube-burner / virt
argocd/
  main/           # Prerequisites + app-of-apps bootstrap
  manifests/
    cluster-objects/            # AppProject, RBAC, PostSync cluster-config hook
    applications/               # Child Applications / ApplicationSets
    openshift-virtualization/   # CNV operator + HyperConverged
    elasticsearch/              # ECK operator + instance
    grafana/                    # Grafana operator + instance
```

## Bootstrap order

```
Clean Azure IPI cluster
  → 1. setup/infra/install.sh
  → 2. setup/gitops/install.sh
  → 3. setup/storage/install.sh   # storage nodes + managed-csi-v2; install ODF separately
  → 4. setup/workers/install.sh   # untainted workers for kube-burner
  → 5. argocd/main/apply-prerequisites.sh
  → 6. argocd/main/bootstrap-app-of-apps.sh
  → (later) child apps via GitOps (CNV, Elasticsearch, Grafana, …)
```

Steps 1–4 are **out-of-band** (Machine API / ODF). Steps 5–6 wire Argo CD so day-2 workloads sync from this repository. **ODF itself is not managed by Argo CD** — install the operator and StorageCluster after storage nodes are Ready (console or CLI per the ODF docs).

---

## Step 0 — Verify the cluster

```bash
export KUBECONFIG=/path/to/kubeconfig

oc version
oc get clusterversion
oc get nodes -o wide
oc get machineset -n openshift-machine-api
oc get co
```

Confirm:

- Cluster version is available and not progressing
- Default topology (e.g. 3 masters + worker MachineSets) is Ready
- Cluster operators are healthy

Record region / zones from worker MachineSets or node labels (`topology.kubernetes.io/region`, `topology.kubernetes.io/zone`). Scripts use these automatically.

---

## Step 1 — Infrastructure nodes

Creates one infra MachineSet **per Azure availability zone** discovered from existing worker MachineSets (typically zones 1, 2, 3), moves platform infra workloads onto those nodes, then removes the original worker MachineSets.

Documentation reference: [Creating infrastructure machine sets (OCP 4.20)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/machine_management/creating-infrastructure-machinesets).

```bash
# Defaults from setup/infra/params.env
./setup/infra/install.sh

# Optional overrides
INFRA_VM_SIZE=Standard_D8s_v3 INFRA_REPLICAS=1 ./setup/infra/install.sh
```

What the script does (idempotent — safe to re-run after a partial or completed pass):

1. Discovers infrastructure ID, region, and zones from worker MachineSets (falls back to infra MachineSets if workers were already removed)
2. Authenticates `az` via `~/.azure/osServicePrincipal.json` when present (`setup/lib/azure-auth.sh`), then checks Azure SKU availability (`setup/infra/check-sku.sh`). Warns and continues if the API is unreachable; set `SKIP_SKU_CHECK=1` to skip
3. Creates or scales MachineSets named `<infraId>-infra-<region><zone>` with:
   - Label `node-role.kubernetes.io/infra`
   - Taint `node-role.kubernetes.io/infra=reserved:NoSchedule`
4. Moves workloads ([§8.14](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/machine_management/creating-infrastructure-machinesets)):
   - IngressController `default` (router)
   - Image registry `Config`
   - `cluster-monitoring-config` (monitoring stack)
5. Polls until movable pods are Running on infra nodes (ingress/registry up to **5m**, monitoring up to **15m** — Prometheus PVC remounts are slow)
6. Scales **all** worker MachineSets to `0`, waits for worker-only nodes to disappear, then **deletes** those MachineSets (no-op if already gone)
7. Annotates namespaces that ship without `openshift.io/node-selector` (notably `openshift-network-console`, per [OCPBUGS-56949](https://issues.redhat.com/browse/OCPBUGS-56949) / Red Hat solution) with `openshift.io/node-selector: ""`, then adds infra tolerations on networking Deployments so they can schedule after worker MachineSets are deleted
8. Runs a cluster health check

Verify:

```bash
oc get nodes -l node-role.kubernetes.io/infra
oc get machineset -n openshift-machine-api
# Expect infra MachineSets only (no worker MachineSets)
```

---

## Step 2 — OpenShift GitOps on infra nodes

Installs Red Hat OpenShift GitOps Operator (`latest` channel) and pins Argo CD + operator pods to infra nodes.

```bash
./setup/gitops/install.sh
```

What the script does:

1. Requires Ready infra nodes
2. Applies Namespace, OperatorGroup, Subscription under `setup/gitops/` (Subscription already pins operator pods to infra)
3. Waits for CSV Succeeded, then patches `GitopsService` `runOnInfra: true` + infra tolerations **before** waiting for Argo CD Available (needed when only tainted infra nodes remain)
4. Deletes `openshift-gitops-application-controller` pods after the StatefulSet template picks up infra placement (Deployments roll automatically; StatefulSet pods created earlier stay on the old revision and remain Pending without the infra toleration)
5. Waits for Argo CD Available (up to 10m) and verifies pods on infra
6. Prints the Argo CD route

Verify:

```bash
oc get pods -n openshift-gitops -o wide
oc get pods -n openshift-gitops-operator -o wide
# NODE should be infra nodes

oc get route openshift-gitops-server -n openshift-gitops
oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password
```

---

## Step 3 — ODF storage nodes

Creates dedicated storage MachineSets (one per zone) for OpenShift Data Foundation. Nodes are labeled and tainted so ODF schedules only there.

Documentation reference: [Deploying ODF using Microsoft Azure (4.20)](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/deploying_openshift_data_foundation_using_microsoft_azure/index).

```bash
# Defaults from setup/storage/params.env (Standard_D16s_v3 recommended)
./setup/storage/install.sh

ODF_VM_SIZE=Standard_D16s_v3 ODF_REPLICAS=1 ./setup/storage/install.sh
```

What the script does:

1. SKU-checks `ODF_VM_SIZE` in the cluster region / zones (same soft-fail behavior as infra)
2. Checks Azure disk SKU `PremiumV2_LRS` is available in the region / zones (`setup/storage/check-disk-sku.sh`)
3. Creates StorageClass **`managed-csi-v2`** from `setup/storage/managed-csi-v2-storageclass.yaml` (`disk.csi.azure.com`, `skuname: PremiumV2_LRS`, `cachingMode: None`) for ODF OSD PVCs
4. Creates MachineSets `<infraId>-storage-<region><zone>` with:
   - Labels: `node-role.kubernetes.io/storage`, `cluster.ocs.openshift.io/openshift-storage`
   - Taint: `node.ocs.openshift.io/storage=true:NoSchedule`
5. Waits until all storage nodes are Ready

Verify:

```bash
oc get nodes -l cluster.ocs.openshift.io/openshift-storage -o wide
oc get sc managed-csi-v2
```

ODF requires enough aggregate CPU/RAM across these nodes (docs: ~30 CPUs / 72 GiB for a full cluster; lean profiles may deploy with less). `Standard_D16s_v3` × 3 is the default sizing for a balanced Azure deployment.

After nodes are Ready, install **OpenShift Data Foundation** out-of-band (not via Argo CD) — Operator + StorageCluster in `openshift-storage`, with OSD PVCs on `managed-csi-v2`. See [Deploying ODF using Microsoft Azure (4.20)](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/deploying_openshift_data_foundation_using_microsoft_azure/index).

```bash
oc get csv -n openshift-storage
oc get storagecluster -n openshift-storage
oc get sc   # expect ocs-storagecluster-ceph-rbd, cephfs, noobaa, …
oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}{"\n"}'
```

---

## Step 4 — Worker nodes (kube-burner)

Recreates untainted worker MachineSets (one per AZ) for kube-burner-ocp / OpenShift Virtualization workloads. Run after infra has removed the installer workers.

Default SKU is **AMD memory-optimized** [`Standard_E32as_v6`](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/easv6-series) (32 vCPU / 256 GiB, nested virtualization supported). The script also applies MachineConfig `80-enable-nested-virt` so `/etc/modprobe.d/kvm.conf` sets `nested=1` for both `kvm_amd` and `kvm_intel` on the worker MachineConfigPool.

```bash
# Defaults from setup/workers/params.env (Standard_E32as_v6, 1 per zone)
./setup/workers/install.sh

# Larger AMD workers
WORKER_VM_SIZE=Standard_E48as_v6 WORKER_REPLICAS=1 ./setup/workers/install.sh

# Scale a single zone later
oc scale machineset <infraId>-worker-eastus1 -n openshift-machine-api --replicas=3
```

What the script does:

1. Applies `setup/workers/machineconfig-nested-virt.yaml` (worker role)
2. SKU-checks `WORKER_VM_SIZE` in the cluster region / zones
3. Creates or scales MachineSets `<infraId>-worker-<region><zone>` with:
   - Label `node-role.kubernetes.io/worker` only (no infra/storage taints)
   - MachineSet label `app.kubernetes.io/part-of=openshift-virt-loadtest` (so `setup/infra/install.sh` re-runs skip them)
4. Waits until the expected number of worker-only nodes are Ready
5. Best-effort check: `cat /sys/module/kvm_amd/parameters/nested` (or `kvm_intel`) is `1` / `Y`

Verify:

```bash
oc get machineset -n openshift-machine-api | grep worker
oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra,!node-role.kubernetes.io/storage' -o wide
oc get mcp worker
oc get mc 80-enable-nested-virt

# Nested virt on a worker (AMD hosts)
oc debug node/<worker> -- chroot /host cat /sys/module/kvm_amd/parameters/nested
```

---

## Step 5 — Argo CD prerequisites

Enables aggregated cluster roles on the Argo CD instance and applies a ClusterRole that grants the Application Controller rights for platform resources (`Namespace`, `Secret`, `Ingress`, …) plus CRDs this repo manages via GitOps (KubeVirt, OLM, monitoring, snapshots, Elasticsearch, Grafana, …). With `aggregatedClusterRoles: true`, write access is only what that ClusterRole lists.

```bash
./argocd/main/apply-prerequisites.sh
```

When you add new Operators / CRDs under GitOps, extend:

`argocd/main/argocd-application-controller-operator-permissions-clusterrole.yaml`

---

## Step 6 — Root app-of-apps

Bootstraps the root Application that syncs:

| Source | Path | Contents |
|--------|------|----------|
| 1 | `argocd/manifests/cluster-objects` | AppProject, hook RBAC, PostSync Job |
| 2 | `argocd/manifests/applications` | Child Applications / ApplicationSets (CNV, Elasticsearch, Grafana, …) |

```bash
# Upstream defaults
./argocd/main/bootstrap-app-of-apps.sh

# Fork / branch
REPO_URL=https://github.com/<org>/openshift-virt-loadtest.git \
  TARGET_REVISION=main \
  ./argocd/main/bootstrap-app-of-apps.sh
```

`REPO_URL` and `TARGET_REVISION` are substituted with **kustomize** (ConfigMap + replacements), not `envsubst`.

**Important:** The Application points at Git. Push this repository (or your fork) to the remote used by `REPO_URL` before expecting a green sync. Until then you can apply manifests locally for testing:

```bash
kubectl apply -k argocd/manifests/cluster-objects/
```

### Global cluster configuration (cluster-agnostic apps)

A PostSync Job creates / updates Secret `openshift-gitops-cluster-configuration` in `openshift-gitops` with labels that make it an Argo CD **cluster** secret (`argocd.argoproj.io/secret-type: cluster`). Annotations carry cluster-specific values so ApplicationSets stay portable:

| Annotation | Example | Used for |
|------------|---------|----------|
| `ingress-domain` | `apps.demo.example.com` | Ingress / Route hosts |
| `default-storage-class` | `managed-csi` | App PVCs (ES/Grafana, etc.) — cluster default |
| `odf-osd-storage-class` | `managed-csi-v2` | Informational; OSD SC created by `setup/storage` |
| `ocp-version` | `4.20.32` | Full cluster version |
| `ocp-channel` | `4.20` | Operator channel major.minor |

Verify:

```bash
kubectl get secret openshift-gitops-cluster-configuration -n openshift-gitops \
  -o jsonpath='{range $k,$v := .metadata.annotations}{$k}={$v}{"\n"}{end}'
```

Child ApplicationSets select the in-cluster secret and inject values, for example:

```yaml
value: "{{ index .metadata.annotations \"default-storage-class\" }}"
```

Do **not** hardcode the Azure apps domain in Git manifests. Use placeholders (e.g. `PLACEHOLDER`) and ApplicationSet / kustomize patches. ODF OSD disks use StorageClass **`managed-csi-v2`** (Premium SSD v2) from `setup/storage`; app PVCs keep using the cluster default (`managed-csi`).

---

## OpenShift Virtualization via GitOps

Installs the OpenShift Virtualization Operator and `HyperConverged` CR in the mandatory `openshift-cnv` namespace ([OCP 4.20 install docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/installing)).

| Path | Contents |
|------|----------|
| `argocd/manifests/openshift-virtualization/operator/` | Namespace, OperatorGroup, Subscription `hco-operatorhub` (`redhat-operators` / `stable`) |
| `argocd/manifests/openshift-virtualization/instance/` | `HyperConverged` `kubevirt-hyperconverged` |

Applications (sync waves):

| App | Wave | Path |
|-----|------|------|
| `cnv-operator` | `1` | operator Subscription |
| `cnv-hyperconverged` | `2` | HyperConverged CR (waits for CRDs; `SkipDryRunOnMissingResource`) |

Node placement (lab topology):

- **Subscription** `spec.config` → HCO operator pods on **infra** (`nodeSelector` + `reserved` toleration)
- **HyperConverged** `spec.infra.nodePlacement` → virt control-plane components on **infra**
- **HyperConverged** `spec.workloads.nodePlacement` → `virt-handler` / VM launchers on **worker-only** nodes (affinity: has `worker`, excludes `infra` and `storage`)

Requires workers from `setup/workers/install.sh` (nested virt MachineConfig) before VMs can run.

### Manual apply (until Git is synced)

```bash
kubectl apply -k argocd/manifests/openshift-virtualization/operator/
# Wait for CSV Succeeded, then:
oc get csv -n openshift-cnv

kubectl apply -k argocd/manifests/openshift-virtualization/instance/
oc wait hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  --for=condition=Available --timeout=15m
```

Verify:

```bash
oc get csv -n openshift-cnv
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv
oc get pods -n openshift-cnv -o wide
# virt-handler should be on worker-only nodes; HCO operator pods on infra
```

---

## Elasticsearch + Grafana (kube-burner metrics) via GitOps

Based on the PoC use cases in `specs/Azure-Virtualization-PoC-EJ.md`, adapted for GitOps and [kubernetes.mdc](file:///home/rgordill/.cursor/rules/kubernetes.mdc) rules (**Ingress instead of Routes**, `kubectl`, cluster-agnostic hosts).

| Path | Contents |
|------|----------|
| `argocd/manifests/elasticsearch/operator/` | Namespace, OperatorGroup, ECK Subscription (`certified-operators` / `stable`) |
| `argocd/manifests/elasticsearch/instance/` | Elasticsearch CR (3 nodes), passthrough Ingress |
| `argocd/manifests/grafana/operator/` | Grafana Operator Subscription (`community-operators` / `v5`) |
| `argocd/manifests/grafana/instance/` | Grafana CR + image-renderer, edge Ingress, Elasticsearch + Thanos datasources |

Improvements vs the PoC doc:

- **Ingress** (`ingressClassName: openshift-default`) instead of OpenShift `Route`
  - Elasticsearch: `route.openshift.io/termination: passthrough` with empty `path` + `ImplementationSpecific` (OpenShift rejects `/` on passthrough)
  - Grafana: edge termination + Redirect (no custom TLS secret — OpenShift router default wildcard cert; a missing `tls.secretName` blocked Route creation)
- Hosts and `root_url` use `PLACEHOLDER`, injected as `elasticsearch.<ingress-domain>` / `grafana.<ingress-domain>`
- PVC `storageClassName` is fixed to Azure **`managed-csi`** (not ODF/Ceph — RBD CSI only attaches on storage nodes; ES/Grafana run on infra)
- Operators and workloads pinned to **infra** nodes (`nodeSelector` + `reserved` toleration); Subscription `spec.config` for operator pods — **lab shortcut only**; see the [subscription note](#architecture-after-bootstrap) above (user apps on infra can qualify those nodes as workers)
- No plaintext admin password in Git (Grafana Operator generates `grafana-admin-credentials`)
- Image renderer image pinned to `docker.io/grafana/grafana-image-renderer:latest` (PoC used the same tag)
- **Thanos** Prometheus datasource → in-cluster `thanos-querier.openshift-monitoring.svc:9091` via SA token + `cluster-monitoring-view` (Elasticsearch remains the default datasource)

Applications (sync waves): operator apps → elasticsearch instance → grafana instance.

### Manual apply (until Git is synced)

```bash
DOMAIN=$(kubectl get secret openshift-gitops-cluster-configuration -n openshift-gitops \
  -o jsonpath='{.metadata.annotations.ingress-domain}')

kubectl apply -k argocd/manifests/elasticsearch/operator/
kubectl apply -k argocd/manifests/grafana/operator/
# Wait for CSVs Succeeded, then:

kustomize build argocd/manifests/elasticsearch/instance/ | \
  sed -e "s/host: PLACEHOLDER/host: elasticsearch.${DOMAIN}/" | kubectl apply -f -

kustomize build argocd/manifests/grafana/instance/ | \
  sed -e "s|https://PLACEHOLDER|https://grafana.${DOMAIN}|" \
      -e "s/host: PLACEHOLDER/host: grafana.${DOMAIN}/g" | kubectl apply -f -
```

Verify:

```bash
kubectl get elasticsearch elasticsearch -n elasticsearch   # HEALTH=green
kubectl get grafana grafana -n elasticsearch               # stageStatus=success
kubectl get grafanadatasource -n elasticsearch             # elasticsearch-datasource, thanos
curl -sk -u elastic:$(kubectl get secret elasticsearch-es-elastic-user -n elasticsearch \
  -o jsonpath='{.data.elastic}' | base64 -d) \
  https://elasticsearch.${DOMAIN}
# Grafana UI: https://grafana.<ingress-domain>
kubectl get secret grafana-admin-credentials -n elasticsearch \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d; echo
```


---

## End-to-end checklist

```bash
export KUBECONFIG=/path/to/kubeconfig

./setup/infra/install.sh
./setup/gitops/install.sh
./setup/storage/install.sh
# Install ODF operator + StorageCluster out-of-band (not via Argo CD)
./setup/workers/install.sh
./argocd/main/apply-prerequisites.sh
./argocd/main/bootstrap-app-of-apps.sh
```

Post-bootstrap checks:

```bash
# Nodes: masters + infra + storage + workers
oc get nodes
oc get machineset -n openshift-machine-api

# Infra workloads on infra nodes
oc get pods -n openshift-ingress -o wide
oc get pods -n openshift-image-registry -o wide
oc get pods -n openshift-monitoring -o wide | grep -v node-exporter
oc get pods -n openshift-gitops -o wide

# ODF (installed out-of-band)
oc get nodes -l cluster.ocs.openshift.io/openshift-storage
oc get storagecluster -n openshift-storage

# Workers for kube-burner
oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra,!node-role.kubernetes.io/storage' -o wide

# GitOps root app + CNV + cluster config
oc get application -n openshift-gitops
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv
kubectl get secret openshift-gitops-cluster-configuration -n openshift-gitops \
  -o jsonpath='{.metadata.annotations.ingress-domain}{"\n"}'

# Platform health
oc get co
```

---

## Forks and parameterization

| Variable | Where | Default |
|----------|--------|---------|
| `REPO_URL` | `bootstrap-app-of-apps.sh` | `https://github.com/rgordill/openshift-virt-loadtest.git` |
| `TARGET_REVISION` | `bootstrap-app-of-apps.sh` | `HEAD` |
| `INFRA_VM_SIZE` / `INFRA_REPLICAS` | `setup/infra/params.env` | `Standard_D8s_v6` / `1` |
| `ODF_VM_SIZE` / `ODF_REPLICAS` | `setup/storage/params.env` | `Standard_D16s_v6` / `1` |
| `WORKER_VM_SIZE` / `WORKER_REPLICAS` | `setup/workers/params.env` | `Standard_E32as_v6` / `1` |
| `INFRA_ZONES` / `ODF_ZONES` / `WORKER_ZONES` | env override | All zones from MachineSets |

AppProject `sourceRepos` includes the default Git remote; forks should update `argocd/manifests/cluster-objects/project.yaml` (or extend bootstrap) to allow their remote.

---

## What comes next (via GitOps only)

After the root app is Healthy/Synced:

- Confirm `cnv-operator` / `cnv-hyperconverged` are Synced and HyperConverged is Available
- Run kube-burner-ocp against the worker nodes from `setup/workers/install.sh`
- Use ApplicationSets with `ingress-domain` wherever Ingress hosts are required
- Prefer StorageClasses from ODF (`ocs-storagecluster-ceph-rbd`, …) for VM disks / load-test PVCs
- Avoid day-2 `oc apply` outside `setup/*/install.sh` and `argocd/main/` bootstrap

---

## License & Attribution

Scripts and manifests in this repository are part of the OpenShift Virt Load Test project.

Third-party products referenced here (OpenShift Container Platform, OpenShift GitOps, OpenShift Data Foundation) are trademarks of Red Hat, Inc. This project is not an official Red Hat product.
