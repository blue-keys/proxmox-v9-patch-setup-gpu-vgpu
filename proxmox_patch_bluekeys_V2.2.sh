#!/bin/bash
# Ce fichier fait partie de Proxmox V9 Patch Bluekeys Setup GPU vGPU.
#
# Proxmox V9 Patch Bluekeys Setup GPU vGPU est un logiciel libre : vous pouvez le redistribuer et/ou le modifier
# selon les termes de la GNU Affero General Public License version 3,
# telle que publiée par la Free Software Foundation.
#
# Ce programme est distribué dans l'espoir qu'il sera utile,
# mais SANS AUCUNE GARANTIE ; sans même la garantie implicite de
# COMMERCIALISABILITÉ ou D'ADÉQUATION À UN USAGE PARTICULIER.
# Voir la GNU Affero General Public License pour plus de détails.
#
# Vous devriez avoir reçu une copie de la GNU Affero General Public License
# avec ce programme. Sinon, voir <https://www.gnu.org/licenses/>.

# Proxmox V9 Support GPU and vGPU
# Name : proxmox_patch_bluekeys_V2.2.sh
# Version: 2.2
# Date: 2025-11-18
# Auteur: bluekeys.org

# Configuration stricte du shell
set -o pipefail
shopt -s nullglob

# ======================
# CONFIGURATION GLOBALE
# ======================

declare -A COLORS=(
    [RED]='\033[0;31m' [GREEN]='\033[0;32m' [YELLOW]='\033[0;33m'
    [BLUE]='\033[0;34m' [PURPLE]='\033[0;35m' [GRAY]='\033[0;37m'
    [NC]='\033[0m' [BOLD]='\033[1m' [CYAN]='\033[0;36m'
)

readonly SCRIPT_VERSION="2.2"
readonly SCRIPT_NAME="Proxmox V9 Support GPU"
readonly LOG_FILE="/var/log/proxmox_gpu_setup.log"
readonly SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
readonly STATE_FILE="$SCRIPT_DIR/proxmox_gpu_state.json"
readonly BACKUP_DIR="$SCRIPT_DIR/backups"
readonly CONFIG_BACKUP="$BACKUP_DIR/config_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
readonly UPDATE_URL="https://raw.githubusercontent.com/blue-keys/proxmox-v9-patch-setup-gpu-vgpu/refs/heads/main/version.txt"
readonly SCRIPT_URL="https://raw.githubusercontent.com/blue-keys/proxmox-v9-patch-setup-gpu-vgpu/refs/heads/main/proxmox_patch_bluekeys_V2.2.sh"
readonly LOCK_FILE="/var/run/proxmox_gpu_setup.lock"
readonly MIN_DISK_SPACE_KB=1048576  # 1GB
readonly REQUIRED_PVE_VERSION="9.0"
readonly TIMEOUT_SECONDS=300  # Timeout pour les opérations longues

LOG_LEVEL=1  # 0: DEBUG, 1: INFO, 2: WARNING, 3: ERROR
REBOOT_NEEDED=false
REBOOT_IN_PROGRESS=false
SKIP_CONFIRMATIONS=false
DRY_RUN=false

# Variables de suivi
declare -a USER_CHOICES=()
declare -a EXECUTED_STEPS=()
declare -a FAILED_STEPS=()
declare -a WARNINGS=()

# Flags de vérification
VERSION_CHECKED=false
STATES_MANAGED=false
SYSTEM_PREREQUISITES_CHECKED=false
BACKUP_CREATED=false

# Étapes du processus
declare -a STEPS=(
    "Affichage du message de bienvenue"
    "Vérification des informations système"
    "Vérification de la version du script"
    "Gestion des états précédents"
    "Vérification des prérequis système"
    "Vérification des dépendances"
    "Configuration des dépôts"
    "Installation des paquets"
    "Désinstallation du pilote NVIDIA non-vGPU"
    "Vérification et configuration IOMMU"
    "Vérification du GPU"
    "Configuration vGPU"
    "Mise à jour de initramfs"
    "Gestion du redémarrage"
)

# ======================
# FONCTIONS UTILITAIRES
# ======================

log_message() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local -a level_str=("DEBUG" "INFO" "WARNING" "ERROR")

    # Écriture sécurisée dans le log
    if [[ -w "$LOG_FILE" ]] || [[ -w "$(dirname "$LOG_FILE")" ]]; then
        echo "[$timestamp] [${level_str[$level]:-UNKNOWN}] $message" >> "$LOG_FILE" 2>/dev/null || true
    fi

    if [[ $level -ge $LOG_LEVEL ]]; then
        case $level in
            0) echo -e "${COLORS[BLUE]}[DEBUG] $message${COLORS[NC]}" ;;
            1) echo -e "${COLORS[GREEN]}[INFO] $message${COLORS[NC]}" ;;
            2) echo -e "${COLORS[YELLOW]}[WARNING] $message${COLORS[NC]}" ;;
            3) echo -e "${COLORS[RED]}[ERROR] $message${COLORS[NC]}" ;;
        esac
    fi
    rotate_logs
}

rotate_logs() {
    [[ -f "$LOG_FILE" ]] || return 0
    local log_size
    log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    
    if [[ $log_size -gt 10485760 ]]; then  # 10MB
        if [[ -w "$(dirname "$LOG_FILE")" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
            echo "=== Logs archivés le $(date) ===" > "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r${COLORS[CYAN]}["
    printf "%${filled}s" | tr ' ' '█'
    printf "${COLORS[GRAY]}"
    printf "%${empty}s" | tr ' ' '░'
    printf "${COLORS[CYAN]}] ${COLORS[BOLD]}%3d%%${COLORS[NC]}" "$percentage"
}

confirm_action() {
    local prompt=$1
    local default=${2:-n}
    local choice
    
    # Mode skip confirmations
    if [[ "$SKIP_CONFIRMATIONS" == "true" ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    
    while true; do
        read -r -p "$prompt (y/n/s=skip all) [${default}]: " choice
        choice=${choice:-$default}
        case ${choice,,} in
            y|yes|o|oui) return 0 ;;
            n|no|non) return 1 ;;
            s|skip) 
                SKIP_CONFIRMATIONS=true
                echo -e "${COLORS[YELLOW]}⚠ Mode auto activé - toutes les confirmations seront ignorées${COLORS[NC]}"
                [[ "$default" == "y" ]] && return 0 || return 1
                ;;
            *) echo -e "${COLORS[RED]}Réponse invalide. Utilisez y/n/s${COLORS[NC]}" ;;
        esac
    done
}

show_menu_navigation() {
    echo -e "\n${COLORS[GRAY]}────────────────────────────────────────${COLORS[NC]}"
    echo -e "${COLORS[CYAN]}Navigation: ${COLORS[NC]}"
    echo -e "${COLORS[GRAY]}  [n] Suivant  [p] Précédent  [m] Menu  [q] Quitter${COLORS[NC]}"
    echo -e "${COLORS[GRAY]}────────────────────────────────────────${COLORS[NC]}"
}

navigate_menu() {
    local current_step=$1
    local action
    
    show_menu_navigation
    read -r -n 1 -p "Action: " action
    echo ""
    
    case ${action,,} in
        n) return 1 ;;  # Next
        p) return 2 ;;  # Previous
        m) return 3 ;;  # Menu
        q) return 4 ;;  # Quit
        *) return 0 ;;  # Stay
    esac
}

error_handler() {
    local error_code=$1
    local error_msg=$2
    local critical=${3:-false}
    
    log_message 3 "Code: $error_code - $error_msg"
    echo -e "${COLORS[RED]}✗ ERREUR ($error_code): $error_msg${COLORS[NC]}"
    
    # Enregistrer l'avertissement
    WARNINGS+=("[$error_code] $error_msg")
    
    if [[ "$critical" == "true" ]]; then
        echo -e "${COLORS[RED]}${COLORS[BOLD]}Erreur critique détectée.${COLORS[NC]}"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${COLORS[YELLOW]}Mode dry-run: erreur simulée${COLORS[NC]}"
            return 0
        fi
        
        if confirm_action "Voulez-vous retourner au menu principal?"; then
            return 0
        else
            cleanup
            exit "$error_code"
        fi
    else
        if ! confirm_action "Voulez-vous continuer malgré cette erreur?" "y"; then
            if confirm_action "Retourner au menu principal?"; then
                return 0
            else
                cleanup
                exit "$error_code"
            fi
        fi
    fi
}

cleanup() {
    log_message 1 "Nettoyage en cours..."
    rm -f "/tmp/proxmox_rebooted" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    save_state 2>/dev/null || true
}

acquire_lock() {
    local timeout=10
    local count=0
    
    while [[ -f "$LOCK_FILE" ]] && [[ $count -lt $timeout ]]; do
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        # Vérifier si le processus existe encore
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            echo -e "${COLORS[YELLOW]}⚠ Lock orphelin détecté, nettoyage...${COLORS[NC]}"
            rm -f "$LOCK_FILE"
            break
        fi
        
        echo -e "${COLORS[YELLOW]}⏳ Une autre instance est en cours d'exécution...${COLORS[NC]}"
        sleep 1
        ((count++))
    done
    
    if [[ -f "$LOCK_FILE" ]]; then
        echo -e "${COLORS[RED]}✗ Impossible d'acquérir le verrou${COLORS[NC]}"
        return 1
    fi
    
    echo $$ > "$LOCK_FILE"
    return 0
}

create_backup() {
    if [[ "$BACKUP_CREATED" == "true" ]]; then
        return 0
    fi
    
    log_message 1 "Création d'une sauvegarde de configuration"
    
    mkdir -p "$BACKUP_DIR" 2>/dev/null || {
        log_message 2 "Impossible de créer le répertoire de backup"
        return 1
    }
    
    echo -e "${COLORS[BLUE]}📦 Création d'une sauvegarde...${COLORS[NC]}"
    
    local -a backup_files=(
        "/etc/default/grub"
        "/etc/apt/sources.list"
        "/etc/apt/sources.list.d/"
        "/etc/modules"
        "/etc/modprobe.d/"
    )
    
    local temp_backup_dir="/tmp/proxmox_backup_$$"
    mkdir -p "$temp_backup_dir"
    
    for item in "${backup_files[@]}"; do
        if [[ -e "$item" ]]; then
            local dest_dir="$temp_backup_dir/$(dirname "$item")"
            mkdir -p "$dest_dir"
            cp -r "$item" "$dest_dir/" 2>/dev/null || true
        fi
    done
    
    # Ajouter les infos système
    {
        echo "=== Backup créé le $(date) ==="
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo "Proxmox Version: $(pveversion 2>/dev/null || echo 'N/A')"
        lspci | grep -i nvidia
    } > "$temp_backup_dir/system_info.txt"
    
    if tar -czf "$CONFIG_BACKUP" -C "$temp_backup_dir" . 2>/dev/null; then
        echo -e "${COLORS[GREEN]}✓ Sauvegarde créée: $CONFIG_BACKUP${COLORS[NC]}"
        BACKUP_CREATED=true
        log_message 1 "Backup créé avec succès"
    else
        echo -e "${COLORS[YELLOW]}⚠ Échec de la création du backup${COLORS[NC]}"
        log_message 2 "Échec de la création du backup"
    fi
    
    rm -rf "$temp_backup_dir"
    return 0
}

