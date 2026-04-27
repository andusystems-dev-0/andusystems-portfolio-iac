# Architecture

## Cluster topology

The portfolio cluster is a spoke in a hub-and-spoke Kubernetes multi-cluster model. It
is a kubeadm-bootstrapped cluster with one control-plane node and four worker nodes,
all running as VMs on Proxmox. The management cluster runs the primary ArgoCD instance
that drives GitOps reconciliation for this spoke.

```
  ┌──────────────────── Management cluster ──────────────────┐
  │                                                          │
  │  ArgoCD (hub)  ──── watches this git repo ──────────┐   │
  │                                                      │   │
  └──────────────────────────────────────────────────────┼───┘
                                                         │ applies manifests
  ┌──────────────── Portfolio cluster ───────────────────▼───┐
  │                                                          │
  │  control-plane                                           │
  │  ┌──────────┐                                           │
  │  │ kubeadm  │  kube-apiserver / scheduler / etcd        │
  │  └──────────┘                                           │
  │                                                          │
  │  workers (×4)                                            │
  │  ┌─────────────────────────────────────────────────┐    │
  │  │  containerd  +  kubelet  +  Flannel (CNI)       │    │
  │  └─────────────────────────────────────────────────┘    │
  │                                                          │
  │  Ingress layer                                           │
  │  ┌──────────┐   ┌────────────┐                          │
  │  │ MetalLB  │──▶│  Traefik   │◀── IngressRoutes        │
  │  └──────────┘   └────────────┘                          │
  │       ▲                │                                 │
  │  Pangolin-Newt         │ TLS (cert-manager + Let's Encrypt)
  │  (tunnel client)       │                                 │
  │                        ▼                                 │
  │  ┌──────────────────────────────────────────────┐       │
  │  │  portfolio app  │  cluster-status proxy       │       │
  │  └──────────────────────────────────────────────┘       │
  │                                                          │
  │  Observability                                           │
  │  ┌──────────────────────────────────────────────┐       │
  │  │  Alloy ──▶ Prometheus (metrics)              │       │
  │  │  Alloy ──▶ Loki (logs) ──▶ MinIO (S3)       │       │
  │  │  Alloy ──▶ Tempo (traces)                    │       │
  │  └──────────────────────────────────────────────┘       │
  │                                                          │
  │  Storage: Longhorn (distributed block, 3 replicas)      │
  └───────────────────────────────────────┬─────────────────┘
                                          │ S3 / registry pull
                        ┌─────────────────▼──────────────────┐
                        │  Storage cluster                    │
                        │  MinIO — Loki S3 backend           │
                        │  Nexus — container registry        │
                        └────────────────────────────────────┘
```

## Data flows

### Public traffic

1. DNS for `portfolio.andusystems.com` resolves to the Pangolin VPN server (public IP).
2. Pangolin forwards the connection through the Newt tunnel to Traefik's MetalLB
   LoadBalancer address inside the cluster's L2 subnet.
