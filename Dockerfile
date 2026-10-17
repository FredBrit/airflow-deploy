FROM apache/airflow:3.1.8

USER root

# Устанавливаем системные зависимости, беря libpq-dev из репозитория PostgreSQL (PGDG)
RUN set -eux; \
    . /etc/os-release; \
    # Добавляем репозиторий PGDG, если его ещё нет в образе
    if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends gnupg curl ca-certificates; \
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg; \
        echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list; \
    fi; \
    apt-get update; \
    # Ключевой момент: -t ${VERSION_CODENAME}-pgdg заставляет apt брать libpq-dev из PGDG
    apt-get install -y --no-install-recommends \
        -t "${VERSION_CODENAME}-pgdg" \
        gcc python3-dev libpq-dev; \
    rm -rf /var/lib/apt/lists/*

USER airflow
