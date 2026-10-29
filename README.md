# DevOps Demo App

Учебный DevOps-проект, включающий простое FastAPI-приложение, PostgreSQL, Nginx, Docker Compose и автоматизированное развёртывание через Ansible.

## Возможности приложения

Пользователь может:

- ввести имя;
- сохранить пользователя в PostgreSQL;
- посмотреть список сохранённых пользователей.

## Архитектура

Client
  |
  | HTTPS :443
  v
Nginx
  |
  | :8000
  v
FastAPI
  |
  | :5432
  v
PostgreSQL

PostgreSQL и FastAPI не публикуют свои порты наружу.

Используемые технологии
- Ubuntu Server
- Python
- FastAPI
- PostgreSQL
- Nginx
- Docker
- Docker Compose
- Ansible
- UFW
- OpenSSH
- Bash
- Git

Ansible автоматически:
- устанавливает базовые пакеты;
- настраивает SSH hardening;
- настраивает UFW;
- устанавливает Docker из официального Docker APT repository;
- создаёт структуру приложения в /opt/devops-demo-app;
- создаёт .env;
- создаёт локальный TLS-сертификат;
- копирует исходный код;
- собирает Docker image;
- запускает Docker Compose stack;
- выполняет health checks.

Playbook:
ansible-playbook site.yml \
  --limit app-1 \
  --ask-become-pass \
  --ask-vault-pass

Backup
На сервере:
cd /opt/devops-demo-app
./scripts/backup.sh

Backup содержит:
- дамп PostgreSQL;
- compose-конфигурацию;
- Nginx-конфигурацию;
- SHA-256 checksums.

Развёртывание
После подготовки чистой Ubuntu и добавления SSH-ключа сервер полностью конфигурируется Ansible.

Проект используется для практики Linux, Docker, сетей контейнеров, reverse proxy, PostgreSQL, security hardening, backup и Infrastructure as Code.
