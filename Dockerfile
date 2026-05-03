FROM apache/airflow:3.1.8

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc python3-dev libpq-dev && \
    rm -rf /var/lib/apt/lists/*

USER airflow
RUN pip install --no-cache-dir \
    clickhouse-driver>=0.2.6 \
    apache-airflow-providers-postgres==6.6.1 \
    airflow-clickhouse-plugin==1.6.0 \
    apache-airflow-providers-telegram==4.0.0
