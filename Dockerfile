# syntax=docker/dockerfile:1

FROM apache/airflow:3.1.8

USER root

# --- Необязательно: замена зеркала Debian для ускорения скачивания ---
# Раскомментируйте и укажите своё зеркало, если стандартное медленное
# ARG APT_MIRROR="mirror.yandex.ru"
# RUN sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list

# Отключаем автоматическую очистку кэша пакетов, чтобы он работал между сборками
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Устанавливаем системные зависимости с кэшированием apt
# Кэш-маунты сохраняют скачанные .deb и индексы между сборками
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    . /etc/os-release; \
    if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends gnupg curl ca-certificates; \
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg; \
        echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        -t "${VERSION_CODENAME}-pgdg" \
        gcc python3-dev libpq-dev

USER airflow

# --- Необязательно: зеркало PyPI для ускорения установки Python-пакетов ---
# ENV PIP_INDEX_URL=https://mirror.yandex.ru/pypi/simple
