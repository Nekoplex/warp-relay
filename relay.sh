#!/bin/bash
#
# WireGuard Relay Server Setup Script
# ===================================
# Этот скрипт настраивает сервер для форвардинга и NAT
# пакетов в сторону WireGuard сервера (по умолчанию CloudFlare WARP).
#
# Использование:
#   sudo ./relay.sh [OPTIONS]
#
# Опции окружения:
#   TARGET_HOST   - Целевой хост для релея (по умолчанию: engage.cloudflareclient.com)
#   TARGET_PORT   - Целевой порт (по умолчанию: 4500)
#   SKIP_SAVE     - Пропустить сохранение iptables правил (yes/no)
#
# Пример:
#   sudo TARGET_HOST=my.wg.server.com TARGET_PORT=51820 ./relay.sh
#

set -euo pipefail

# ============================================================================
# КОНФИГУРАЦИЯ
# ============================================================================

# Целевой хост и порт (можно переопределить через переменные окружения)
TARGET_HOST="${TARGET_HOST:-engage.cloudflareclient.com}"
TARGET_PORT="${TARGET_PORT:-4500}"
SKIP_SAVE="${SKIP_SAVE:-no}"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# ФУНКЦИИ
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка наличия необходимых прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

# Проверка зависимостей
check_dependencies() {
    local deps=("curl" "getent" "awk" "iptables" "sysctl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Отсутствуют необходимые зависимости: ${missing[*]}"
        log_info "Установка базовых зависимостей..."
        apt-get update
        apt-get install -y curl iptables dnsutils
    fi
}

# Включение IP forwarding
enable_ip_forwarding() {
    log_info "Включение IP forwarding..."
    
    # Создаем файл конфигурации для сохранения настроек после перезагрузки
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-warp-relay.conf
    
    # Применяем настройку немедленно
    if sysctl -w net.ipv4.ip_forward=1 &>/dev/null; then
        log_success "IP forwarding включен"
    else
        log_error "Не удалось включить IP forwarding"
        exit 1
    fi
}

# Получение IP адресов
get_ip_addresses() {
    log_info "Получение IP адресов..."
    
    # Получаем внешний IP текущего сервера
    MYIP=$(curl -s -4 --connect-timeout 10 ifconfig.me 2>/dev/null || \
           curl -s -4 --connect-timeout 10 icanhazip.com 2>/dev/null || \
           curl -s -4 --connect-timeout 10 api.ipify.org 2>/dev/null)
    
    if [[ -z "$MYIP" ]]; then
        log_error "Не удалось определить внешний IP адрес сервера"
        exit 1
    fi
    
    # Получаем IP целевого хоста
    TARGET_IP=$(getent ahostsv4 "$TARGET_HOST" 2>/dev/null | awk '{print $1; exit}')
    
    if [[ -z "$TARGET_IP" ]]; then
        log_error "Не удалось разрешить DNS имя: $TARGET_HOST"
        exit 1
    fi
    
    log_info "Внешний IP сервера: $MYIP"
    log_info "IP целевого хоста ($TARGET_HOST): $TARGET_IP"
}

# Настройка iptables правил
setup_iptables() {
    log_info "Настройка iptables правил..."
    
    # Проверяем существование правил перед добавлением
    if iptables -t nat -C PREROUTING -d "${MYIP}" -p udp --dport "${TARGET_PORT}" \
       -j DNAT --to-destination "${TARGET_IP}:${TARGET_PORT}" &>/dev/null; then
        log_warn "Правила iptables уже существуют. Пропускаем..."
        return 0
    fi
    
    # DNAT: Перенаправление входящих пакетов на целевой сервер
    iptables -t nat -A PREROUTING \
        -d "${MYIP}" -p udp --dport "${TARGET_PORT}" \
        -j DNAT --to-destination "${TARGET_IP}:${TARGET_PORT}"
    
    # MASQUERADE: Маскировка исходящих пакетов
    iptables -t nat -A POSTROUTING \
        -p udp -d "${TARGET_IP}" --dport "${TARGET_PORT}" \
        -j MASQUERADE
    
    # Разрешаем форвардинг пакетов
    iptables -A FORWARD -p udp -d "${TARGET_IP}" --dport "${TARGET_PORT}" -j ACCEPT
    iptables -A FORWARD -p udp -s "${TARGET_IP}" --sport "${TARGET_PORT}" -j ACCEPT
    
    log_success "iptables правила настроены"
}

# Установка iptables-persistent для сохранения правил
install_iptables_persistent() {
    if [[ "$SKIP_SAVE" == "yes" ]]; then
        log_info "Пропуск установки iptables-persistent (SKIP_SAVE=yes)"
        return 0
    fi
    
    log_info "Установка iptables-persistent для сохранения правил..."
    
    # Предотвращаем интерактивный запрос при установке
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    
    # Создаем директорию если она не существует
    mkdir -p /etc/iptables
    
    # Сохраняем правила
    if iptables-save > /etc/iptables/rules.v4; then
        log_success "iptables правила сохранены в /etc/iptables/rules.v4"
    else
        log_warn "Не удалось сохранить iptables правила автоматически"
        log_info "Вы можете сохранить их вручную командой: iptables-save > /etc/iptables/rules.v4"
    fi
}

# Показать сводку
show_summary() {
    echo ""
    echo "=========================================="
    echo "     WireGuard Relay Настроен!"
    echo "=========================================="
    echo ""
    echo "Параметры релея:"
    echo "  Внешний IP сервера: ${MYIP}"
    echo "  Целевой хост:       ${TARGET_HOST}"
    echo "  Целевой IP:         ${TARGET_IP}"
    echo "  Порт:               ${TARGET_PORT}"
    echo ""
    echo "Для подключения к WARP используйте:"
    echo "  Сервер: ${MYIP}"
    echo "  Порт:   ${TARGET_PORT}"
    echo ""
    echo "Проверка статуса правил:"
    echo "  iptables -t nat -L PREROUTING -n --line-numbers"
    echo ""
}

# Функция очистки (вызывается при ошибке)
cleanup() {
    log_warn "Выполняется очистка..."
    # Здесь можно добавить удаление созданных правил при необходимости
}

# ============================================================================
# ОСНОВНОЙ СКРИПТ
# ============================================================================

main() {
    echo "=========================================="
    echo "   WireGuard Relay Server Setup"
    echo "=========================================="
    echo ""
    
    # Устанавливаем trap для очистки при прерывании
    trap cleanup EXIT
    
    # Проверки
    check_root
    check_dependencies
    
    # Настройка
    enable_ip_forwarding
    get_ip_addresses
    setup_iptables
    install_iptables_persistent
    
    # Сводка
    show_summary
    
    log_success "Настройка завершена успешно!"
}

# Запуск main если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