restore_backup() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   RESTAURATION DE SAUVEGARDE         ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${COLORS[RED]}✗ Aucun répertoire de backup trouvé${COLORS[NC]}"
        return 1
    fi
    
    local -a backups
    mapfile -t backups < <(find "$BACKUP_DIR" -name "config_backup_*.tar.gz" -type f 2>/dev/null | sort -r)
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo -e "${COLORS[YELLOW]}⚠ Aucune sauvegarde disponible${COLORS[NC]}"
        return 1
    fi
    
    echo -e "${COLORS[YELLOW]}Sauvegardes disponibles:${COLORS[NC]}"
    local i=1
    for backup in "${backups[@]}"; do
        local backup_date
        backup_date=$(basename "$backup" | grep -oP '\d{8}_\d{6}')
        local readable_date
        readable_date=$(date -d "${backup_date:0:8} ${backup_date:9:2}:${backup_date:11:2}:${backup_date:13:2}" "+%d/%m/%Y %H:%M:%S" 2>/dev/null || echo "$backup_date")
        echo -e "${COLORS[GREEN]}$i.${COLORS[NC]} $readable_date"
        ((i++))
    done
    
    local choice
    read -r -p "Choisir une sauvegarde (1-${#backups[@]}): " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#backups[@]} ]]; then
        echo -e "${COLORS[RED]}✗ Choix invalide${COLORS[NC]}"
        return 1
    fi
    
    local selected_backup="${backups[$((choice-1))]}"
    
    echo -e "\n${COLORS[YELLOW]}${COLORS[BOLD]}ATTENTION:${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}Cette opération va restaurer la configuration système.${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}Fichier: $(basename "$selected_backup")${COLORS[NC]}"
    
    if ! confirm_action "Continuer avec la restauration?"; then
        echo -e "${COLORS[YELLOW]}Restauration annulée${COLORS[NC]}"
        return 1
    fi
    
    local temp_restore_dir="/tmp/proxmox_restore_$$"
    mkdir -p "$temp_restore_dir"
    
    if tar -xzf "$selected_backup" -C "$temp_restore_dir" 2>/dev/null; then
        echo -e "${COLORS[GREEN]}✓ Archive extraite${COLORS[NC]}"
        
        # Restaurer les fichiers
        if cp -r "$temp_restore_dir/"* / 2>/dev/null; then
            echo -e "${COLORS[GREEN]}✓ Configuration restaurée${COLORS[NC]}"
            REBOOT_NEEDED=true
            log_message 1 "Backup restauré avec succès"
        else
            echo -e "${COLORS[RED]}✗ Échec de la restauration${COLORS[NC]}"
            rm -rf "$temp_restore_dir"
            return 1
        fi
    else
        echo -e "${COLORS[RED]}✗ Échec de l'extraction${COLORS[NC]}"
        rm -rf "$temp_restore_dir"
        return 1
    fi
    
    rm -rf "$temp_restore_dir"
    
    echo -e "\n${COLORS[YELLOW]}⚠ Redémarrage requis pour appliquer les changements${COLORS[NC]}"
    read -r -p "Appuyez sur Entrée pour continuer..."
    return 0
}

# ======================
# FONCTIONS D'AFFICHAGE
# ======================

display_welcome_message() {
    clear
    echo -e "${COLORS[BLUE]}===============================================${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}"
    cat << "EOF"
  ____  _             ____    ____  _             _       
 |  _ \| | __ _ _ __ | __ )  |  _ \| |_   _  __ _(_)_ __  
 | |_) | |/ _` | '_ \|  _ \  | |_) | | | | |/ _` | | '_ \ 
 |  __/| | (_| | | | | |_) | |  __/| | |_| | (_| | | | | |
 |_|   |_|\__,_|_| |_|____/  |_|   |_|\__,_|\__, |_|_| |_|
                                            |___/          
EOF
    echo -e "${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}===============================================${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}${COLORS[BOLD]}$SCRIPT_NAME${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}Version: $SCRIPT_VERSION${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}Date: $(date +"%Y-%m-%d")${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}Auteur: bluekeys.org${COLORS[NC]}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLORS[YELLOW]}${COLORS[BOLD]}🔍 MODE DRY-RUN ACTIVÉ${COLORS[NC]}"
    fi
    
    echo -e "${COLORS[BLUE]}===============================================${COLORS[NC]}"
    echo ""
}

display_system_info() {
    echo -e "${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   INFORMATIONS SYSTÈME                ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    local hostname distribution kernel arch cpu cores mem disk uptime load
    hostname=$(hostname 2>/dev/null || echo "N/A")
    distribution=$(lsb_release -d 2>/dev/null | cut -f2- || echo "N/A")
    kernel=$(uname -r)
    arch=$(uname -m)
    cpu=$(lscpu | grep "Model name" | cut -d ":" -f2 | xargs 2>/dev/null || echo "N/A")
    cores=$(nproc)
    mem=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
    disk=$(df -h / | awk '/\// {print $3 "/" $2}')
    uptime=$(uptime -p 2>/dev/null || echo "N/A")
    load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    
    echo -e "${COLORS[GREEN]}├─ Hôte:${COLORS[NC]} $hostname"
    echo -e "${COLORS[GREEN]}├─ Distribution:${COLORS[NC]} $distribution"
    echo -e "${COLORS[GREEN]}├─ Noyau:${COLORS[NC]} $kernel"
    echo -e "${COLORS[GREEN]}├─ Architecture:${COLORS[NC]} $arch"
    echo -e "${COLORS[GREEN]}├─ CPU:${COLORS[NC]} $cpu"
    echo -e "${COLORS[GREEN]}├─ Cœurs:${COLORS[NC]} $cores"
    echo -e "${COLORS[GREEN]}├─ Mémoire:${COLORS[NC]} $mem"
    echo -e "${COLORS[GREEN]}├─ Disque:${COLORS[NC]} $disk"
    echo -e "${COLORS[GREEN]}├─ Uptime:${COLORS[NC]} $uptime"
    echo -e "${COLORS[GREEN]}└─ Load:${COLORS[NC]} $load"
    
    if lspci | grep -qi nvidia; then
        echo -e "\n${COLORS[GREEN]}GPU NVIDIA détectés:${COLORS[NC]}"
        lspci | grep -i nvidia | sed 's/^/  ├─ /'
    fi
    
    # Afficher les warnings s'il y en a
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo -e "\n${COLORS[YELLOW]}⚠ Avertissements (${#WARNINGS[@]}):${COLORS[NC]}"
        for warning in "${WARNINGS[@]}"; do
            echo -e "  ${COLORS[YELLOW]}•${COLORS[NC]} $warning"
        done
    fi
    echo ""
}

display_step_progress() {
    local current_step=$1
    local total_steps=${#STEPS[@]}
    local progress=$((current_step * 100 / total_steps))
    local bar_length=40
    local filled=$((progress * bar_length / 100))
    local empty=$((bar_length - filled))
    
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   PROGRESSION: [$current_step/$total_steps] ${progress}%   ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    printf "${COLORS[GREEN]}["
    printf "%${filled}s" | tr ' ' '█'
    printf "${COLORS[GRAY]}"
    printf "%${empty}s" | tr ' ' '░'
    printf "${COLORS[NC]}] ${progress}%%\n\n"
    
    echo -e "${COLORS[YELLOW]}Étape actuelle: ${STEPS[$((current_step-1))]}${COLORS[NC]}\n"
}

display_summary() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   RÉSUMÉ DE LA CONFIGURATION         ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}\n"
    
    local success_count=0
    local failed_count=0
    local skipped_count=0
    
    for i in "${!STEPS[@]}"; do
        local step_num=$((i+1))
        local executed=false
        
        for choice in "${USER_CHOICES[@]}"; do
            if [[ $choice == *"$step_num"* ]]; then
                executed=true
                break
            fi
        done
        
        if [[ "$executed" == "true" ]]; then
            local failed=false
            for failed_step in "${FAILED_STEPS[@]}"; do
                if [[ "$failed_step" == "$step_num" ]]; then
                    failed=true
                    break
                fi
            done
            
            if [[ "$failed" == "false" ]]; then
                echo -e "${COLORS[GREEN]}✓ ${step_num}. ${STEPS[$i]}${COLORS[NC]}"
                ((success_count++))
            else
                echo -e "${COLORS[RED]}✗ ${step_num}. ${STEPS[$i]}${COLORS[NC]}"
                ((failed_count++))
            fi
        else
            echo -e "${COLORS[GRAY]}○ ${step_num}. ${STEPS[$i]} (ignorée)${COLORS[NC]}"
            ((skipped_count++))
        fi
    done
    
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   STATISTIQUES                        ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}├─ Réussies:${COLORS[NC]} $success_count"
    echo -e "${COLORS[RED]}├─ Échouées:${COLORS[NC]} $failed_count"
    echo -e "${COLORS[GRAY]}└─ Ignorées:${COLORS[NC]} $skipped_count"
    
    if [[ "$REBOOT_NEEDED" == "true" ]]; then
        echo -e "\n${COLORS[YELLOW]}${COLORS[BOLD]}⚠ ATTENTION: Un redémarrage est nécessaire${COLORS[NC]}"
    fi
    
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo -e "\n${COLORS[YELLOW]}${COLORS[BOLD]}⚠ ${#WARNINGS[@]} avertissement(s) enregistré(s)${COLORS[NC]}"
    fi
}

# ======================
# FONCTIONS DE VÉRIFICATION
# ======================

check_permissions() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_message 3 "Ce script doit être exécuté en tant que root"
        echo -e "${COLORS[RED]}✗ Ce script doit être exécuté en tant que root${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}Utilisez: sudo $0${COLORS[NC]}"
        exit 1
    fi
    log_message 1 "Vérification des permissions OK"
    return 0
}

check_disk_space() {
    local available_space
    available_space=$(df -k / | awk 'NR==2 {print $4}')
    
    if ! [[ "$available_space" =~ ^[0-9]+$ ]]; then
        error_handler 2 "Impossible de déterminer l'espace disque disponible" false
        return 1
    fi
    
    if [[ "$available_space" -lt "$MIN_DISK_SPACE_KB" ]]; then
        error_handler 3 "Espace disque insuffisant (requis: 1GB, disponible: $((available_space/1024))MB)" false
        return 1
    fi
    
    log_message 1 "Espace disque suffisant: $((available_space/1024))MB disponible"
    return 0
}

check_network_connectivity() {
    local test_hosts=("8.8.8.8" "1.1.1.1" "208.67.222.222")
    local online=false
    
    echo -e "${COLORS[BLUE]}🌐 Vérification de la connectivité réseau...${COLORS[NC]}"
    
    for host in "${test_hosts[@]}"; do
        if timeout 5 ping -c 1 -W 2 "$host" &> /dev/null; then
            log_message 1 "Connectivité réseau OK ($host)"
            online=true
            break
        fi
    done
    
    if [[ "$online" == "false" ]]; then
        error_handler 4 "Pas de connectivité réseau" false
        return 1
    fi
    
    # Test DNS
    if timeout 5 nslookup google.com &> /dev/null; then
        echo -e "${COLORS[GREEN]}✓ DNS fonctionnel${COLORS[NC]}"
    else
        echo -e "${COLORS[YELLOW]}⚠ Problème DNS détecté${COLORS[NC]}"
        WARNINGS+=("DNS resolution issues detected")
    fi
    
    return 0
}

check_dependencies() {
    log_message 1 "Vérification des dépendances"
    
    local -a dependencies=("jq" "wget" "curl" "git" "lsb-release" "unzip" "pciutils" "dkms")
    local -a missing_deps=()
    
    echo -e "${COLORS[BLUE]}📦 Vérification des dépendances...${COLORS[NC]}"
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
            echo -e "${COLORS[RED]}  ✗ $dep${COLORS[NC]}"
        else
            echo -e "${COLORS[GREEN]}  ✓ $dep${COLORS[NC]}"
        fi
    done
    
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        echo -e "\n${COLORS[YELLOW]}Dépendances manquantes: ${missing_deps[*]}${COLORS[NC]}"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${COLORS[YELLOW]}Mode dry-run: installation simulée${COLORS[NC]}"
            return 0
        fi
        
        if confirm_action "Installer les dépendances manquantes?" "y"; then
            configure_repositories
            apt-get update -qq || true
            
            echo -e "${COLORS[BLUE]}Installation en cours...${COLORS[NC]}"
            if apt-get install -y "${missing_deps[@]}"; then
                echo -e "${COLORS[GREEN]}✓ Dépendances installées${COLORS[NC]}"
                REBOOT_NEEDED=true
            else
                error_handler 5 "Échec de l'installation des dépendances" false
                return 1
            fi
        else
            error_handler 6 "Dépendances manquantes non installées" false
            return 1
        fi
    fi
    
    echo -e "${COLORS[GREEN]}✓ Toutes les dépendances sont satisfaites${COLORS[NC]}"
    return 0
}

