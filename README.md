# DevOps Demo App

Учебный DevOps-проект вокруг простого FastAPI-приложения с PostgreSQL.

Приложение намеренно минимальное: пользователь может сохранить имя в базу и посмотреть список пользователей. Основной фокус проекта — инфраструктура, автоматизация, CI/CD, backup и disaster recovery.

## Архитектура

```text
Browser
   |
 HTTPS
   |
 Nginx
   |
 FastAPI
   |
PostgreSQL
```

Наружу доступны только:

```text
22   SSH
80   HTTP → HTTPS redirect
443  HTTPS
```

FastAPI и PostgreSQL работают только внутри Docker networks.

## Стек

- Ubuntu Server
- Python / FastAPI
- PostgreSQL
- Nginx
- Docker / Docker Compose
- Ansible
- Ansible Vault
- GitHub Actions
- GitHub Container Registry
- UFW
- OpenSSH
- Bash
- Git

## Структура проекта

```text
devops-demo-app/
├── app/
├── tests/
├── scripts/
│   ├── backup.sh
│   └── dr-test.sh
├── ansible/
│   ├── site.yml
│   ├── inventory.ini
│   ├── group_vars/
│   └── roles/
│       ├── common/
│       ├── ssh_hardening/
│       ├── docker/
│       ├── firewall/
│       └── app/
├── .github/workflows/
│   └── pipeline.yml
├── Dockerfile
├── compose.yaml
├── requirements.txt
└── README.md
```

## Ansible

Ansible используется для конфигурации Ubuntu Server и развёртывания приложения на нескольких VM.

Control node:

```text
WSL
```

Managed nodes:

```text
app-1
app-2
```

Playbook автоматически:

- устанавливает базовые пакеты;
- настраивает SSH hardening;
- настраивает UFW;
- устанавливает Docker;
- создаёт `/opt/devops-demo-app`;
- создаёт `.env`;
- создаёт self-signed TLS certificate;
- копирует конфигурацию;
- скачивает Docker image приложения;
- запускает Docker Compose stack;
- выполняет health checks.

Секреты хранятся в зашифрованном Ansible Vault.

## CI/CD

Pipeline реализован через GitHub Actions.

```text
git push
   |
   v
Tests
   |
   v
Docker build
   |
   v
GHCR
   |
   v
Self-hosted runner
   |
   v
Ansible
   |
   +--> app-1
   |
   +--> app-2
```

Pipeline состоит из трёх этапов.

### Test

GitHub-hosted runner:

- запускает PostgreSQL service container;
- устанавливает зависимости;
- запускает `pytest`;
- проверяет Docker Compose configuration.

Тесты проверяют:

- `/health`;
- сохранение пользователя;
- получение списка пользователей.

При ошибке следующие стадии не запускаются.

### Build

После успешных тестов собирается Docker image и публикуется в:

```text
ghcr.io/sboevd13/devops-demo-app
```

Используются tags:

```text
latest
<git commit SHA>
```

Для deployment используется SHA конкретного commit.

### Deploy

Локальные VM находятся в private VMware network и недоступны GitHub-hosted runner.

Поэтому deployment выполняет self-hosted GitHub Actions runner в WSL.

Runner запускает Ansible, который обновляет приложение сначала на `app-1`, затем на `app-2` и выполняет health checks.

Для выпуска новой версии достаточно:

```bash
git add .
git commit -m "Update application"
git push
```

## Backup

На каждой VM Ansible разворачивает:

```text
/opt/devops-demo-app/scripts/backup.sh
```

Скрипт создаёт PostgreSQL dump без остановки приложения:

```text
database.sql.gz
```

Также сохраняются конфигурация и SHA-256 checksums.

Запуск:

```bash
cd /opt/devops-demo-app
./scripts/backup.sh
```

## Disaster Recovery

В проекте есть автоматизированный cross-host DR test:

```bash
./scripts/dr-test.sh
```

Сценарий:

```text
app-1
  |
create unique record
  |
backup
  |
database.sql.gz
  |
restore
  |
app-2
  |
health check
  |
verify restored record
```

Перед изменением базы `app-2` создаётся safety backup.

Тест считается успешным только если:

- backup создан;
- база на `app-2` восстановлена;
- приложение снова healthy;
- уникальная запись из `app-1` найдена в восстановленной базе.

Успешный результат:

```text
DISASTER RECOVERY TEST PASSED
```

## Локальное развёртывание

Для доступа используются локальные DNS-имена через `hosts`:

```text
192.168.175.130 demo1.test
192.168.175.133 demo2.test
```

После deployment:

```text
https://demo1.test
https://demo2.test
```

Для homelab используются self-signed TLS certificates.

## Что реализовано

```text
FastAPI application             ✓
PostgreSQL                      ✓
Docker / Docker Compose         ✓
Nginx reverse proxy             ✓
HTTPS                           ✓
SSH hardening                   ✓
UFW                             ✓
Ansible                         ✓
Ansible roles                   ✓
Ansible Vault                   ✓
Infrastructure as Code          ✓
Automated backup                ✓
Restore                         ✓
Cross-host disaster recovery    ✓
Health checks                   ✓
Pytest                          ✓
GitHub Actions                  ✓
GitHub Container Registry       ✓
Automatic deployment            ✓
Deployment to two servers       ✓
```

## Цель проекта

Проект используется для практического изучения:

- Linux administration;
- Docker;
- networking;
- Infrastructure as Code;
- configuration management;
- secrets management;
- CI/CD;
- automated deployment;
- backup;
- disaster recovery;
- эксплуатации нескольких серверов.
