# Развёртывание в Kubernetes (домашний кластер k3s из двух VM)

Это инструкция для перехода со старого Docker Compose на Kubernetes. Старый
`ansible/site.yml` по-прежнему разворачивает Compose. **После перехода не
запускай его**: он снова поднимет старые контейнеры и включит прежние правила UFW.

## Схема

- `app-1` (`192.168.175.130`): управляющий узел k3s, мониторинг и дампы БД.
- `app-2` (`192.168.175.133`): рабочий узел k3s и том PostgreSQL.
- FastAPI и Nginx: по две реплики, по возможности на разных узлах.
- PostgreSQL: один экземпляр с локальным томом. Репликации и автоматического
  переключения БД на другой узел здесь нет.
- WSL: клиент `kubectl` и self-hosted runner GitHub Actions.

На обеих VM должны работать маршруты между Pod и кластерный DNS. Пока не
разобрана проблема PostgreSQL с ядром `7.0.0-42-generic`, `app-2` должна
загружаться с работавшим ядром `7.0.0-38-generic`. Для текущей конфигурации
k3s UFW выключен на обеих VM; доступ ограничен частной сетью VMware.

## 1. Подготовка

Команды выполняются **в WSL**, если не указано другое место.

```bash
kubectl get nodes -o wide
ssh dmitriy@192.168.175.133 uname -r
kubectl -n devops-demo get pod postgres-0
```

**Если кластер уже работает, пропусти установку k3s ниже.** Отдельный
`ansible/k3s-bootstrap.yml` нужен только для создания нового кластера. Он
устанавливает закреплённую версию k3s, назначает IP узлов и интерфейс `ens33`.
Он не переносит данные из старого кластера: перед переустановкой сделай
снимки обеих VM и отдельно сохрани БД.

Пароли `sudo` на двух VM могут различаться:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
read -rsp 'Пароль sudo на app-1: ' APP1_BECOME_PASSWORD; echo
read -rsp 'Пароль sudo на app-2: ' APP2_BECOME_PASSWORD; echo
export APP1_BECOME_PASSWORD APP2_BECOME_PASSWORD
ansible-playbook k3s-bootstrap.yml
unset APP1_BECOME_PASSWORD APP2_BECOME_PASSWORD
cd ..
```

Каталог для дампов на `app-1` должен принадлежать пользователю `dmitriy`
(UID 1000) и быть закрыт от других пользователей:

```bash
ssh -t dmitriy@192.168.175.130 \
  'sudo install -d -o dmitriy -g dmitriy -m 0700 /opt/devops-demo-app/k8s-backups'
```

## 2. Секреты

**В существующем кластере сохрани работающий `app-secrets`.** Убедись, что он
есть, не выводя пароль на экран:

```bash
kubectl apply -f kubernetes/app/namespace.yaml
kubectl -n devops-demo get secret app-secrets
```

**Только в новом кластере** создай `app-secrets`. Пароль кодируется для URL:
символы `@`, `/`, `:` и `%` иначе могут испортить `DATABASE_URL`.

```bash
read -rsp 'Пароль PostgreSQL: ' DB_PASS; echo
export DB_PASS
DB_URL=$(python3 -c 'import os, urllib.parse; print("postgresql+psycopg://app:" + urllib.parse.quote(os.environ["DB_PASS"], safe="") + "@postgres:5432/appdb")')
kubectl -n devops-demo create secret generic app-secrets \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS" \
  --from-literal=DATABASE_URL="$DB_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DB_PASS DB_URL
```

Создай самоподписанный сертификат для обоих имён и IP. Браузер предупредит,
что сертификат не выдан доверенным центром; для домашнего стенда это ожидаемо.

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

Создай namespace мониторинга и пароль Grafana:

```bash
kubectl apply -f kubernetes/monitoring/namespace.yaml
read -rsp 'Пароль admin для Grafana: ' GRAFANA_PASSWORD; echo
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=password="$GRAFANA_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
unset GRAFANA_PASSWORD
```

Секреты не добавляются в Git. В существующем кластере `app-secrets` уже
содержит нужные `DATABASE_URL` и `POSTGRES_PASSWORD`.

## 3. Приложение

```bash
kubectl apply -k kubernetes/app
kubectl -n devops-demo rollout status statefulset/postgres --timeout=300s
kubectl -n devops-demo rollout status deployment/devops-demo-app --timeout=180s
kubectl -n devops-demo rollout status deployment/nginx --timeout=180s
curl -kfsS https://192.168.175.130:30443/health
curl -kfsS https://192.168.175.133:30443/health
```

Nginx доступен через NodePort `30080` (HTTP с перенаправлением) и `30443`
(HTTPS). Адреса: `https://demo1.test:30443` и `https://demo2.test:30443`.
Для `curl` с самоподписанным сертификатом нужен флаг `-k`. Старый Compose
может пока оставаться на портах хоста 80/443; это другие порты.

## 4. Перенос мониторинга

Старые агенты Compose занимают на хостах порты 9100 и 8080. Останови их
на обеих VM, а старые Prometheus и Grafana — на `app-1`. **Не добавляй `-v`**:
без этого флага старые тома сохранятся на случай отката.

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
Grafana: `http://192.168.175.130:30300`, пользователь `admin`.
Проверь, что цели `node`, `cadvisor` и `fastapi` имеют статус `UP`, а на
панели есть данные. Prometheus и Grafana получат новые локальные PVC на
`app-1`; исторические метрики из Compose автоматически не переносятся.

## 5. Бэкап и проверка восстановления

CronJob в 03:00 по времени Екатеринбурга сохраняет сжатый SQL-дамп и SHA-256
на `app-1` в `/opt/devops-demo-app/k8s-backups`. Старые файлы удаляются через
14 дней. База находится на `app-2`, то есть дамп лежит на другой VM, но всё
ещё на том же ноутбуке.

Проверь создание бэкапа и восстановление в **отдельную временную БД**:

```bash
./scripts/k8s-dr-test.sh
```

Скрипт добавляет уникальную запись в рабочую БД, запускает Job из CronJob,
проверяет контрольную сумму на `app-1`, загружает дамп во временную БД на
`app-2` и проверяет запись. Затем он удаляет временную БД и тестовую запись.
Рабочую БД он не заменяет. Для защиты от потери всего ноутбука копируй дампы
ещё и за пределы обеих VM.

## 6. Переключение CI/CD

`.github/workflows/pipeline.yml` после тестов собирает образ с тегом SHA
коммита и через runner в WSL применяет манифесты с этим конкретным тегом.
Перед слиянием ветки проверь, что пользователь, запускающий runner, может
выполнить `kubectl get nodes`, что секреты созданы, а старые контейнеры
мониторинга остановлены. После слияния каждый push в `main` запустит deploy.

Старый `ansible/site.yml` оставлен для отката к Compose; для выпусков в
Kubernetes он не используется.