check_proxmox_version() {
    log_message 1 "Vérification de la version de Proxmox"
    
    if ! command -v pveversion &> /dev/null; then
        error_handler 7 "Proxmox n'est pas installé" true
        return 1
    fi
    
    local current_version
    current_version=$(pveversion | awk -F'/' '{print $2}' | cut -d'-' -f1)
    
    if [[ -z "$current_version" ]]; then
        error_handler 8 "Impossible de déterminer la version de Proxmox" false
        return 1
    fi
    
    if [[ "$(printf '%s\n' "$REQUIRED_PVE_VERSION" "$current_version" | sort -V | head -n1)" != "$REQUIRED_PVE_VERSION" ]]; then
        error_handler 9 "Version de Proxmox incompatible (actuelle: $current_version, requise: >= $REQUIRED_PVE_VERSION)" true
        return 1
    fi
    
    echo -e "${COLORS[GREEN]}✓ Proxmox version $current_version détectée${COLORS[NC]}"
    return 0
}

check_gpu() {
    log_message 1 "Vérification du GPU"
    
    echo -e "${COLORS[BLUE]}🎮 Analyse des GPU...${COLORS[NC]}"
    
    if ! lspci | grep -qi nvidia; then
        echo -e "${COLORS[YELLOW]}⚠ Aucun GPU NVIDIA détecté via lspci${COLORS[NC]}"
        if ! confirm_action "Continuer sans GPU NVIDIA détecté?"; then
            error_handler 11 "GPU NVIDIA requis pour vGPU" false
            return 1
        fi
        return 0
    fi
    
    # Compter les GPU
    local gpu_count
    gpu_count=$(lspci | grep -i "vga.*nvidia" | wc -l)
    echo -e "${COLORS[GREEN]}✓ $gpu_count GPU NVIDIA détecté(s)${COLORS[NC]}"
    
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader 2>/dev/null || echo "N/A")
        echo -e "${COLORS[GREEN]}✓ GPU détecté: $gpu_info${COLORS[NC]}"
        
        # Vérifier la température
        local temp
        temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1)
        if [[ -n "$temp" ]] && [[ "$temp" -gt 80 ]]; then
            echo -e "${COLORS[YELLOW]}⚠ Température GPU élevée: ${temp}°C${COLORS[NC]}"
            WARNINGS+=("High GPU temperature: ${temp}°C")
        fi
    else
        echo -e "${COLORS[YELLOW]}⚠ nvidia-smi non disponible ou non fonctionnel${COLORS[NC]}"
    fi
    
    return 0
}

diagnose_iommu() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   DIAGNOSTIC IOMMU COMPLET            ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}\n"
    
    local iommu_score=0
    local max_score=5
    
    # 1. Groupes IOMMU
    echo -e "${COLORS[YELLOW]}🔍 Groupes IOMMU:${COLORS[NC]}"
    if [[ -d "/sys/kernel/iommu_groups" ]]; then
        local group_count
        group_count=$(find /sys/kernel/iommu_groups/ -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [[ "$group_count" -gt 0 ]]; then
            echo -e "${COLORS[GREEN]}   ✓ $group_count groupes IOMMU détectés${COLORS[NC]}"
            ((iommu_score++))
            
            echo -e "\n${COLORS[YELLOW]}Détails des groupes (premiers 20):${COLORS[NC]}"
            for d in /sys/kernel/iommu_groups/*/devices/*; do
                [[ -e "$d" ]] || continue
                local n=${d#*/iommu_groups/*}
                n=${n%%/*}
                printf "${COLORS[GREEN]}   Groupe %s:${COLORS[NC]} " "$n"
                lspci -nns "${d##*/}" 2>/dev/null || echo "N/A"
            done | sort -V | head -20
        else
            echo -e "${COLORS[RED]}   ✗ Aucun groupe IOMMU détecté${COLORS[NC]}"
        fi
    else
        echo -e "${COLORS[RED]}   ✗ Répertoire IOMMU non trouvé${COLORS[NC]}"
    fi
    
    # 2. Messages dmesg
    echo -e "\n${COLORS[YELLOW]}📋 Messages noyau IOMMU:${COLORS[NC]}"
    if dmesg | grep -q "DMAR: IOMMU enabled"; then
        echo -e "${COLORS[GREEN]}   ✓ Intel VT-d activé${COLORS[NC]}"
        ((iommu_score++))
    elif dmesg | grep -qi "AMD-Vi: IOMMU"; then
        echo -e "${COLORS[GREEN]}   ✓ AMD-Vi activé${COLORS[NC]}"
        ((iommu_score++))
    else
        echo -e "${COLORS[RED]}   ✗ Aucun message IOMMU détecté${COLORS[NC]}"
    fi
    
    # 3. Paramètres kernel
    echo -e "\n${COLORS[YELLOW]}🔧 Paramètres noyau:${COLORS[NC]}"
    if grep -q "intel_iommu=on\|amd_iommu=on" /proc/cmdline; then
        echo -e "${COLORS[GREEN]}   ✓ Paramètre IOMMU activé${COLORS[NC]}"
        grep -o "intel_iommu=[^ ]*\|amd_iommu=[^ ]*" /proc/cmdline | sed 's/^/      /'
        ((iommu_score++))
    else
        echo -e "${COLORS[RED]}   ✗ Paramètre IOMMU absent${COLORS[NC]}"
    fi
    
    if grep -q "iommu=pt" /proc/cmdline; then
        echo -e "${COLORS[GREEN]}   ✓ Mode passthrough activé${COLORS[NC]}"
        ((iommu_score++))
    fi
    
    # 4. Support CPU
    echo -e "\n${COLORS[YELLOW]}💻 Support matériel:${COLORS[NC]}"
    if grep -q "vmx" /proc/cpuinfo; then
        echo -e "${COLORS[GREEN]}   ✓ Intel VT-x (VMX) supporté${COLORS[NC]}"
        ((iommu_score++))
    elif grep -q "svm" /proc/cpuinfo; then
        echo -e "${COLORS[GREEN]}   ✓ AMD-V (SVM) supporté${COLORS[NC]}"
        ((iommu_score++))
    else
        echo -e "${COLORS[RED]}   ✗ Virtualisation matérielle non détectée${COLORS[NC]}"
    fi
    
    # 5. Modules VFIO
    echo -e "\n${COLORS[YELLOW]}🔌 Modules VFIO:${COLORS[NC]}"
    if lsmod | grep -q vfio; then
        echo -e "${COLORS[GREEN]}   ✓ VFIO chargé${COLORS[NC]}"
        lsmod | grep vfio | awk '{printf "      %-20s %10s\n", $1, $2}'
    else
        echo -e "${COLORS[YELLOW]}   ⚠ VFIO non chargé${COLORS[NC]}"
    fi
    
    # 6. GPU NVIDIA
    echo -e "\n${COLORS[YELLOW]}🎮 GPU NVIDIA:${COLORS[NC]}"
    local gpu
    gpu=$(lspci | grep -i "vga.*nvidia" | head -1)
    if [[ -n "$gpu" ]]; then
        local gpu_bus
        gpu_bus=$(echo "$gpu" | cut -d' ' -f1)
        echo -e "${COLORS[GREEN]}   ✓ GPU détecté: $gpu_bus${COLORS[NC]}"
        echo -e "      $(lspci -s "$gpu_bus")"
        
        if [[ -d "/sys/bus/pci/devices/0000:${gpu_bus}/iommu_group" ]]; then
            local iommu_group
            iommu_group=$(readlink "/sys/bus/pci/devices/0000:${gpu_bus}/iommu_group" 2>/dev/null | awk -F'/' '{print $NF}')
            if [[ -n "$iommu_group" ]]; then
                echo -e "${COLORS[GREEN]}   ✓ GPU dans groupe IOMMU $iommu_group${COLORS[NC]}"
            fi
        fi
    else
        echo -e "${COLORS[YELLOW]}   ⚠ Aucun GPU NVIDIA détecté${COLORS[NC]}"
    fi
    
    # Résumé avec score
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   RÉSUMÉ FINAL                        ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    local percentage=$((iommu_score * 100 / max_score))
    echo -e "${COLORS[CYAN]}Score IOMMU: $iommu_score/$max_score ($percentage%)${COLORS[NC]}"
    
    progress_bar "$iommu_score" "$max_score"
    echo -e "\n"
    
    local iommu_ok=false
    if [[ -d "/sys/kernel/iommu_groups" ]] && dmesg | grep -q "DMAR: IOMMU enabled\|AMD-Vi: IOMMU"; then
        iommu_ok=true
    fi
    
    if [[ "$iommu_ok" == "true" ]] && [[ $iommu_score -ge 4 ]]; then
        echo -e "${COLORS[GREEN]}${COLORS[BOLD]}✓ IOMMU est CORRECTEMENT ACTIVÉ et FONCTIONNEL${COLORS[NC]}"
        return 0
    else
        echo -e "${COLORS[RED]}${COLORS[BOLD]}✗ IOMMU N'EST PAS ACTIVÉ ou NON FONCTIONNEL${COLORS[NC]}"
        echo -e "\n${COLORS[YELLOW]}Actions recommandées:${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}1. Activer VT-d/AMD-Vi dans le BIOS${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}2. Configurer GRUB (option disponible ci-dessous)${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}3. Redémarrer le système${COLORS[NC]}"
        
        # Menu d'actions avec navigation
        while true; do
            echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
            echo -e "${COLORS[BLUE]}║   QUE VOULEZ-VOUS FAIRE ?             ║${COLORS[NC]}"
            echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
            echo -e "${COLORS[YELLOW]}1.${COLORS[NC]} Configurer GRUB automatiquement"
            echo -e "${COLORS[YELLOW]}2.${COLORS[NC]} Afficher les instructions manuelles"
            echo -e "${COLORS[YELLOW]}3.${COLORS[NC]} Passer cette étape"
            echo -e "${COLORS[YELLOW]}4.${COLORS[NC]} Retour au menu principal"
            echo -e "${COLORS[YELLOW]}5.${COLORS[NC]} Quitter"
            
            local action_choice
            read -r -p "Choisissez une option (1-5): " action_choice
            
            case $action_choice in
                1)
                    if enable_iommu; then
                        echo -e "\n${COLORS[GREEN]}✓ GRUB configuré avec succès${COLORS[NC]}"
                        REBOOT_NEEDED=true
                        if confirm_action "Redémarrer maintenant pour appliquer les changements?"; then
                            handle_reboot
                        fi
                    fi
                    return 1
                    ;;
                2) 
                    display_manual_iommu_instructions
                    ;;
                3) 
                    echo -e "${COLORS[YELLOW]}⚠ Étape IOMMU ignorée${COLORS[NC]}"
                    return 0
                    ;;
                4) return 1 ;;
                5) cleanup; exit 0 ;;
                *) echo -e "${COLORS[RED]}✗ Option invalide${COLORS[NC]}" ;;
            esac
        done
    fi
}

display_manual_iommu_instructions() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   INSTRUCTIONS MANUELLES IOMMU       ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}\n"
    
    echo -e "${COLORS[GREEN]}${COLORS[BOLD]}Étape 1: Configuration du BIOS${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}  • Redémarrez et entrez dans le BIOS/UEFI${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}  • Cherchez les options de virtualisation:${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}    - Intel: VT-d (Virtualization Technology for Directed I/O)${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}    - AMD: AMD-Vi ou IOMMU${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}  • Activez ces options${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}  • Sauvegardez et redémarrez${COLORS[NC]}"
    
    echo -e "\n${COLORS[GREEN]}${COLORS[BOLD]}Étape 2: Configuration de GRUB${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}  • Éditez le fichier GRUB:${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}    nano /etc/default/grub${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}  • Modifiez la ligne GRUB_CMDLINE_LINUX_DEFAULT:${COLORS[NC]}"
    
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        echo -e "${COLORS[BLUE]}    GRUB_CMDLINE_LINUX_DEFAULT=\"quiet intel_iommu=on iommu=pt\"${COLORS[NC]}"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        echo -e "${COLORS[BLUE]}    GRUB_CMDLINE_LINUX_DEFAULT=\"quiet amd_iommu=on iommu=pt\"${COLORS[NC]}"
    else
        echo -e "${COLORS[BLUE]}    Intel: GRUB_CMDLINE_LINUX_DEFAULT=\"quiet intel_iommu=on iommu=pt\"${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}    AMD:   GRUB_CMDLINE_LINUX_DEFAULT=\"quiet amd_iommu=on iommu=pt\"${COLORS[NC]}"
    fi
    
    echo -e "\n${COLORS[GREEN]}${COLORS[BOLD]}Étape 3: Mise à jour de GRUB${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}    update-grub${COLORS[NC]}"
    
    echo -e "\n${COLORS[GREEN]}${COLORS[BOLD]}Étape 4: Redémarrage${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}    reboot${COLORS[NC]}"
    
    echo -e "\n${COLORS[GREEN]}${COLORS[BOLD]}Étape 5: Vérification${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}  Après le redémarrage, vérifiez avec:${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}    dmesg | grep -e DMAR -e IOMMU${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}    find /sys/kernel/iommu_groups/ -type l${COLORS[NC]}"
    
    echo -e "\n${COLORS[YELLOW]}Appuyez sur Entrée pour continuer...${COLORS[NC]}"
    read -r
}

