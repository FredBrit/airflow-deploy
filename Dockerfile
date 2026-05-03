FROM apache/airflow:3.1.8

# Устанавливаем системные зависимости как root
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc python3-dev libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Устанавливаем Python-пакеты как root (в системный Python)
# Не используем --user, --system или --break-system-packages
RUN pip install --no-cache-dir \
    "clickhouse-driver>=0.2.6" \
    "apache-airflow-providers-postgres==6.6.1" \
    "airflow-clickhouse-plugin==1.6.0" \
    "apache-airflow-providers-telegram==4.0.0"

# Возвращаемся к пользователю airflow
USER airflow