# Kubernetes deployment (two-node k3s homelab)

This is the Kubernetes successor to the legacy Docker Compose deployment in the root README.
The existing `ansible/site.yml` still manages Compose. **Do not run it after switching to
Kubernetes**: it starts the old stacks and enables the old firewall rules.

## Layout

- `app-1` (192.168.175.130): k3s server, monitoring, daily database dumps.
- `app-2` (192.168.175.133): k3s agent, PostgreSQL's local-path PVC.
- FastAPI and Nginx: two replicas, spread across the nodes when possible.
- PostgreSQL: one instance with local storage, **not** replicated or automatic failover.
- WSL: `kubectl` client and self-hosted GitHub Actions runner.

Both nodes must run with working Pod routes and cluster DNS. On this homelab,
`app-2` must boot `7.0.0-38-generic` until the PostgreSQL issue seen with
`7.0.0-42-generic` is understood. Keep UFW disabled on both k3s nodes; restrict
access using the VMware private network and host firewall if required.

## 1. Prepare (from WSL unless a command says otherwise)

```bash
kubectl get nodes -o wide
ssh dmitriy@192.168.175.133 uname -r
kubectl -n devops-demo get pod postgres-0
```

For a **new** cluster only, `ansible/k3s-bootstrap.yml` installs the pinned k3s
version and configures `ens33` and the node IPs. It does not migrate or preserve
an existing Kubernetes database. Snapshot both VMs before resetting a cluster.
The passwords for `sudo` on the two machines can differ:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
read -rsp 'app-1 sudo password: ' APP1_BECOME_PASSWORD; echo
read -rsp 'app-2 sudo password: ' APP2_BECOME_PASSWORD; echo
export APP1_BECOME_PASSWORD APP2_BECOME_PASSWORD
ansible-playbook k3s-bootstrap.yml
unset APP1_BECOME_PASSWORD APP2_BECOME_PASSWORD
cd ..
```

For the existing working cluster, **skip the bootstrap**. Before deploying the
backup CronJob, make its directory writable only by `dmitriy` on `app-1`:

```bash
ssh -t dmitriy@192.168.175.130 \
  'sudo install -d -o dmitriy -g dmitriy -m 0700 /opt/devops-demo-app/k8s-backups'
```

## 2. Create secrets

On the existing cluster, preserve the working `app-secrets`. Check its presence
without printing its contents:

```bash
kubectl apply -f kubernetes/app/namespace.yaml
kubectl -n devops-demo get secret app-secrets
```

On a new cluster, create it from an interactive password. URL encoding matters
for PostgreSQL passwords containing `@`, `/`, `:` or `%`:

```bash
read -rsp 'PostgreSQL password: ' DB_PASS; echo
export DB_PASS
DB_URL=$(python3 -c 'import os, urllib.parse; print("postgresql+psycopg://app:" + urllib.parse.quote(os.environ["DB_PASS"], safe="") + "@postgres:5432/appdb")')
kubectl -n devops-demo create secret generic app-secrets \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS" \
  --from-literal=DATABASE_URL="$DB_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DB_PASS DB_URL
```

Create a self-signed certificate covering both names and both VM IPs:

```bash
TLS_DIR=$(mktemp -d)
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" \
  -subj '/CN=demo1.test' \
  -addext 'subjectAltName=DNS:demo1.test,DNS:demo2.test,IP:192.168.175.130,IP:192.168.175.133'
kubectl -n devops-demo create secret tls nginx-tls \
  --cert="$TLS_DIR/tls.crt" --key="$TLS_DIR/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$TLS_DIR"
```

For Grafana, create the monitoring namespace and password:

```bash
kubectl apply -f kubernetes/monitoring/namespace.yaml
read -rsp 'Grafana admin password: ' GRAFANA_PASSWORD; echo
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=password="$GRAFANA_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
unset GRAFANA_PASSWORD
```

Keep secrets out of Git. The existing cluster's `app-secrets` already includes
the `DATABASE_URL` and `POSTGRES_PASSWORD` required by these manifests.

## 3. Apply app and validate it

```bash
kubectl apply -k kubernetes/app
kubectl -n devops-demo rollout status statefulset/postgres --timeout=300s
kubectl -n devops-demo rollout status deployment/devops-demo-app --timeout=180s
kubectl -n devops-demo rollout status deployment/nginx --timeout=180s
curl -kfsS https://192.168.175.130:30443/health
curl -kfsS https://192.168.175.133:30443/health
```

Nginx uses NodePort `30080` (HTTP redirect) and `30443` (HTTPS), so the
homelab URLs are `https://demo1.test:30443` and `https://demo2.test:30443`.
Self-signed certificates require a browser exception (or `curl -k`). Old
Compose can continue on host ports 80/443 until you are ready to shut it down.

## 4. Move monitoring

The old Compose agents occupy host ports 9100 and 8080. Stop their containers
on both nodes, and stop the old Prometheus/Grafana on app-1. **Do not add `-v`**
to these commands: the old monitoring volumes stay available for rollback.

```bash
ssh dmitriy@192.168.175.130 'cd /opt/monitoring-agent && docker compose -p monitoring-agent down'
ssh dmitriy@192.168.175.133 'cd /opt/monitoring-agent && docker compose -p monitoring-agent down'
ssh dmitriy@192.168.175.130 'cd /opt/monitoring && docker compose -p monitoring down'
kubectl apply -k kubernetes/monitoring
kubectl -n monitoring rollout status daemonset/node-exporter --timeout=180s
kubectl -n monitoring rollout status daemonset/cadvisor --timeout=180s
kubectl -n monitoring rollout status deployment/prometheus --timeout=180s
kubectl -n monitoring rollout status deployment/grafana --timeout=180s
```

Prometheus: `http://192.168.175.130:30090/targets`.
Grafana: `http://192.168.175.130:30300` (user `admin`). Check that all
node/cAdvisor/FastAPI scrape targets are UP and the dashboard has data.
Grafana and Prometheus have new local-path PVCs on app-1; old Compose metric
history is not copied.

## 5. Backups and recovery test

The CronJob runs at 03:00 Asia/Yekaterinburg, writes compressed SQL and SHA-256
to `app-1:/opt/devops-demo-app/k8s-backups` and keeps 14 days. This is on a
different VM from the PostgreSQL PVC, but is still within the same laptop.
The CronJob reads the database over the Kubernetes network.

Test the actual backup and a restore into a disposable database:

```bash
chmod +x scripts/k8s-dr-test.sh
./scripts/k8s-dr-test.sh
```

The script adds a unique record to the live database, invokes the CronJob,
verifies its checksum on app-1, imports the dump into a temporary database on
app-2, checks the record, then removes the record and temporary database. It
does **not** overwrite the live database. For a disk or laptop failure,
copy backups to additional storage outside the two VMs.

## 6. CI/CD cutover

`.github/workflows/pipeline.yml` now tests, builds an immutable SHA-tagged
image, and applies the Kubernetes manifests with that exact tag from the WSL
self-hosted runner. Before merging the migration branch, check that the runner's
user can run `kubectl get nodes` and that the secrets and monitoring ports above
are prepared. A push to `main` will deploy automatically.

The legacy Compose playbook `ansible/site.yml` is retained for rollback and
must not be used for Kubernetes releases.
