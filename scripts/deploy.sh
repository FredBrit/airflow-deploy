#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Airflow Auto-Deploy Script"
echo "==============================="

# 0. Определяем корень проекта по расположению самого скрипта
#    Это избавляет от хардкода /opt/airflow-deploy и работает из любого места
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BASE_DIR" ]; then
    echo "❌ Каталог проекта не найден: $BASE_DIR"
    exit 1
fi
cd "$BASE_DIR"
echo "📂 Рабочий каталог: $BASE_DIR"

# 1. Установка системных зависимостей
echo "📦 Проверяем зависимости..."
if command -v apt-get &>/dev/null; then
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y --no-install-recommends \
        git curl ca-certificates gnupg \
        python3 python3-pip openssl \
        docker.io docker-compose-plugin >/dev/null 2>&1 || true
fi

# cryptography нужна для генерации Fernet Key
pip3 install --break-system-packages cryptography >/dev/null 2>&1 || \
python3 -m pip install --break-system-packages cryptography >/dev/null 2>&1 || true

if ! command -v docker &>/dev/null; then
    echo "❌ Docker не установлен. https://docs.docker.com/engine/install/"
    exit 1
fi
if ! docker compose version &>/dev/null; then
    echo "❌ Docker Compose V2 не установлен."
    exit 1
fi

# 2. Подготовка директорий
mkdir -p logs dags plugins config/postgres scripts

# 3. Генерация .env и критичных секретов
if [ ! -f .env ]; then
    echo "🔑 Создаём .env..."
    cp .env.example .env

    # Fernet Key
    FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 44)
    sed -i "s|^AIRFLOW__CORE__FERNET_KEY=.*|AIRFLOW__CORE__FERNET_KEY=${FERNET}|" .env

    # API / Webserver / JWT Secrets
    for KEY in AIRFLOW__API__SECRET_KEY AIRFLOW__WEBSERVER__SECRET_KEY AIRFLOW__API_AUTH__JWT_SECRET; do
        VAL=$(openssl rand -base64 32 | tr -d '\n')
        if grep -q "^${KEY}=" .env; then
            sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" .env
        else
            echo "${KEY}=${VAL}" >> .env
        fi
    done

    # Пароль БД (только alphanumeric)
    DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DB_PASS}|" .env

    # Логин/пароль админа фиксируем как admin/admin
    sed -i "s|^_AIRFLOW_WWW_USER_USERNAME=.*|_AIRFLOW_WWW_USER_USERNAME=admin|" .env
    sed -i "s|^_AIRFLOW_WWW_USER_PASSWORD=.*|_AIRFLOW_WWW_USER_PASSWORD=admin|" .env

    echo "✅ Секреты сохранены в .env"
else
    echo "ℹ️  .env уже существует — оставляем как есть"
fi

# 4. Настройка прав
export AIRFLOW_UID=$(id -u)
export AIRFLOW_GID=$(id -g)

# 5. Сборка образа
#    ВАЖНО: без --no-cache — используем кэш слоёв и кэш-маунты apt из Dockerfile
echo "🏗️  Собираем образ (кэш включён)..."
docker compose build --pull

# 6. Инициализация БД
echo "🗄️  Инициализируем БД..."
docker compose run --rm airflow-init

# 7. Запуск сервисов
echo "🌐 Запускаем сервисы..."
docker compose up -d

# 8. Настройка доступа admin/admin
echo "⏳ Ждём готовности API-сервера..."
for i in {1..24}; do
    if docker compose ps airflow-apiserver --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
        echo "✅ API-сервер готов"
        break
    fi
    if [ "$i" -eq 24 ]; then
        echo "⚠️  API-сервер не перешёл в healthy за 120 секунд — продолжаем, но проверьте логи:"
        echo "    docker compose logs airflow-apiserver"
    fi
    sleep 5
done

echo "🔐 Устанавливаем логин/пароль: admin / admin..."
docker compose exec -u airflow -T airflow-apiserver bash -c "
    export PATH=\$PATH:/home/airflow/.local/bin
    airflow users update \
      --username admin \
      --firstname Admin \
      --lastname User \
      --email admin@localhost \
      --role Admin \
      --password admin 2>/dev/null || \
    airflow users create \
      --username admin \
      --firstname Admin \
      --lastname User \
      --email admin@localhost \
      --role Admin \
      --password admin
"
echo "✅ Готово."

# 9. Вывод
echo ""
echo "========================================="
echo "🎉 Airflow успешно развернут!"
echo "🌐 Web UI: http://localhost:8080"
echo "👤 Логин: admin"
echo "🔑 Пароль: admin"
echo "========================================="
echo ""
echo "💡 Полезные команды:"
echo "   docker compose logs -f airflow-apiserver"
echo "   docker compose down"
echo ""
echo "⚠️  Для продакшена:"
echo "   • Замените admin/admin на сложные учетные данные"
echo "   • Настройте HTTPS и firewall"
