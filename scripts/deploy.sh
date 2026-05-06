#!/usr/bin/env bash
set -e

echo "🚀 Airflow Auto-Deploy Script"
echo "==============================="

# Парсинг аргументов
REBUILD=false
for arg in "$@"; do
    case $arg in
        --rebuild|-r)
            REBUILD=true
            ;;
    esac
done

# 1. Установка системных зависимостей
echo "📦 Проверяем и устанавливаем зависимости..."
if command -v apt-get &>/dev/null; then
    sudo apt-get update -y >/dev/null 2>&1
    sudo apt-get install -y --no-install-recommends \
        git curl ca-certificates gnupg \
        python3 python3-pip openssl \
        docker.io docker-compose-plugin >/dev/null 2>&1 || true
elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    sudo dnf install -y git curl python3 openssl docker docker-compose >/dev/null 2>&1 || \
    sudo yum install -y git curl python3 openssl docker docker-compose >/dev/null 2>&1 || true
fi

# Устанавливаем cryptography для генерации Fernet Key
pip3 install --break-system-packages cryptography >/dev/null 2>&1 || \
python3 -m pip install --break-system-packages cryptography >/dev/null 2>&1 || true

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
    
    # JWT_SECRET: обновляем ИЛИ добавляем, если строки нет
    if grep -q "^AIRFLOW__API_AUTH__JWT_SECRET=" .env; then
        sed -i "s|^AIRFLOW__API_AUTH__JWT_SECRET=.*|AIRFLOW__API_AUTH__JWT_SECRET=${JWT_SEC}|" .env
    else
        echo "AIRFLOW__API_AUTH__JWT_SECRET=${JWT_SEC}" >> .env
    fi

    # Пароли БД и Админа
    DB_PASS=$(openssl rand -base64 16 | tr -d '\n')
    ADMIN_PASS=$(openssl rand -base64 16 | tr -d '\n')
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DB_PASS}|" .env
    sed -i "s|^_AIRFLOW_WWW_USER_PASSWORD=.*|_AIRFLOW_WWW_USER_PASSWORD=${ADMIN_PASS}|" .env

    echo "✅ Секреты сохранены в .env"
else
    echo "✅ .env уже существует, проверяем критичные переменные..."
    
    # Валидация критичных переменных
    CRITICAL_VARS=(
        "AIRFLOW__CORE__FERNET_KEY"
        "AIRFLOW__API__SECRET_KEY"
        "AIRFLOW__WEBSERVER__SECRET_KEY"
        "AIRFLOW__API_AUTH__JWT_SECRET"
    )
    
    MISSING=false
    for var in "${CRITICAL_VARS[@]}"; do
        if ! grep -q "^${var}=" .env || grep -q "^${var}=auto_generated$" .env || grep -q "^${var}=CHANGE_ME" .env; then
            echo "⚠️  Переменная $var требует настройки"
            MISSING=true
        fi
    done
    
    if [ "$MISSING" = true ]; then
        echo "⚠️  Некоторые секреты не настроены. Генерируем недостающие..."
        
        # Генерируем только недостающие
        if ! grep -q "^AIRFLOW__CORE__FERNET_KEY=" .env || grep -q "^AIRFLOW__CORE__FERNET_KEY=auto_generated$" .env; then
            FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 44)
            if grep -q "^AIRFLOW__CORE__FERNET_KEY=" .env; then
                sed -i "s|^AIRFLOW__CORE__FERNET_KEY=.*|AIRFLOW__CORE__FERNET_KEY=${FERNET}|" .env
            else
                echo "AIRFLOW__CORE__FERNET_KEY=${FERNET}" >> .env
            fi
        fi
        
        if ! grep -q "^AIRFLOW__API_AUTH__JWT_SECRET=" .env || grep -q "^AIRFLOW__API_AUTH__JWT_SECRET=auto_generated$" .env; then
            JWT_SEC=$(openssl rand -base64 32 | tr -d '\n')
            if grep -q "^AIRFLOW__API_AUTH__JWT_SECRET=" .env; then
                sed -i "s|^AIRFLOW__API_AUTH__JWT_SECRET=.*|AIRFLOW__API_AUTH__JWT_SECRET=${JWT_SEC}|" .env
            else
                echo "AIRFLOW__API_AUTH__JWT_SECRET=${JWT_SEC}" >> .env
            fi
        fi
        
        # Аналогично для API_SECRET и WEB_SECRET при необходимости
        for KEY in "AIRFLOW__API__SECRET_KEY" "AIRFLOW__WEBSERVER__SECRET_KEY"; do
            if ! grep -q "^${KEY}=" .env || grep -q "^${KEY}=auto_generated$" .env; then
                VAL=$(openssl rand -base64 32 | tr -d '\n')
                if grep -q "^${KEY}=" .env; then
                    sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" .env
                else
                    echo "${KEY}=${VAL}" >> .env
                fi
            fi
        done
        
        echo "✅ Недостающие секреты сгенерированы"
    fi
