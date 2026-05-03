FROM apache/airflow:3.1.8

# Системные зависимости (только их можно ставить как root)
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc python3-dev libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Python-пакеты: НЕ запускаем pip вручную!
# Официальный образ сам найдёт requirements.txt и установит их как пользователь airflow
USER airflow