check_virtualization() {
    log_message 1 "Vérification de la virtualisation"
    
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   VÉRIFICATION VIRTUALISATION         ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    # Option de diagnostic
    if confirm_action "Exécuter le diagnostic IOMMU complet?" "y"; then
        diagnose_iommu
        return $?
    fi
    
    # Vérification CPU
    if ! grep -q "vmx\|svm" /proc/cpuinfo; then
        echo -e "${COLORS[YELLOW]}⚠ Virtualisation CPU non activée dans le BIOS${COLORS[NC]}"
        if ! confirm_action "Continuer malgré cette limitation?"; then
            error_handler 12 "Virtualisation CPU requise" false
            return 1
        fi
    else
        echo -e "${COLORS[GREEN]}✓ Virtualisation CPU activée${COLORS[NC]}"
    fi
    
    # Vérification IOMMU
    if ! dmesg | grep -q "DMAR: IOMMU enabled\|AMD-Vi: IOMMU"; then
        echo -e "${COLORS[YELLOW]}⚠ IOMMU non activé${COLORS[NC]}"
        
        if confirm_action "Activer IOMMU automatiquement?" "y"; then
            enable_iommu || {
                error_handler 13 "Échec de l'activation IOMMU" false
                return 1
            }
            REBOOT_NEEDED=true
        else
            if ! confirm_action "Continuer sans IOMMU?"; then
                error_handler 14 "IOMMU requis pour vGPU" false
                return 1
            fi
        fi
    else
        echo -e "${COLORS[GREEN]}✓ IOMMU activé et fonctionnel${COLORS[NC]}"
    fi
    
    return 0
}

enable_iommu() {
    log_message 1 "Activation automatique d'IOMMU"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLORS[YELLOW]}Mode dry-run: configuration IOMMU simulée${COLORS[NC]}"
        return 0
    fi
    
    # Créer une sauvegarde avant modification
    create_backup
    
    local cpu_type=""
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        cpu_type="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        cpu_type="amd"
    else
        error_handler 15 "Type de CPU non détecté" false
        return 1
    fi
    
    local grub_file="/etc/default/grub"
    if [[ ! -f "$grub_file" ]]; then
        error_handler 16 "Fichier GRUB introuvable" false
        return 1
    fi
    
    # Backup
    cp "$grub_file" "${grub_file}.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Configuration
    local iommu_params
    if [[ "$cpu_type" == "intel" ]]; then
        iommu_params="quiet intel_iommu=on iommu=pt"
    else
        iommu_params="quiet amd_iommu=on iommu=pt"
    fi
    
    sed -i.bak "s/GRUB_CMDLINE_LINUX_DEFAULT=\".*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$iommu_params\"/" "$grub_file"
    
    # Mise à jour GRUB
    echo -e "${COLORS[BLUE]}Mise à jour de GRUB...${COLORS[NC]}"
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub-mkconfig &> /dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        error_handler 17 "Commande GRUB introuvable" false
        return 1
    fi
    
    echo -e "${COLORS[GREEN]}✓ IOMMU configuré pour $cpu_type${COLORS[NC]}"
    return 0
}

# ======================
# FONCTIONS DE CONFIGURATION
# ======================