fi

# 4. Настройка прав пользователя
echo "🔧 Настраиваем UID/GID для Docker..."
export AIRFLOW_UID=$(id -u)
export AIRFLOW_GID=$(id -g)

# 5. Сборка образа
echo "🏗️  Собираем образ (может занять 2-5 минут)..."
if [ "$REBUILD" = true ]; then
    echo "♻️  Принудительная пересборка (--no-cache)..."
    docker compose build --pull --no-cache
else
    if [ ! -f .build_done ]; then
        echo "🆕 Первая сборка --no-cache для чистоты..."
        docker compose build --pull --no-cache
        touch .build_done
    else
        echo "🔄 Используем кэш для ускорения (добавьте --rebuild для полной пересборки)..."
        docker compose build --pull
    fi
fi

# 6. Инициализация БД
echo "🗄️  Инициализируем БД и создаём админа..."
docker compose run --rm airflow-init

# 7. Запуск сервисов
echo "🌐 Запускаем сервисы в фоне..."
docker compose up -d

# 🔐 Синхронизируем пароль админа (ТОЛЬКО ПОСЛЕ того, как apiserver запустился)
# Ждём, пока контейнер станет healthy (макс. 60 секунд)
echo "⏳ Ждём запуска airflow-apiserver..."
for i in {1..12}; do
    if docker compose ps airflow-apiserver --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
        echo "✅ airflow-apiserver готов"
        break
    fi
    echo "⏱  Попытка $i/12... ждём 5 секунд"
    sleep 5
done

# Теперь синхронизируем пароль
# ❗ Важно: запускаем от пользователя 'airflow', т.к. airflow CLI установлен в его HOME
echo "🔐 Синхронизируем пароль админа..."
ADMIN_USER=$(grep '^_AIRFLOW_WWW_USER_USERNAME=' .env | cut -d'=' -f2)
ADMIN_PASS=$(grep '^_AIRFLOW_WWW_USER_PASSWORD=' .env | cut -d'=' -f2)

# Функция для безопасного выполнения airflow команд
run_airflow_cmd() {
    docker compose exec -u airflow -T airflow-apiserver bash -c "
        export PATH=\$PATH:/home/airflow/.local/bin
        airflow \$@
    " -- "$@"
}

# Пробуем обновить пароль; если пользователь не существует — создаём
if run_airflow_cmd users update \
  --username "${ADMIN_USER}" \
  --firstname Admin \
  --lastname User \
  --email "admin@localhost" \
  --role Admin \
  --password "${ADMIN_PASS}" 2>/dev/null; then
    echo "✅ Пароль админа обновлён"
else
    run_airflow_cmd users create \
      --username "${ADMIN_USER}" \
      --firstname Admin \
      --lastname User \
      --email "admin@localhost" \
      --role Admin \
      --password "${ADMIN_PASS}"
    echo "✅ Пользователь админа создан"
fi

# 8. Вывод учетных данных
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
echo "   ./scripts/deploy.sh --rebuild              # Пересобрать с нуля"
echo ""
echo "⚠️  Для продакшена:"
echo "   • Замените localhost в .env на домен"
echo "   • Сохраните сгенерированные пароли в менеджере"
echo "   • Настройте Nginx/Traefik + HTTPS"