3. Traefik terminates TLS (Let's Encrypt certificate, DNS-01 via Cloudflare) and routes
   to the portfolio pod or the cluster-status nginx proxy depending on the path.

### Observability pipeline

- **Metrics**: Alloy scrapes kubelet, cAdvisor, kube-state-metrics, node-exporter, and
  any pod annotated with `prometheus.io/*`. It also respects ServiceMonitors and
  PodMonitors created by the kube-prometheus-stack. Scraped metrics are remote-written
  to in-cluster Prometheus, which exposes a LoadBalancer service so the hub Grafana can
  query it directly.
- **Logs**: Alloy collects all pod stdout/stderr and Kubernetes events, then pushes them
  to in-cluster Loki via the Loki push API. Loki stores chunks and index in MinIO (S3)
  on the storage cluster.
- **Traces**: Applications send OTLP traces to the Alloy receiver (gRPC and HTTP ports).
  Alloy forwards them to in-cluster Tempo.

### Image pulls

Cluster nodes resolve the internal registry hostname to the storage cluster's Traefik
LoadBalancer IP via a static `/etc/hosts` entry inserted by the `kubernetes` Ansible
role. This allows containerd to pull images with valid TLS (SNI matches the Let's Encrypt
cert served by storage Traefik) without a public DNS record for the registry hostname.

## Key design decisions

### Ansible owns bootstrap, ArgoCD owns workloads

ArgoCD cannot inject Vault secrets into a cluster before it has access to the cluster.
Ansible therefore handles a defined set of one-time prerequisites:

- VM provisioning and OS configuration
- kubeadm cluster init and worker join
- MetalLB IP pool configuration (requires cluster networking to be up first)
- Kubernetes Secrets that contain credentials from Ansible Vault (Cloudflare token,
  Newt credentials, Nexus image-pull secret, MinIO credentials)

Everything else — Deployments, Services, IngressRoutes, Certificates, Helm releases —
is owned by ArgoCD and must not be manually applied.

### No port forwarding: Pangolin-Newt tunnel

Exposing the cluster without inbound firewall holes is accomplished through the
Pangolin-Newt client. The Newt pod establishes an outbound tunnel to the Pangolin
server (which holds the public IP). Traffic flows inward through the tunnel rather than
via a public LoadBalancer or NodePort. This keeps the cluster nodes unreachable from
the internet directly.

### Grafana on the hub, Prometheus on the spoke

Each spoke runs Prometheus locally (7-day retention) to avoid cross-cluster metric
push at high volume. The hub Grafana queries spoke Prometheus instances directly over
their LoadBalancer IPs. This means spoke Prometheus services are exposed on internal
LoadBalancer addresses (within the homelab network) rather than via a public ingress.

### Longhorn for persistent storage

PersistentVolumeClaims for Prometheus, Alertmanager, and Loki use Longhorn with a
3-replica default. This tolerates a single worker node failure without data loss.
Loki additionally offloads its object storage (chunks and ruler data) to MinIO on the
storage cluster, so the Longhorn volume for Loki only needs to hold the local WAL and
index cache.

### cert-manager with Cloudflare DNS-01

All TLS certificates are issued via Let's Encrypt using DNS-01 challenges, with
Cloudflare as the DNS provider. This means no HTTP-01 solver is needed and certificates
can be issued even when the cluster is not yet reachable from the public internet (useful
during initial bootstrap). A single `letsencrypt` ClusterIssuer services all namespaces.

### cluster-status reverse proxy

The cluster-status nginx deployment aggregates health endpoints from multiple clusters
under the `/api/status/` path on `portfolio.andusystems.com`. Its nginx ConfigMap is
bootstrapped by an Ansible role in the management cluster (not by ArgoCD) because it
contains cluster-internal addresses. ArgoCD manages the Deployment and Service; Ansible
manages the ConfigMap. This pattern — Ansible bootstraps secrets/configs, ArgoCD manages
workloads — is the same pattern used for the Nexus registry credentials.

## Invariants

- The `portfolio` namespace and its Nexus image-pull secret must exist before ArgoCD
  can sync the portfolio Deployment; the `portfolio` Ansible role ensures this.
- MetalLB must be installed and the IP pool configured before any LoadBalancer-type
  Service (Traefik, Prometheus, Loki) can receive an address.
- cert-manager CRDs must be applied before the ClusterIssuer manifest; the
  `cert-manager` role waits for the CRD to register before applying the issuer.
- Worker nodes must be joined to the cluster before Longhorn replication reaches its
  target replica count; scheduling Longhorn volumes before all workers are up results
  in degraded (not unavailable) volumes that self-heal as workers join.
- Alloy `tolerations` include `node-role.kubernetes.io/control-plane` so the
  alloy-metrics and alloy-logs DaemonSets can schedule on the control-plane node,
  ensuring its metrics and logs are collected.
