# DevOps Demo App

Учебный DevOps-проект по развёртыванию и эксплуатации FastAPI-приложения с PostgreSQL в Kubernetes.

Инфраструктура состоит из двух Ubuntu Server VM. Настройка серверов и установка K3s автоматизированы через Ansible. Для мониторинга используются Prometheus и Grafana, для CI/CD — GitHub Actions.

## Технологии

- **Infrastructure:** Ubuntu Server, Ansible, Kubernetes (K3s)
- **Application:** Python, FastAPI, PostgreSQL, Nginx
- **CI/CD:** GitHub Actions, Docker, GHCR
- **Monitoring:** Prometheus, Grafana, Node Exporter, cAdvisor
- **Backup:** Kubernetes CronJob, pg_dump

## Архитектура

```text
                   GitHub Actions
                         |
                        GHCR
                         |
                Kubernetes (K3s)
                  /           \
              app-1           app-2
           Control Plane      Worker
                  \           /
                   Nginx (HTTPS)
                         |
                       FastAPI
                         |
                     PostgreSQL

              Prometheus + Grafana
```

## Развёртывание

Кластер использует две Ubuntu Server VM:

| Узел | IP-адрес | Роль |
|---|---|---|
| app-1 | 192.168.175.130 | Control Plane |
| app-2 | 192.168.175.133 | Worker |

Необходимы настроенный SSH-доступ к VM, Ansible и kubectl на управляющей машине.

### 1. Установка K3s

```bash
cd ansible
ansible-playbook site.yml
cd ..
```

Подключение к кластеру:

```bash
export KUBECONFIG="$PWD/ansible/.generated/kubeconfig"
kubectl get nodes
```

### 2. Развёртывание приложения

Перед первым запуском необходимо создать Kubernetes Secrets `app-secrets` и `nginx-tls`, а также подготовить каталог бэкапов на `app-1`.

```bash
kubectl apply -k kubernetes/app/
kubectl -n devops-demo get pods,svc
```

### 3. Мониторинг

После создания Secret `grafana-admin`:

```bash
kubectl apply -k kubernetes/monitoring/
kubectl -n monitoring get pods,svc
```

## Доступ к сервисам

| Сервис | Адрес |
|---|---|
| FastAPI | https://192.168.175.130:30443 |
| Grafana | http://192.168.175.130:30300 |
| Prometheus | http://192.168.175.130:30090 |

Для HTTPS используется самоподписанный сертификат.

## CI/CD

После push в `main` GitHub Actions:

1. Запускает тесты приложения.
2. Собирает Docker image и публикует его в GHCR.
3. Обновляет FastAPI Deployment через self-hosted runner.
4. Проверяет успешность Kubernetes rollout.

Для автоматического деплоя runner должен иметь доступ к Kubernetes API.

## Основные команды

```bash
# Состояние кластера
kubectl get nodes -o wide

# Приложение
kubectl -n devops-demo get pods,svc

# Мониторинг
kubectl -n monitoring get pods,svc

# Логи FastAPI
kubectl -n devops-demo logs deployment/devops-demo-app

# Проверка обновления приложения
kubectl -n devops-demo rollout status deployment/devops-demo-app

# Проверка резервного копирования и восстановления
./scripts/k8s-dr-test.sh
```

PostgreSQL использует PersistentVolumeClaim. Резервные копии создаются Kubernetes CronJob.

**Примечание:** первоначальное развёртывание с двух чистых VM и восстановление из бэкапа требуют дополнительной проверки. Создание Secrets пока выполняется вручную.
