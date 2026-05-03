#!/usr/bin/env bash
set -e

echo "🚀 Airflow Auto-Deploy Script"
echo "==============================="

# 1. Установка системных зависимостей
echo "📦 Проверяем и устанавливаем зависимости..."
if command -v apt-get &>/dev/null; then
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        git curl ca-certificates gnupg \
        python3 python3-pip openssl \
        docker.io docker-compose-plugin || true
elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    sudo dnf install -y git curl python3 openssl docker docker-compose || \
    sudo yum install -y git curl python3 openssl docker docker-compose || true
fi

# Устанавливаем cryptography для генерации Fernet Key
pip3 install --break-system-packages cryptography 2>/dev/null || \
python3 -m pip install --break-system-packages cryptography 2>/dev/null || true

# Проверка Docker
if ! command -v docker &>/dev/null; then
    echo "❌ Docker не установлен. Установите его вручную: https://docs.docker.com/engine/install/"
    exit 1
fi
if ! docker compose version &>/dev/null; then
    echo "❌ Docker Compose V2 не установлен. Установите docker-compose-plugin."
    exit 1
fi

# 2. Подготовка директорий
BASE_DIR="/opt/airflow"
cd "$BASE_DIR" || exit 1
mkdir -p logs dags plugins config/postgres scripts

# 3. Генерация .env и секретов
if [ ! -f .env ]; then
    echo "🔑 Генерируем .env и все секреты..."
    cp .env.example .env

    # Fernet Key (обязательно для шифрования)
    FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 44)
    sed -i "s|^AIRFLOW__CORE__FERNET_KEY=.*|AIRFLOW__CORE__FERNET_KEY=${FERNET}|" .env

    # API / Webserver / JWT Secrets (min 32 chars)
    API_SEC=$(openssl rand -base64 32 | tr -d '\n')
    WEB_SEC=$(openssl rand -base64 32 | tr -d '\n')
    JWT_SEC=$(openssl rand -base64 32 | tr -d '\n')
    sed -i "s|^AIRFLOW__API__SECRET_KEY=.*|AIRFLOW__API__SECRET_KEY=${API_SEC}|" .env
    sed -i "s|^AIRFLOW__WEBSERVER__SECRET_KEY=.*|AIRFLOW__WEBSERVER__SECRET_KEY=${WEB_SEC}|" .env
    sed -i "s|^AIRFLOW__API_AUTH__JWT_SECRET=.*|AIRFLOW__API_AUTH__JWT_SECRET=${JWT_SEC}|" .env

    # Пароли БД и Админа
    DB_PASS=$(openssl rand -base64 16 | tr -d '\n')
    ADMIN_PASS=$(openssl rand -base64 16 | tr -d '\n')
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DB_PASS}|" .env
    sed -i "s|^_AIRFLOW_WWW_USER_PASSWORD=.*|_AIRFLOW_WWW_USER_PASSWORD=${ADMIN_PASS}|" .env

    echo "✅ Секреты сохранены в .env"
else
    echo "✅ .env уже существует, используем его"
fi

# 4. Настройка прав пользователя
echo "🔧 Настраиваем UID/GID для Docker..."
export AIRFLOW_UID=$(id -u)
export AIRFLOW_GID=$(id -g)

# 5. Сборка и запуск
echo "🏗️  Собираем образ (может занять 2-5 минут)..."
docker compose build --pull

echo "🗄️  Инициализируем БД и создаём админа..."
docker compose run --rm --no-deps airflow-init

echo "🌐 Запускаем сервисы в фоне..."
docker compose up -d

# 6. Вывод учетных данных
ADMIN_USER=$(grep '^_AIRFLOW_WWW_USER_USERNAME=' .env | cut -d'=' -f2)
ADMIN_PASS=$(grep '^_AIRFLOW_WWW_USER_PASSWORD=' .env | cut -d'=' -f2)

echo ""
echo "========================================="
echo "🎉 Airflow успешно развернут!"
echo "🌐 Web UI: http://localhost:8080"
echo "👤 Логин: ${ADMIN_USER}"
echo "🔑 Пароль: ${ADMIN_PASS}"
echo "========================================="
echo ""
echo "💡 Полезные команды:"
echo "   docker compose logs -f airflow-apiserver   # Логи UI"
echo "   docker compose down                         # Остановка"
echo "   docker compose up -d                        # Запуск"
echo ""
echo "⚠️  Для продакшена:"
echo "   • Замените localhost в .env на домен"
echo "   • Сохраните сгенерированные пароли в менеджере"
echo "   • Настройте Nginx/Traefik + HTTPS"
