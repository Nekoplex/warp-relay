#!/bin/bash
#
# WireGuard Relay Uninstall Script
# ================================
# Этот скрипт удаляет все правила iptables, созданные relay.sh
#
# Использование:
#   sudo ./uninstall.sh [OPTIONS]
#
# Опции окружения:
#   TARGET_HOST   - Целевой хост (по умолчанию: engage.cloudflareclient.com)
#   TARGET_PORT   - Целевой порт (по умолчанию: 4500)
#

set -euo pipefail

# ============================================================================
# КОНФИГУРАЦИЯ
# ============================================================================

TARGET_HOST="${TARGET_HOST:-engage.cloudflareclient.com}"
TARGET_PORT="${TARGET_PORT:-4500}"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

get_target_ip() {
    TARGET_IP=$(getent ahostsv4 "$TARGET_HOST" 2>/dev/null | awk '{print $1; exit}')
    if [[ -z "$TARGET_IP" ]]; then
        log_warn "Не удалось разрешить DNS имя: $TARGET_HOST"
        log_info "Будет произведена попытка удаления по известным правилам"
    fi
}

remove_iptables_rules() {
    log_info "Удаление iptables правил..."
    
    # Получаем внешний IP
    MYIP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "")
    
    if [[ -n "$MYIP" && -n "$TARGET_IP" ]]; then
        # Удаляем PREROUTING правила
        while iptables -t nat -C PREROUTING -d "${MYIP}" -p udp --dport "${TARGET_PORT}" \
              -j DNAT --to-destination "${TARGET_IP}:${TARGET_PORT}" &>/dev/null; do
            iptables -t nat -D PREROUTING -d "${MYIP}" -p udp --dport "${TARGET_PORT}" \
                -j DNAT --to-destination "${TARGET_IP}:${TARGET_PORT}" 2>/dev/null || break
            log_info "Удалено PREROUTING правило"
        done
        
        # Удаляем POSTROUTING правила
        while iptables -t nat -C POSTROUTING -p udp -d "${TARGET_IP}" --dport "${TARGET_PORT}" \
              -j MASQUERADE &>/dev/null; do
            iptables -t nat -D POSTROUTING -p udp -d "${TARGET_IP}" --dport "${TARGET_PORT}" \
                -j MASQUERADE 2>/dev/null || break
            log_info "Удалено POSTROUTING правило"
        done
        
        # Удаляем FORWARD правила
        while iptables -C FORWARD -p udp -d "${TARGET_IP}" --dport "${TARGET_PORT}" -j ACCEPT &>/dev/null; do
            iptables -D FORWARD -p udp -d "${TARGET_IP}" --dport "${TARGET_PORT}" -j ACCEPT 2>/dev/null || break
            log_info "Удалено FORWARD правило (входящее)"
        done
        
        while iptables -C FORWARD -p udp -s "${TARGET_IP}" --sport "${TARGET_PORT}" -j ACCEPT &>/dev/null; do
            iptables -D FORWARD -p udp -s "${TARGET_IP}" --sport "${TARGET_PORT}" -j ACCEPT 2>/dev/null || break
            log_info "Удалено FORWARD правило (исходящее)"
        done
    else
        log_warn "Не удалось определить IP адреса, показываю текущие правила:"
        echo ""
        echo "=== NAT PREROUTING ==="
        iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null || true
        echo ""
        echo "=== NAT POSTROUTING ==="
        iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null || true
        echo ""
        echo "=== FORWARD ==="
        iptables -L FORWARD -n --line-numbers 2>/dev/null || true
        echo ""
        log_info "Удалите правила вручную используя: iptables -t nat -D [chain] [number]"
    fi
    
    log_success "iptables правила удалены"
}

disable_ip_forwarding() {
    log_info "Отключение IP forwarding..."
    
    # Удаляем файл конфигурации
    if [[ -f /etc/sysctl.d/99-warp-relay.conf ]]; then
        rm -f /etc/sysctl.d/99-warp-relay.conf
        log_info "Удален файл конфигурации /etc/sysctl.d/99-warp-relay.conf"
    fi
    
    # Отключаем IP forwarding (опционально - раскомментируйте если нужно)
    # sysctl -w net.ipv4.ip_forward=0
    
    log_warn "IP forwarding оставлен включенным (может использоваться другими сервисами)"
    log_info "Для отключения выполните: sysctl -w net.ipv4.ip_forward=0"
}

remove_iptables_persistent() {
    log_info "Удаление iptables-persistent (опционально)..."
    read -p "Удалить iptables-persistent? (yes/no): " answer
    if [[ "$answer" == "yes" ]]; then
        apt-get remove -y iptables-persistent || true
        log_success "iptables-persistent удален"
    else
        log_info "iptables-persistent оставлен установленным"
    fi
}

main() {
    echo "=========================================="
    echo "   WireGuard Relay Uninstall"
    echo "=========================================="
    echo ""
    
    check_root
    get_target_ip
    remove_iptables_rules
    disable_ip_forwarding
    remove_iptables_persistent
    
    echo ""
    log_success "Удаление завершено!"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