configure_repositories() {
    log_message 1 "Configuration des dépôts"
    
    while true; do
        echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}║   CONFIGURATION DES DÉPÔTS            ║${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}1.${COLORS[NC]} Configuration automatique (recommandé)"
        echo -e "${COLORS[YELLOW]}2.${COLORS[NC]} Ajouter des dépôts personnalisés"
        echo -e "${COLORS[YELLOW]}3.${COLORS[NC]} Voir les dépôts actuels"
        echo -e "${COLORS[YELLOW]}4.${COLORS[NC]} Nettoyer et réparer les dépôts"
        echo -e "${COLORS[YELLOW]}5.${COLORS[NC]} Passer cette étape"
        echo -e "${COLORS[YELLOW]}6.${COLORS[NC]} Retour"
        
        local repo_choice
        read -r -p "Choisissez une option (1-6): " repo_choice
        
        case $repo_choice in
            1)
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo -e "${COLORS[YELLOW]}Mode dry-run: configuration dépôts simulée${COLORS[NC]}"
                    sleep 2
                    return 0
                fi
                
                echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}║   CONFIGURATION AUTOMATIQUE           ║${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
                
                # Créer une sauvegarde
                create_backup
                
                mkdir -p /usr/share/keyrings
                
                # Étape 1: Nettoyage des dépôts problématiques
                echo -e "\n${COLORS[YELLOW]}📦 Étape 1/5: Nettoyage des dépôts enterprise...${COLORS[NC]}"
                local cleaned=0
                
                # Supprimer tous les fichiers de dépôts enterprise
                for file in /etc/apt/sources.list.d/pve-enterprise.list \
                           /etc/apt/sources.list.d/ceph.list \
                           /etc/apt/sources.list.d/pve-enterprise.sources \
                           /etc/apt/sources.list.d/ceph-squid.sources \
                           /etc/apt/sources.list.d/ceph-squid.list; do
                    if [[ -f "$file" ]]; then
                        rm -f "$file" && ((cleaned++))
                        echo -e "  ${COLORS[GREEN]}✓${COLORS[NC]} Supprimé: $(basename "$file")"
                    fi
                done
                
                # Nettoyer sources.list
                if [[ -f /etc/apt/sources.list ]]; then
                    if grep -q "enterprise.proxmox.com" /etc/apt/sources.list; then
                        sed -i.bak '/enterprise.proxmox.com/d' /etc/apt/sources.list
                        ((cleaned++))
                        echo -e "  ${COLORS[GREEN]}✓${COLORS[NC]} Nettoyé: sources.list"
                    fi
                fi
                
                [[ $cleaned -eq 0 ]] && echo -e "  ${COLORS[GRAY]}Aucun dépôt enterprise trouvé${COLORS[NC]}"
                
                # Étape 2: Installation de la clé GPG Proxmox
                echo -e "\n${COLORS[YELLOW]}🔑 Étape 2/5: Installation de la clé GPG Proxmox...${COLORS[NC]}"
                
                # Méthode 1: Avec wget
                if wget -qO /tmp/proxmox-release-bookworm.gpg http://download.proxmox.com/debian/proxmox-release-bookworm.gpg 2>/dev/null; then
                    mv /tmp/proxmox-release-bookworm.gpg /usr/share/keyrings/proxmox-release-bookworm.gpg
                    chmod 644 /usr/share/keyrings/proxmox-release-bookworm.gpg
                    echo -e "  ${COLORS[GREEN]}✓${COLORS[NC]} Clé GPG installée (méthode wget)"
                # Méthode 2: Avec curl
                elif curl -fsSL http://download.proxmox.com/debian/proxmox-release-bookworm.gpg -o /usr/share/keyrings/proxmox-release-bookworm.gpg 2>/dev/null; then
                    chmod 644 /usr/share/keyrings/proxmox-release-bookworm.gpg
                    echo -e "  ${COLORS[GREEN]}✓${COLORS[NC]} Clé GPG installée (méthode curl)"
                # Méthode 3: Avec apt-key (legacy)
                elif command -v apt-key &>/dev/null; then
                    wget -qO- http://download.proxmox.com/debian/proxmox-release-bookworm.gpg | apt-key add - 2>/dev/null
                    echo -e "  ${COLORS[GREEN]}✓${COLORS[NC]} Clé GPG installée (méthode apt-key)"
                else
                    echo -e "  ${COLORS[YELLOW]}⚠${COLORS[NC]} Impossible d'installer la clé GPG"
                fi
                
                # Étape 3: Configuration du dépôt no-subscription
                echo -e "\n${COLORS[YELLOW]}📚 Étape 3/5: Configuration du dépôt no-subscription...${COLORS[NC]}"
                
                # Détecter la version Debian/Proxmox
                local debian_codename="bookworm"
                if grep -q "trixie" /etc/os-release 2>/dev/null; then
                    debian_codename="trixie"
                fi
                
                cat > /etc/apt/sources.list.d/pve-no-subscription.list << EOF
# Proxmox VE No-Subscription Repository
# Vous pouvez utiliser ce dépôt gratuitement sans souscription
deb [signed-by=/usr/share/keyrings/proxmox-release-bookworm.gpg] http://download.proxmox.com/debian/pve $debian_codename pve-no-subscription
EOF
                echo -e "  ${COLORS[GREEN]}✓${COLORS[NC]} Dépôt no-subscription configuré"
                
                # Étape 4: Configuration des dépôts Debian
                echo -e "\n${COLORS[YELLOW]}📚 Étape 4/5: Configuration des dépôts Debian...${COLORS[NC]}"
                
                local -a debian_repos=(
                    "deb http://deb.debian.org/debian $debian_codename main contrib non-free non-free-firmware"
                    "deb http://deb.debian.org/debian $debian_codename-updates main contrib non-free non-free-firmware"
                    "deb http://security.debian.org/debian-security $debian_codename-security main contrib non-free non-free-firmware"
                )
                
                local added=0
                for repo in "${debian_repos[@]}"; do
                    if ! grep -qF "$repo" /etc/apt/sources.list 2>/dev/null; then
                        echo "$repo" >> /etc/apt/sources.list
                        ((added++))
                    fi
                done
                
                if [[ $added -gt 0 ]]; then
                    echo -e "  ${COLORS[GREEN]}✓${COLORS[NC]} $added dépôt(s) Debian ajouté(s)"
                else
                    echo -e "  ${COLORS[GRAY]}Dépôts Debian déjà configurés${COLORS[NC]}"
                fi
                
                # Étape 5: Mise à jour
                echo -e "\n${COLORS[YELLOW]}🔄 Étape 5/5: Mise à jour de la liste des paquets...${COLORS[NC]}"
                echo -e "${COLORS[GRAY]}Cela peut prendre quelques instants...${COLORS[NC]}"
                
                # Première tentative
                if apt-get update 2>&1 | tee /tmp/apt_update.log | grep -v "^Hit:\|^Get:\|^Ign:" | grep -v "^$"; then
                    echo -e "\n${COLORS[GREEN]}✓ Mise à jour réussie${COLORS[NC]}"
                    rm -f /tmp/apt_update.log
                else
                    local exit_code=${PIPESTATUS[0]}
                    
                    if [[ $exit_code -eq 0 ]]; then
                        echo -e "\n${COLORS[GREEN]}✓ Mise à jour réussie${COLORS[NC]}"
                        rm -f /tmp/apt_update.log
                    else
                        echo -e "\n${COLORS[YELLOW]}⚠ La mise à jour a rencontré des problèmes${COLORS[NC]}"
                        
                        # Analyser et corriger les erreurs
                        local needs_retry=false
                        
                        if grep -q "401.*Unauthorized" /tmp/apt_update.log; then
                            echo -e "\n${COLORS[YELLOW]}${COLORS[BOLD]}INFO:${COLORS[NC]} Erreurs 401 détectées"
                            echo -e "${COLORS[GRAY]}  → Certains dépôts enterprise n'ont pas été complètement nettoyés${COLORS[NC]}"
                            echo -e "${COLORS[GRAY]}  → Nettoyage approfondi en cours...${COLORS[NC]}"
                            
                            # Nettoyage approfondi
                            find /etc/apt/sources.list.d/ -type f \( -name "*.list" -o -name "*.sources" \) -exec grep -l "enterprise.proxmox.com" {} \; -delete
                            sed -i '/enterprise.proxmox.com/d' /etc/apt/sources.list
                            needs_retry=true
                        fi
                        
                        if grep -q "signature verification failed\|OpenPGP\|Missing key" /tmp/apt_update.log; then
                            echo -e "\n${COLORS[YELLOW]}${COLORS[BOLD]}INFO:${COLORS[NC]} Problème de signature GPG"
                            echo -e "${COLORS[GRAY]}  → Réinstallation de la clé...${COLORS[NC]}"
                            
                            # Forcer la réinstallation de la clé
                            rm -f /usr/share/keyrings/proxmox-release-bookworm.gpg
                            
                            if wget -qO /usr/share/keyrings/proxmox-release-bookworm.gpg http://download.proxmox.com/debian/proxmox-release-bookworm.gpg 2>/dev/null; then
                                chmod 644 /usr/share/keyrings/proxmox-release-bookworm.gpg
                                echo -e "  ${COLORS[GREEN]}✓ Clé GPG réinstallée${COLORS[NC]}"
                                needs_retry=true
                            fi
                        fi
                        
                        # Réessayer si nécessaire
                        if [[ "$needs_retry" == "true" ]]; then
                            echo -e "\n${COLORS[BLUE]}🔄 Nouvelle tentative de mise à jour...${COLORS[NC]}"
                            if apt-get update -qq 2>&1 | grep -v "^Hit:\|^Get:\|^Ign:" | grep -v "^$"; then
                                :
                            fi
                            
                            if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
                                echo -e "${COLORS[GREEN]}✓ Mise à jour réussie après correction${COLORS[NC]}"
                            else
                                echo -e "${COLORS[RED]}✗ Échec persistant${COLORS[NC]}"
                                
                                if confirm_action "Afficher les détails des erreurs?" "n"; then
                                    cat /tmp/apt_update.log
                                fi
                            fi
                        else
                            if confirm_action "Afficher les détails des erreurs?" "n"; then
                                cat /tmp/apt_update.log
                            fi
                        fi
                        
                        rm -f /tmp/apt_update.log
                    fi
                fi
                
                echo -e "\n${COLORS[GREEN]}╔═══════════════════════════════════════╗${COLORS[NC]}"
                echo -e "${COLORS[GREEN]}║   CONFIGURATION TERMINÉE              ║${COLORS[NC]}"
                echo -e "${COLORS[GREEN]}╚═══════════════════════════════════════╝${COLORS[NC]}"
                
                echo -e "\n${COLORS[YELLOW]}Appuyez sur Entrée pour continuer...${COLORS[NC]}"
                read -r
                ;;
                
            2) add_custom_repositories ;;
                
            3)
                echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}║   DÉPÔTS ACTUELS                      ║${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
                echo -e "\n${COLORS[YELLOW]}Fichier sources.list:${COLORS[NC]}"
                grep -v "^#" /etc/apt/sources.list 2>/dev/null | grep -v "^$" | sed 's/^/  /' || echo "  Vide"
                
                echo -e "\n${COLORS[YELLOW]}Fichiers sources.list.d:${COLORS[NC]}"
                for file in /etc/apt/sources.list.d/*.{list,sources}; do
                    [[ -f "$file" ]] || continue
                    echo -e "${COLORS[GREEN]}  $(basename "$file"):${COLORS[NC]}"
                    grep -v "^#" "$file" 2>/dev/null | grep -v "^$" | sed 's/^/    /' || echo "    Vide"
                done
                
                echo -e "\n${COLORS[YELLOW]}Appuyez sur Entrée pour continuer...${COLORS[NC]}"
                read -r
                ;;
                
            4)
                echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}║   NETTOYAGE ET RÉPARATION             ║${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
                
                echo -e "\n${COLORS[YELLOW]}Cette opération va:${COLORS[NC]}"
                echo -e "${COLORS[GRAY]}  • Supprimer tous les dépôts enterprise${COLORS[NC]}"
                echo -e "${COLORS[GRAY]}  • Réinstaller les clés GPG${COLORS[NC]}"
                echo -e "${COLORS[GRAY]}  • Nettoyer le cache APT${COLORS[NC]}"
                
                if confirm_action "Continuer?" "y"; then
                    create_backup
                    
                    # Nettoyage complet
                    find /etc/apt/sources.list.d/ -type f \( -name "*.list" -o -name "*.sources" \) -exec grep -l "enterprise.proxmox.com" {} \; -delete
                    sed -i.bak '/enterprise.proxmox.com/d' /etc/apt/sources.list
                    
                    # Nettoyage cache
                    apt-get clean
                    rm -rf /var/lib/apt/lists/*
                    mkdir -p /var/lib/apt/lists/partial
                    
                    # Réinstaller clés
                    rm -f /usr/share/keyrings/proxmox-release-bookworm.gpg
                    wget -qO /usr/share/keyrings/proxmox-release-bookworm.gpg http://download.proxmox.com/debian/proxmox-release-bookworm.gpg 2>/dev/null
                    chmod 644 /usr/share/keyrings/proxmox-release-bookworm.gpg
                    
                    echo -e "${COLORS[GREEN]}✓ Nettoyage terminé${COLORS[NC]}"
                    
                    if confirm_action "Mettre à jour les dépôts maintenant?" "y"; then
                        apt-get update
                    fi
                fi
                
                echo -e "\n${COLORS[YELLOW]}Appuyez sur Entrée pour continuer...${COLORS[NC]}"
                read -r
                ;;
                
            5) 
                echo -e "${COLORS[YELLOW]}⚠ Configuration des dépôts ignorée${COLORS[NC]}"
                return 0
                ;;
                
            6) return 0 ;;
                
            *)
                echo -e "${COLORS[RED]}✗ Option invalide${COLORS[NC]}"
                sleep 1
                ;;
        esac
    done
}

add_custom_repositories() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   AJOUTER DES DÉPÔTS PERSONNALISÉS    ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    echo -e "\n${COLORS[YELLOW]}Exemples de dépôts valides:${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}  deb http://deb.debian.org/debian bookworm main${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}  deb [arch=amd64] http://example.com/debian stable main${COLORS[NC]}"
    
    echo -e "\n${COLORS[YELLOW]}Entrez les dépôts à ajouter (un par ligne)${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}Ligne vide pour terminer${COLORS[NC]}\n"
    
    local added_repos=0
    local repo_line
    while true; do
        read -r -p "Dépôt $((added_repos + 1)): " repo_line
        
        [[ -z "$repo_line" ]] && break
        
        if [[ ! "$repo_line" =~ ^deb ]]; then
            echo -e "${COLORS[RED]}✗ Le dépôt doit commencer par 'deb' ou 'deb-src'${COLORS[NC]}"
            continue
        fi
        
        if grep -qF "$repo_line" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
            echo -e "${COLORS[YELLOW]}⚠ Ce dépôt existe déjà${COLORS[NC]}"
            continue
        fi
        
        echo -e "${COLORS[YELLOW]}Ajouter: ${COLORS[BLUE]}$repo_line${COLORS[NC]}"
        if confirm_action "Confirmer?" "y"; then
            echo "$repo_line" >> /etc/apt/sources.list
            echo -e "${COLORS[GREEN]}✓ Dépôt ajouté${COLORS[NC]}"
            ((added_repos++))
        fi
    done
    
    if [[ $added_repos -gt 0 ]]; then
        echo -e "\n${COLORS[GREEN]}$added_repos dépôt(s) ajouté(s)${COLORS[NC]}"
        
        if confirm_action "Mettre à jour la liste des paquets maintenant?" "y"; then
            echo -e "${COLORS[BLUE]}Mise à jour...${COLORS[NC]}"
            apt-get update -qq && echo -e "${COLORS[GREEN]}✓ Mise à jour réussie${COLORS[NC]}" || echo -e "${COLORS[RED]}✗ Échec${COLORS[NC]}"
        fi
    else
        echo -e "${COLORS[YELLOW]}Aucun dépôt ajouté${COLORS[NC]}"
    fi
    
    echo -e "\n${COLORS[YELLOW]}Appuyez sur Entrée pour continuer...${COLORS[NC]}"
    read -r
}

install_packages() {
    log_message 1 "Installation des paquets"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLORS[YELLOW]}Mode dry-run: installation paquets simulée${COLORS[NC]}"
        return 0
    fi
    
    local -a base_packages=("jq" "git" "lsb-release" "unzip" "build-essential" "dkms" "software-properties-common" "pciutils")
    
    echo -e "${COLORS[BLUE]}Installation des paquets de base...${COLORS[NC]}"
    
    local total=${#base_packages[@]}
    local current=0
    
    for pkg in "${base_packages[@]}"; do
        ((current++))
        progress_bar "$current" "$total"
        apt-get install -y -qq "$pkg" 2>/dev/null || true
    done
    echo ""
    
    echo -e "${COLORS[GREEN]}✓ Paquets de base installés${COLORS[NC]}"
    
    if confirm_action "Installer des paquets supplémentaires?"; then
        echo -e "${COLORS[YELLOW]}Entrez les noms des paquets (séparés par des espaces):${COLORS[NC]}"
        local additional_packages
        read -r additional_packages
        
        if [[ -n "$additional_packages" ]]; then
            if apt-get install -y $additional_packages; then
                echo -e "${COLORS[GREEN]}✓ Paquets supplémentaires installés${COLORS[NC]}"
            else
                log_message 2 "Échec de l'installation de certains paquets supplémentaires"
            fi
        fi
    fi
    
    echo -e "${COLORS[GREEN]}✓ Installation des paquets terminée${COLORS[NC]}"
    return 0
}

uninstall_nvidia_driver() {
    log_message 1 "Vérification du pilote NVIDIA standard"
    
    if command -v nvidia-uninstall &> /dev/null; then
        echo -e "${COLORS[YELLOW]}⚠ Pilote NVIDIA standard détecté${COLORS[NC]}"
        
        if confirm_action "Désinstaller le pilote NVIDIA standard?" "y"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                echo -e "${COLORS[YELLOW]}Mode dry-run: désinstallation simulée${COLORS[NC]}"
                return 0
            fi
            
            if nvidia-uninstall; then
                echo -e "${COLORS[GREEN]}✓ Pilote NVIDIA désinstallé${COLORS[NC]}"
                REBOOT_NEEDED=true
            else
                error_handler 19 "Échec de la désinstallation du pilote NVIDIA" false
                return 1
            fi
        fi
    else
        echo -e "${COLORS[GREEN]}✓ Aucun pilote NVIDIA standard détecté${COLORS[NC]}"
    fi
    return 0
}

configure_vgpu() {
    log_message 1 "Configuration vGPU"
    
    local -a helper_paths=(
        "/usr/bin/pve-nvidia-vgpu-helper"
        "/usr/local/bin/pve-nvidia-vgpu-helper"
        "/bin/pve-nvidia-vgpu-helper"
        "/opt/pve-nvidia-vgpu-helper"
    )
    
    local helper_found=false
    local helper_path=""
    
    for path in "${helper_paths[@]}"; do
        if [[ -f "$path" ]]; then
            helper_found=true
            helper_path="$path"
            break
        fi
    done
    
    while true; do
        echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}║   CONFIGURATION vGPU                  ║${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}1.${COLORS[NC]} Afficher les informations GPU"
        echo -e "${COLORS[YELLOW]}2.${COLORS[NC]} Vérifier les prérequis vGPU"
        
        if [[ "$helper_found" == "true" ]]; then
            echo -e "${COLORS[YELLOW]}3.${COLORS[NC]} Exécuter pve-nvidia-vgpu-helper ${COLORS[GREEN]}(disponible)${COLORS[NC]}"
        else
            echo -e "${COLORS[YELLOW]}3.${COLORS[NC]} Exécuter pve-nvidia-vgpu-helper ${COLORS[RED]}(non trouvé)${COLORS[NC]}"
        fi
        
        echo -e "${COLORS[YELLOW]}4.${COLORS[NC]} Configuration manuelle vGPU"
        echo -e "${COLORS[YELLOW]}5.${COLORS[NC]} Vérifier la configuration actuelle"
        echo -e "${COLORS[YELLOW]}6.${COLORS[NC]} Passer cette étape"
        echo -e "${COLORS[YELLOW]}7.${COLORS[NC]} Retour au menu principal"
        
        show_menu_navigation
        
        local vgpu_choice
        read -r -p "Choisissez une option (1-7): " vgpu_choice
        
        case $vgpu_choice in
            1) display_gpu_info ;;
            2) check_vgpu_prerequisites ;;
            3)
                if [[ "$helper_found" == "true" ]]; then
                    run_vgpu_helper "$helper_path"
                else
                    echo -e "${COLORS[RED]}✗ pve-nvidia-vgpu-helper non trouvé${COLORS[NC]}"
                    error_handler 20 "Helper vGPU introuvable" false
                fi
                ;;
            4) manual_vgpu_config ;;
            5) verify_vgpu_config ;;
            6) 
                echo -e "${COLORS[YELLOW]}⚠ Configuration vGPU ignorée${COLORS[NC]}"
                return 0
                ;;
            7) return 0 ;;
            n) return 1 ;;  # Next
            m) return 0 ;;  # Menu
            q) cleanup; exit 0 ;;
            *) echo -e "${COLORS[RED]}Option invalide${COLORS[NC]}" ;;
        esac
    done
}

display_gpu_info() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   INFORMATIONS GPU                    ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    if ! command -v nvidia-smi &> /dev/null; then
        echo -e "${COLORS[YELLOW]}⚠ nvidia-smi non disponible${COLORS[NC]}"
        read -r -p "Appuyez sur Entrée pour continuer..."
        return 1
    fi
    
    if nvidia-smi --query-gpu=index,name,driver_version,memory.total,temperature.gpu,utilization.gpu,power.draw --format=csv,noheader 2>/dev/null | \
        awk -F', ' '{printf "GPU %s: %s\n  Pilote: %s | Mémoire: %s | Temp: %s | Util: %s | Power: %s\n", $1, $2, $3, $4, $5, $6, $7}'; then
        :
    else
        echo -e "${COLORS[YELLOW]}⚠ Erreur lors de la récupération des informations GPU${COLORS[NC]}"
    fi
    
    if nvidia-smi vgpu &> /dev/null; then
        echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}║   INFORMATIONS vGPU                   ║${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
        nvidia-smi vgpu 2>/dev/null || echo -e "${COLORS[YELLOW]}⚠ Aucun vGPU configuré${COLORS[NC]}"
    fi
    
    echo -e "\n${COLORS[YELLOW]}Appuyez sur Entrée pour continuer...${COLORS[NC]}"
    read -r
}

check_vgpu_prerequisites() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   VÉRIFICATION PRÉREQUIS vGPU         ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    local all_ok=true
    local score=0
    local max_score=4
    
    # IOMMU
    if ! dmesg | grep -q "DMAR: IOMMU enabled\|AMD-Vi: IOMMU"; then
        echo -e "${COLORS[RED]}✗ IOMMU non activé${COLORS[NC]}"
        all_ok=false
    else
        echo -e "${COLORS[GREEN]}✓ IOMMU activé${COLORS[NC]}"
        ((score++))
    fi
    
    # VFIO
    if ! lsmod | grep -q vfio; then
        echo -e "${COLORS[YELLOW]}⚠ Module VFIO non chargé${COLORS[NC]}"
        if confirm_action "Charger le module VFIO?" "y"; then
            if modprobe vfio-pci; then
                echo -e "${COLORS[GREEN]}✓ VFIO chargé${COLORS[NC]}"
                ((score++))
            else
                all_ok=false
            fi
        else
            all_ok=false
        fi
    else
        echo -e "${COLORS[GREEN]}✓ VFIO chargé${COLORS[NC]}"
        ((score++))
    fi
    
    # Noyau
    if [[ ! "$(uname -r)" =~ pve ]]; then
        echo -e "${COLORS[RED]}✗ Noyau Proxmox non chargé (actuel: $(uname -r))${COLORS[NC]}"
        all_ok=false
    else
        echo -e "${COLORS[GREEN]}✓ Noyau Proxmox chargé${COLORS[NC]}"
        ((score++))
    fi
    
    # Pilotes NVIDIA
    if ! command -v nvidia-smi &> /dev/null || ! nvidia-smi &> /dev/null; then
        echo -e "${COLORS[RED]}✗ Pilotes NVIDIA non fonctionnels${COLORS[NC]}"
        all_ok=false
    else
        echo -e "${COLORS[GREEN]}✓ Pilotes NVIDIA fonctionnels${COLORS[NC]}"
        ((score++))
    fi
    
    # Afficher le score
    echo -e "\n${COLORS[CYAN]}Score: $score/$max_score${COLORS[NC]}"
    progress_bar "$score" "$max_score"
    echo -e "\n"
    
    if [[ "$all_ok" == "false" ]]; then
        echo -e "\n${COLORS[RED]}⚠ Certains prérequis ne sont pas satisfaits${COLORS[NC]}"
        display_prerequisites_solutions
        read -r -p "Appuyez sur Entrée pour continuer..." 
        return 1
    else
        echo -e "\n${COLORS[GREEN]}✓ Tous les prérequis sont satisfaits${COLORS[NC]}"
        read -r -p "Appuyez sur Entrée pour continuer..." 
        return 0
    fi
}

display_prerequisites_solutions() {
    echo -e "\n${COLORS[YELLOW]}Solutions recommandées:${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}• IOMMU: Activer VT-d/AMD-Vi dans le BIOS + configurer GRUB${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}• VFIO: modprobe vfio-pci${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}• Noyau: Installer et charger un noyau Proxmox (pve)${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}• NVIDIA: Installer les pilotes vGPU NVIDIA${COLORS[NC]}"
}

run_vgpu_helper() {
    local helper_path=$1
    
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   EXÉCUTION VGPU HELPER               ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    if [[ ! -f "$helper_path" ]]; then
        error_handler 21 "Script helper introuvable: $helper_path" false
        return 1
    fi
    
    [[ -x "$helper_path" ]] || chmod +x "$helper_path"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLORS[YELLOW]}Mode dry-run: exécution vGPU helper simulée${COLORS[NC]}"
        read -r -p "Appuyez sur Entrée pour continuer..."
        return 0
    fi
    
    if perl "$helper_path" setup; then
        echo -e "${COLORS[GREEN]}✓ Configuration vGPU terminée${COLORS[NC]}"
    else
        error_handler 22 "Échec de l'exécution du helper" false
        return 1
    fi
    
    read -r -p "Appuyez sur Entrée pour continuer..." 
    return 0
}

manual_vgpu_config() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   CONFIGURATION MANUELLE vGPU         ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}Instructions pour configuration manuelle:${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}1.${COLORS[NC]} Identifier le bus PCI du GPU:"
    echo -e "   ${COLORS[BLUE]}lspci | grep -i nvidia${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}2.${COLORS[NC]} Charger le module VFIO:"
    echo -e "   ${COLORS[BLUE]}modprobe vfio-pci${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}3.${COLORS[NC]} Lier le GPU à VFIO:"
    echo -e "   ${COLORS[BLUE]}echo 'device_id' > /sys/bus/pci/drivers/vfio-pci/new_id${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}4.${COLORS[NC]} Configurer les vGPU dans Proxmox via l'interface web"
    echo -e "\n${COLORS[YELLOW]}Note: Utilisez pve-nvidia-vgpu-helper pour une configuration automatique${COLORS[NC]}"
    
    read -r -p "Appuyez sur Entrée pour continuer..." 
}

verify_vgpu_config() {
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   VÉRIFICATION CONFIGURATION vGPU     ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    # Modules
    echo -e "\n${COLORS[YELLOW]}Modules chargés:${COLORS[NC]}"
    if lsmod | grep -E "vfio|nvidia"; then
        lsmod | grep -E "vfio|nvidia" | awk '{printf "  %-20s %10s\n", $1, $2}'
    else
        echo -e "${COLORS[RED]}  ✗ Aucun module vfio ou nvidia chargé${COLORS[NC]}"
    fi
    
    # Paramètres kernel
    echo -e "\n${COLORS[YELLOW]}Paramètres kernel:${COLORS[NC]}"
    grep -o -E "(intel_iommu|amd_iommu|iommu|vfio)[^[:space:]]*" /proc/cmdline | sed 's/^/  /' || echo "  Aucun"
    
    # Status vGPU
    echo -e "\n${COLORS[YELLOW]}Status vGPU:${COLORS[NC]}"
    if command -v nvidia-smi &> /dev/null && nvidia-smi vgpu &> /dev/null; then
        nvidia-smi vgpu | sed 's/^/  /'
    else
        echo -e "${COLORS[YELLOW]}  ⚠ Aucun vGPU détecté ou nvidia-smi non disponible${COLORS[NC]}"
    fi
    
    # Logs récents
    echo -e "\n${COLORS[YELLOW]}Messages récents:${COLORS[NC]}"
    dmesg | grep -i -E "vfio|nvidia|iommu" | tail -5 | sed 's/^/  /'
    
    read -r -p "Appuyez sur Entrée pour continuer..." 
}

update_initramfs() {
    log_message 1 "Mise à jour de initramfs"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLORS[YELLOW]}Mode dry-run: mise à jour initramfs simulée${COLORS[NC]}"
        return 0
    fi
    
    echo -e "${COLORS[BLUE]}Mise à jour de initramfs...${COLORS[NC]}"
    echo -e "${COLORS[GRAY]}Cette opération peut prendre quelques minutes...${COLORS[NC]}"
    
    if timeout $TIMEOUT_SECONDS update-initramfs -u -k all 2>&1 | grep -v "update-initramfs: Generating"; then
        echo -e "${COLORS[GREEN]}✓ initramfs mis à jour${COLORS[NC]}"
        REBOOT_NEEDED=true
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            error_handler 23 "Timeout lors de la mise à jour de initramfs" false
        else
            error_handler 23 "Échec de la mise à jour de initramfs" false
        fi
        return 1
    fi
}

# ======================
# GESTION DES ÉTATS
# ======================

save_state() {
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    if ! command -v jq &> /dev/null; then
        log_message 2 "jq non disponible, sauvegarde d'état impossible"
        return 1
    fi
    
    [[ -f "$STATE_FILE" ]] && cp "$STATE_FILE" "${STATE_FILE}.bak" 2>/dev/null || true
    
    local hostname distribution kernel
    hostname=$(hostname 2>/dev/null || echo "unknown")
    kernel=$(uname -r 2>/dev/null || echo "unknown")
    distribution=$(lsb_release -d 2>/dev/null | cut -f2- || echo "unknown")
    
    # Créer le JSON
    local temp_file="${STATE_FILE}.tmp"
    {
        echo "{"
        echo "  \"metadata\": {"
        echo "    \"timestamp\": \"$timestamp\","
        echo "    \"script_version\": \"$SCRIPT_VERSION\","
        echo "    \"reboot_needed\": $([[ "$REBOOT_NEEDED" == "true" ]] && echo "true" || echo "false"),"
        echo "    \"backup_created\": $([[ "$BACKUP_CREATED" == "true" ]] && echo "true" || echo "false")"
        echo "  },"
        echo "  \"system_info\": {"
        echo "    \"hostname\": \"$hostname\","
        echo "    \"kernel\": \"$kernel\","
        echo "    \"distribution\": \"$distribution\""
        echo "  },"
        echo "  \"user_choices\": $(printf '%s\n' "${USER_CHOICES[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]'),"
        echo "  \"executed_steps\": $(printf '%s\n' "${EXECUTED_STEPS[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]'),"
        echo "  \"failed_steps\": $(printf '%s\n' "${FAILED_STEPS[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]'),"
        echo "  \"warnings\": $(printf '%s\n' "${WARNINGS[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')"
        echo "}"
    } > "$temp_file" 2>/dev/null || {
        log_message 3 "Échec de la création du fichier d'état"
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    }
    
    if jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$STATE_FILE" 2>/dev/null || true
        log_message 1 "État sauvegardé"
        return 0
    else
        log_message 3 "État JSON invalide"
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    fi
}

load_state() {
    [[ -f "$STATE_FILE" ]] || return 1
    
    if ! command -v jq &> /dev/null; then
        log_message 2 "jq non disponible, chargement d'état impossible"
        return 1
    fi
    
    if ! jq empty "$STATE_FILE" 2>/dev/null; then
        log_message 2 "État corrompu, suppression"
        rm -f "$STATE_FILE" 2>/dev/null || true
        return 1
    fi
    
    local reboot_status
    reboot_status=$(jq -r '.metadata.reboot_needed' "$STATE_FILE" 2>/dev/null || echo "false")
    REBOOT_NEEDED="$reboot_status"
    
    local backup_status
    backup_status=$(jq -r '.metadata.backup_created' "$STATE_FILE" 2>/dev/null || echo "false")
    BACKUP_CREATED="$backup_status"
    
    local state_timestamp
    state_timestamp=$(jq -r '.metadata.timestamp' "$STATE_FILE" 2>/dev/null || echo "date inconnue")
    
    local state_version
    state_version=$(jq -r '.metadata.script_version' "$STATE_FILE" 2>/dev/null || echo "inconnue")
    
    local executed_count
    executed_count=$(jq -r '.executed_steps | length' "$STATE_FILE" 2>/dev/null || echo "0")
    
    local warnings_count
    warnings_count=$(jq -r '.warnings | length' "$STATE_FILE" 2>/dev/null || echo "0")
    
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   ÉTAT PRÉCÉDENT DÉTECTÉ             ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}⚠ État précédent trouvé${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}├─ Date:${COLORS[NC]} $state_timestamp"
    echo -e "${COLORS[GREEN]}├─ Version script:${COLORS[NC]} $state_version"
    echo -e "${COLORS[GREEN]}├─ Étapes exécutées:${COLORS[NC]} $executed_count"
    echo -e "${COLORS[GREEN]}├─ Avertissements:${COLORS[NC]} $warnings_count"
    echo -e "${COLORS[GREEN]}└─ Redémarrage nécessaire:${COLORS[NC]} $([ "$reboot_status" = "true" ] && echo "Oui" || echo "Non")"
    echo ""
    
    if confirm_action "Reprendre l'état précédent?" "y"; then
        mapfile -t USER_CHOICES < <(jq -r '.user_choices[]' "$STATE_FILE" 2>/dev/null || true)
        mapfile -t EXECUTED_STEPS < <(jq -r '.executed_steps[]' "$STATE_FILE" 2>/dev/null || true)
        mapfile -t FAILED_STEPS < <(jq -r '.failed_steps[]' "$STATE_FILE" 2>/dev/null || true)
        mapfile -t WARNINGS < <(jq -r '.warnings[]' "$STATE_FILE" 2>/dev/null || true)
        log_message 1 "État précédent chargé"
        echo -e "${COLORS[GREEN]}✓ État restauré avec succès${COLORS[NC]}"
        sleep 2
        return 0
    else
        rm -f "$STATE_FILE" 2>/dev/null || true
        log_message 1 "État précédent supprimé"
        echo -e "${COLORS[YELLOW]}État précédent ignoré et supprimé${COLORS[NC]}"
        sleep 2
        return 1
    fi
}

handle_reboot() {
    if [[ "$REBOOT_NEEDED" != "true" ]]; then
        return 0
    fi
    
    # Empêcher les exécutions multiples
    if [[ "$REBOOT_IN_PROGRESS" == "true" ]]; then
        return 0
    fi
    
    REBOOT_IN_PROGRESS=true
    
    echo -e "\n${COLORS[YELLOW]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}║   REDÉMARRAGE NÉCESSAIRE              ║${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    
    echo -e "${COLORS[YELLOW]}Un redémarrage est requis pour appliquer les modifications.${COLORS[NC]}"
    echo -e "${COLORS[GRAY]}Les changements nécessitant un redémarrage :${COLORS[NC]}"
    echo -e "${COLORS[GRAY]}  • Configuration IOMMU${COLORS[NC]}"
    echo -e "${COLORS[GRAY]}  • Mise à jour initramfs${COLORS[NC]}"
    echo -e "${COLORS[GRAY]}  • Installation de nouveaux modules${COLORS[NC]}"
    echo ""
    
    if confirm_action "Redémarrer maintenant?" "y"; then
        save_state
        touch "/tmp/proxmox_rebooted"
        log_message 1 "Redémarrage initié"
        
        echo -e "\n${COLORS[BLUE]}${COLORS[BOLD]}Préparation au redémarrage...${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}Redémarrage dans 5 secondes...${COLORS[NC]}"
        
        # Afficher un compte à rebours
        for i in {5..1}; do
            echo -ne "${COLORS[YELLOW]}$i...${COLORS[NC]} "
            sleep 1
        done
        echo ""
        
        # Empêcher toute interaction supplémentaire
        exec reboot
    else
        echo -e "${COLORS[YELLOW]}⚠ Redémarrage reporté${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}⚠ Pensez à redémarrer ultérieurement pour finaliser la configuration${COLORS[NC]}"
        REBOOT_NEEDED=false
        REBOOT_IN_PROGRESS=false
    fi
}

# ======================
# EXÉCUTION DES ÉTAPES
# ======================

execute_step() {
    local step=$1
    
    if [[ $step -lt 1 ]] || [[ $step -gt ${#STEPS[@]} ]]; then
        echo -e "${COLORS[RED]}✗ Étape invalide: $step${COLORS[NC]}"
        return 1
    fi
    
    display_step_progress "$step"
    
    local success=true
    
    case $step in
        1) display_welcome_message ;;
        2) display_system_info ;;
        3) check_script_version ;;
        4) load_state ;;
        5) check_permissions && check_disk_space && check_network_connectivity && check_proxmox_version || success=false ;;
        6) check_dependencies || success=false ;;
        7) configure_repositories || success=false ;;
        8) install_packages || success=false ;;
        9) uninstall_nvidia_driver || success=false ;;
        10) check_virtualization || success=false ;;
        11) check_gpu || success=false ;;
        12) configure_vgpu || success=false ;;
        13) update_initramfs || success=false ;;
        14) handle_reboot ;;
        *) echo -e "${COLORS[RED]}✗ Étape non implémentée: $step${COLORS[NC]}"; success=false ;;
    esac
    
    if [[ "$success" == "true" ]]; then
        echo -e "${COLORS[GREEN]}✓ Étape $step terminée: ${STEPS[$((step-1))]}${COLORS[NC]}"
        EXECUTED_STEPS+=("$step")
        USER_CHOICES+=("step_$step")
    else
        echo -e "${COLORS[RED]}✗ Étape $step échouée: ${STEPS[$((step-1))]}${COLORS[NC]}"
        FAILED_STEPS+=("$step")
        
        if ! confirm_action "Continuer malgré l'échec?" "y"; then
            return 1
        fi
    fi
    
    save_state
    return 0
}

execute_all_steps() {
    log_message 1 "Exécution de toutes les étapes"
    
    for i in "${!STEPS[@]}"; do
        execute_step $((i+1)) || {
            echo -e "${COLORS[RED]}✗ Arrêt à l'étape $((i+1))${COLORS[NC]}"
            return 1
        }
    done
    
    echo -e "\n${COLORS[GREEN]}✓ Toutes les étapes terminées${COLORS[NC]}"
    display_summary
    return 0
}

check_script_version() {
    [[ "$VERSION_CHECKED" == "true" ]] && return 0
    
    VERSION_CHECKED=true
    log_message 1 "Vérification de version du script"
    
    echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}║   VÉRIFICATION DE VERSION             ║${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
    echo -e "${COLORS[GREEN]}Version actuelle: $SCRIPT_VERSION${COLORS[NC]}"
    
    if ! confirm_action "Vérifier les mises à jour en ligne?" "y"; then
        echo -e "${COLORS[YELLOW]}Vérification ignorée${COLORS[NC]}"
        return 0
    fi
    
    # Vérification de la connectivité
    if ! ping -c 1 -W 5 8.8.8.8 &> /dev/null; then
        echo -e "${COLORS[RED]}✗ Pas de connexion internet${COLORS[NC]}"
        return 1
    fi
    
    echo -e "${COLORS[BLUE]}Vérification en cours...${COLORS[NC]}"
    
    local latest_version
    latest_version=$(timeout 30 curl -s --connect-timeout 10 --max-time 30 "$UPDATE_URL" 2>/dev/null | head -1 | tr -d '[:space:]')
    
    if [[ -z "$latest_version" ]]; then
        echo -e "${COLORS[RED]}✗ Impossible de récupérer la version${COLORS[NC]}"
        return 1
    fi
    
    echo -e "${COLORS[GREEN]}Dernière version disponible: $latest_version${COLORS[NC]}"
    
    if [[ "$SCRIPT_VERSION" == "$latest_version" ]]; then
        echo -e "${COLORS[GREEN]}✓ Vous utilisez la dernière version${COLORS[NC]}"
        return 0
    fi
    
    # Vérifier si version plus récente disponible
    if [[ "$(printf '%s\n' "$SCRIPT_VERSION" "$latest_version" | sort -V | head -n1)" == "$SCRIPT_VERSION" ]]; then
        echo -e "\n${COLORS[YELLOW]}╔═══════════════════════════════════════╗${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}║   MISE À JOUR DISPONIBLE              ║${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}╚═══════════════════════════════════════╝${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}Version actuelle: $SCRIPT_VERSION${COLORS[NC]}"
        echo -e "${COLORS[GREEN]}Nouvelle version: $latest_version${COLORS[NC]}"
        
        if ! confirm_action "Télécharger et installer la mise à jour?" "y"; then
            echo -e "${COLORS[YELLOW]}Mise à jour ignorée${COLORS[NC]}"
            return 0
        fi
        
        echo -e "${COLORS[BLUE]}Téléchargement de la mise à jour...${COLORS[NC]}"
        local temp_script="/tmp/proxmox_gpu_update_$.sh"
        
        if ! timeout 60 curl -f -s --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$temp_script" 2>/dev/null; then
            echo -e "${COLORS[RED]}✗ Échec du téléchargement${COLORS[NC]}"
            rm -f "$temp_script" 2>/dev/null
            return 1
        fi
        
        # Vérifications du fichier téléchargé
        if [[ ! -s "$temp_script" ]]; then
            echo -e "${COLORS[RED]}✗ Fichier téléchargé vide${COLORS[NC]}"
            rm -f "$temp_script" 2>/dev/null
            return 1
        fi
        
        if ! head -1 "$temp_script" | grep -q "^#!/bin/bash"; then
            echo -e "${COLORS[RED]}✗ Fichier invalide (pas un script bash)${COLORS[NC]}"
            rm -f "$temp_script" 2>/dev/null
            return 1
        fi
        
        # Backup et installation
        local script_path="$0"
        cp "$script_path" "${script_path}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
        
        if mv "$temp_script" "$script_path" && chmod +x "$script_path"; then
            echo -e "${COLORS[GREEN]}✓ Mise à jour installée avec succès${COLORS[NC]}"
            echo -e "\n${COLORS[YELLOW]}Le script va redémarrer avec la nouvelle version...${COLORS[NC]}"
            sleep 3
            exec "$script_path"
        else
            echo -e "${COLORS[RED]}✗ Échec de l'installation${COLORS[NC]}"
            return 1
        fi
    else
        echo -e "${COLORS[YELLOW]}⚠ Votre version ($SCRIPT_VERSION) est plus récente que celle disponible ($latest_version)${COLORS[NC]}"
    fi
    
    return 0
}

# ======================
# MENU PRINCIPAL
# ======================

display_main_menu() {
    while true; do
        clear
        display_welcome_message
        
        echo -e "${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}║   MENU PRINCIPAL                      ║${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}\n"
        
        echo -e "${COLORS[YELLOW]}1.${COLORS[NC]} Exécuter toutes les étapes (configuration complète)"
        echo -e "${COLORS[YELLOW]}2.${COLORS[NC]} Exécuter des étapes spécifiques"
        echo -e "${COLORS[YELLOW]}3.${COLORS[NC]} Afficher les informations système"
        echo -e "${COLORS[YELLOW]}4.${COLORS[NC]} Diagnostic IOMMU complet"
        echo -e "${COLORS[YELLOW]}5.${COLORS[NC]} Configuration vGPU uniquement"
        echo -e "${COLORS[YELLOW]}6.${COLORS[NC]} Vérifier la configuration actuelle"
        echo -e "${COLORS[YELLOW]}7.${COLORS[NC]} Afficher le résumé des étapes"
        echo -e "${COLORS[YELLOW]}8.${COLORS[NC]} Afficher les logs"
        echo -e "${COLORS[YELLOW]}9.${COLORS[NC]} Options avancées"
        echo -e "${COLORS[YELLOW]}0.${COLORS[NC]} Quitter"
        
        if [[ "$REBOOT_NEEDED" == "true" ]]; then
            echo -e "\n${COLORS[YELLOW]}${COLORS[BOLD]}⚠ Un redémarrage est nécessaire${COLORS[NC]}"
        fi
        
        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            echo -e "${COLORS[YELLOW]}${COLORS[BOLD]}⚠ ${#WARNINGS[@]} avertissement(s)${COLORS[NC]}"
        fi
        
        echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}║   ÉTAPES DISPONIBLES                  ║${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
        
        for i in "${!STEPS[@]}"; do
            local step_num=$((i+1))
            local status_icon=""
            local status_color=""
            local executed=false
            local failed=false
            
            # Vérifier si exécutée
            for exec_step in "${EXECUTED_STEPS[@]}"; do
                if [[ "$exec_step" == "$step_num" ]]; then
                    executed=true
                    break
                fi
            done
            
            # Vérifier si échouée
            if [[ "$executed" == "true" ]]; then
                for fail_step in "${FAILED_STEPS[@]}"; do
                    if [[ "$fail_step" == "$step_num" ]]; then
                        failed=true
                        break
                    fi
                done
            fi
            
            # Définir l'icône et la couleur
            if [[ "$failed" == "true" ]]; then
                status_icon="✗"
                status_color="${COLORS[RED]}"
            elif [[ "$executed" == "true" ]]; then
                status_icon="✓"
                status_color="${COLORS[GREEN]}"
            else
                status_icon="○"
                status_color="${COLORS[GRAY]}"
            fi
            
            # Afficher avec echo -e pour interpréter les codes couleur
            echo -e "${status_color}${status_icon}${COLORS[NC]} ${COLORS[BLUE]}$(printf "%2d" $step_num).${COLORS[NC]} ${STEPS[$i]}"
        done
        echo ""
        
        echo ""
        local choice
        read -r -p "Choisissez une option (0-9): " choice
        
        case $choice in
            1)
                execute_all_steps
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            2)
                echo -e "\n${COLORS[YELLOW]}Entrez les numéros des étapes à exécuter (séparés par des espaces):${COLORS[NC]}"
                local -a steps_to_run
                read -r -a steps_to_run
                
                for step in "${steps_to_run[@]}"; do
                    if [[ "$step" =~ ^[0-9]+$ ]] && [[ "$step" -ge 1 ]] && [[ "$step" -le ${#STEPS[@]} ]]; then
                        execute_step "$step"
                    else
                        echo -e "${COLORS[RED]}✗ Étape invalide: $step${COLORS[NC]}"
                    fi
                done
                
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            3)
                display_system_info
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            4)
                diagnose_iommu
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            5)
                configure_vgpu
                ;;
            6)
                verify_vgpu_config
                ;;
            7)
                display_summary
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            8)
                echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}║   DERNIÈRES LIGNES DU LOG             ║${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
                tail -30 "$LOG_FILE" 2>/dev/null || echo -e "${COLORS[YELLOW]}⚠ Fichier log vide ou inexistant${COLORS[NC]}"
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            9)
                advanced_options_menu
                ;;
            0)
                if confirm_action "Voulez-vous vraiment quitter?" "y"; then
                    save_state
                    cleanup
                    echo -e "${COLORS[GREEN]}Au revoir!${COLORS[NC]}"
                    exit 0
                fi
                ;;
            *)
                echo -e "${COLORS[RED]}✗ Option invalide${COLORS[NC]}"
                sleep 2
                ;;
        esac
    done
}

advanced_options_menu() {
    while true; do
        clear
        echo -e "${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}║   OPTIONS AVANCÉES                    ║${COLORS[NC]}"
        echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}\n"
        
        echo -e "${COLORS[YELLOW]}1.${COLORS[NC]} Modifier le niveau de log (actuel: $LOG_LEVEL)"
        echo -e "${COLORS[YELLOW]}2.${COLORS[NC]} Nettoyer les fichiers temporaires"
        echo -e "${COLORS[YELLOW]}3.${COLORS[NC]} Réinitialiser l'état sauvegardé"
        echo -e "${COLORS[YELLOW]}4.${COLORS[NC]} Exporter les logs"
        echo -e "${COLORS[YELLOW]}5.${COLORS[NC]} Vérifier l'intégrité du système"
        echo -e "${COLORS[YELLOW]}6.${COLORS[NC]} Créer une sauvegarde manuelle"
        echo -e "${COLORS[YELLOW]}7.${COLORS[NC]} Restaurer une sauvegarde"
        echo -e "${COLORS[YELLOW]}8.${COLORS[NC]} Mode Dry-Run (actuel: $([[ "$DRY_RUN" == "true" ]] && echo "Activé" || echo "Désactivé"))"
        echo -e "${COLORS[YELLOW]}9.${COLORS[NC]} Afficher les avertissements (${#WARNINGS[@]})"
        echo -e "${COLORS[YELLOW]}0.${COLORS[NC]} Retour au menu principal"
        
        local adv_choice
        read -r -p "Choisissez une option (0-9): " adv_choice
        
        case $adv_choice in
            1)
                echo -e "\n${COLORS[YELLOW]}Niveaux disponibles:${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}0:${COLORS[NC]} DEBUG | ${COLORS[GREEN]}1:${COLORS[NC]} INFO | ${COLORS[YELLOW]}2:${COLORS[NC]} WARNING | ${COLORS[RED]}3:${COLORS[NC]} ERROR"
                read -r -p "Nouveau niveau (0-3): " new_level
                if [[ "$new_level" =~ ^[0-3]$ ]]; then
                    LOG_LEVEL=$new_level
                    echo -e "${COLORS[GREEN]}✓ Niveau de log modifié: $LOG_LEVEL${COLORS[NC]}"
                else
                    echo -e "${COLORS[RED]}✗ Niveau invalide${COLORS[NC]}"
                fi
                sleep 2
                ;;
            2)
                echo -e "\n${COLORS[BLUE]}Nettoyage des fichiers temporaires...${COLORS[NC]}"
                rm -f /tmp/proxmox_* 2>/dev/null || true
                echo -e "${COLORS[GREEN]}✓ Fichiers temporaires nettoyés${COLORS[NC]}"
                sleep 2
                ;;
            3)
                if confirm_action "Réinitialiser l'état sauvegardé?" "y"; then
                    rm -f "$STATE_FILE" "$STATE_FILE.bak" 2>/dev/null || true
                    USER_CHOICES=()
                    EXECUTED_STEPS=()
                    FAILED_STEPS=()
                    WARNINGS=()
                    echo -e "${COLORS[GREEN]}✓ État réinitialisé${COLORS[NC]}"
                fi
                sleep 2
                ;;
            4)
                local export_file="/tmp/proxmox_gpu_logs_$(date +%Y%m%d_%H%M%S).log"
                if [[ -f "$LOG_FILE" ]]; then
                    cp "$LOG_FILE" "$export_file"
                    echo -e "${COLORS[GREEN]}✓ Logs exportés vers: $export_file${COLORS[NC]}"
                else
                    echo -e "${COLORS[RED]}✗ Aucun log à exporter${COLORS[NC]}"
                fi
                sleep 2
                ;;
            5)
                echo -e "\n${COLORS[BLUE]}Vérification de l'intégrité...${COLORS[NC]}"
                check_permissions && check_disk_space && check_network_connectivity
                echo -e "${COLORS[GREEN]}✓ Vérification terminée${COLORS[NC]}"
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            6)
                if confirm_action "Créer une sauvegarde de configuration?" "y"; then
                    create_backup
                    echo -e "${COLORS[GREEN]}✓ Sauvegarde créée: $CONFIG_BACKUP${COLORS[NC]}"
                fi
                sleep 2
                ;;
            7)
                restore_backup
                ;;
            8)
                if [[ "$DRY_RUN" == "true" ]]; then
                    DRY_RUN=false
                    echo -e "${COLORS[GREEN]}✓ Mode Dry-Run désactivé${COLORS[NC]}"
                else
                    DRY_RUN=true
                    echo -e "${COLORS[YELLOW]}✓ Mode Dry-Run activé - Aucune modification ne sera appliquée${COLORS[NC]}"
                fi
                sleep 2
                ;;
            9)
                echo -e "\n${COLORS[BLUE]}╔═══════════════════════════════════════╗${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}║   AVERTISSEMENTS                      ║${COLORS[NC]}"
                echo -e "${COLORS[BLUE]}╚═══════════════════════════════════════╝${COLORS[NC]}"
                
                if [[ ${#WARNINGS[@]} -eq 0 ]]; then
                    echo -e "${COLORS[GREEN]}✓ Aucun avertissement${COLORS[NC]}"
                else
                    for i in "${!WARNINGS[@]}"; do
                        echo -e "${COLORS[YELLOW]}$((i+1)).${COLORS[NC]} ${WARNINGS[$i]}"
                    done
                fi
                
                read -r -p "Appuyez sur Entrée pour continuer..."
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${COLORS[RED]}✗ Option invalide${COLORS[NC]}"
                sleep 2
                ;;
        esac
    done
}

# ======================
# FONCTION PRINCIPALE
# ======================

main() {
    # Gestion des interruptions
    trap 'cleanup; echo -e "\n${COLORS[YELLOW]}Script interrompu${COLORS[NC]}"; exit 130' SIGINT SIGTERM
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                echo -e "${COLORS[YELLOW]}Mode Dry-Run activé${COLORS[NC]}"
                shift
                ;;
            --skip-confirmations)
                SKIP_CONFIRMATIONS=true
                echo -e "${COLORS[YELLOW]}Mode auto activé${COLORS[NC]}"
                shift
                ;;
            --log-level)
                if [[ -n "$2" ]] && [[ "$2" =~ ^[0-3]$ ]]; then
                    LOG_LEVEL=$2
                    shift 2
                else
                    echo -e "${COLORS[RED]}✗ Niveau de log invalide${COLORS[NC]}"
                    exit 1
                fi
                ;;
            --help|-h)
                echo -e "${COLORS[GREEN]}Usage: $0 [OPTIONS]${COLORS[NC]}"
                echo -e "\nOptions:"
                echo -e "  --dry-run              Mode simulation (aucune modification)"
                echo -e "  --skip-confirmations   Ignorer toutes les confirmations"
                echo -e "  --log-level LEVEL      Définir le niveau de log (0-3)"
                echo -e "  --help, -h             Afficher cette aide"
                exit 0
                ;;
            *)
                echo -e "${COLORS[RED]}✗ Option inconnue: $1${COLORS[NC]}"
                echo -e "Utilisez --help pour voir les options disponibles"
                exit 1
                ;;
        esac
    done
    
    # Acquisition du verrou
    if ! acquire_lock; then
        echo -e "${COLORS[RED]}✗ Une autre instance est déjà en cours d'exécution${COLORS[NC]}"
        exit 1
    fi
    
    # Initialisation du log
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "=== Nouveau démarrage du script le $(date) ===" >> "$LOG_FILE" 2>/dev/null || true
    log_message 1 "Script démarré (version $SCRIPT_VERSION)"
    
    # Vérification root obligatoire
    check_permissions
    
    # Vérification de jq
    if ! command -v jq &> /dev/null; then
        echo -e "${COLORS[YELLOW]}⚠ jq n'est pas installé${COLORS[NC]}"
        if confirm_action "Installer jq maintenant?" "y"; then
            apt-get update -qq && apt-get install -y jq || {
                echo -e "${COLORS[RED]}✗ Impossible d'installer jq${COLORS[NC]}"
                echo -e "${COLORS[YELLOW]}⚠ Certaines fonctionnalités seront limitées${COLORS[NC]}"
            }
        else
            echo -e "${COLORS[YELLOW]}⚠ Certaines fonctionnalités seront limitées sans jq${COLORS[NC]}"
        fi
    fi
    
    # Affichage du message de bienvenue
    display_welcome_message
    echo -e "${COLORS[YELLOW]}Appuyez sur Entrée pour continuer...${COLORS[NC]}"
    read -r
    
    # Vérification de version du script au démarrage
    check_script_version
    
    # Chargement de l'état si disponible
    load_state 2>/dev/null || true
    
    # Affichage du menu principal
    display_main_menu
}

# ======================
# POINT D'ENTRÉE
# ======================

main "$@"
