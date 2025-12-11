#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
K8S_VERSION="1.28.0"
POD_NETWORK_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CONTAINER_RUNTIME="containerd"
MASTER_NODE=true
JOIN_CLUSTER=false
TOKEN=""
DISCOVERY_TOKEN_HASH=""
MASTER_IP=""
NETWORK_PLUGIN="flannel" # flannel, calico, or weave

print_step() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!] ERROR:${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!] WARNING:${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен запускаться с правами root"
        exit 1
    fi
}

update_system() {
    print_step "Обновление системы..."
    apt update && apt upgrade -y
    apt install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates
}

disable_swap() {
    print_step "Отключение swap..."
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
}

setup_network() {
    print_step "Настройка сети..."
    
    # Load kernel modules
    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    
    modprobe overlay
    modprobe br_netfilter
    
    # Sysctl params
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    
    sysctl --system
}

install_containerd() {
    print_step "Установка Containerd..."
    
    # Install containerd
    apt install -y containerd
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    
    # Enable SystemdCgroup
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Restart containerd
    systemctl restart containerd
    systemctl enable containerd
}

install_docker() {
    print_step "Установка Docker..."
    
    # Install Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    
    # Configure Docker daemon
    cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
    
    systemctl daemon-reload
    systemctl restart docker
    systemctl enable docker
}

install_kubernetes_tools() {
    print_step "Установка Kubernetes инструментов..."
    
    # 1. Удаляем старый ключ и репозиторий, если они есть (чтобы избежать конфликтов)
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list
    sudo rm -f /usr/share/keyrings/kubernetes-archive-keyring.gpg 2>/dev/null

    # 2. Скачиваем новый ключ и настраиваем репозиторий по НОВОЙ официальной схеме
    # Устанавливаем необходимые зависимости
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg

    # Скачиваем ключ и помещаем его в trusted keyring
    # ВАЖНО: v${K8S_VERSION%.*} превратит "1.28.0" в "v1.28"
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    # Добавляем новый репозиторий.
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

    # 3. Устанавливаем пакеты
    sudo apt-get update
    sudo apt-get install -y kubelet=${K8S_VERSION}-00 kubeadm=${K8S_VERSION}-00 kubectl=${K8S_VERSION}-00
    sudo apt-mark hold kubelet kubeadm kubectl
}

init_master_node() {
    print_step "Инициализация Master узла..."
    
    # Initialize cluster
    kubeadm init \
        --pod-network-cidr=${POD_NETWORK_CIDR} \
        --service-cidr=${SERVICE_CIDR} \
        --upload-certs \
        --control-plane-endpoint=$(hostname -I | awk '{print $1}')
    
    # Copy kubeconfig
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    
    # Copy kubeconfig for root
    export KUBECONFIG=/etc/kubernetes/admin.conf
    
    # Print join command
    print_step "Команда для присоединения worker узлов:"
    kubeadm token create --print-join-command
}

install_network_plugin() {
    print_step "Установка сетевого плагина (${NETWORK_PLUGIN})..."
    
    case $NETWORK_PLUGIN in
        "flannel")
            kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
            ;;
        "calico")
            kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
            ;;
        "weave")
            kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
            ;;
        *)
            print_warning "Неизвестный сетевой плагин, используется Flannel"
            kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
            ;;
    esac
    
    # Wait for pods to be ready
    sleep 10
}

join_worker_node() {
    print_step "Присоединение к кластеру как Worker узел..."
    
    if [ -z "$TOKEN" ] || [ -z "$DISCOVERY_TOKEN_HASH" ] || [ -z "$MASTER_IP" ]; then
        print_error "Не указаны параметры для присоединения (TOKEN, DISCOVERY_TOKEN_HASH, MASTER_IP)"
        exit 1
    fi
    
    kubeadm join ${MASTER_IP}:6443 \
        --token ${TOKEN} \
        --discovery-token-ca-cert-hash ${DISCOVERY_TOKEN_HASH}
}

install_metrics_server() {
    print_step "Установка Metrics Server..."
    
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    # Patch metrics server for insecure TLS
    kubectl patch deployment metrics-server -n kube-system \
        --type=json -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
}

setup_bash_completion() {
    print_step "Настройка автодополнения bash..."
    
    # For current user
    echo 'source <(kubectl completion bash)' >> ~/.bashrc
    echo 'alias k=kubectl' >> ~/.bashrc
    echo 'complete -F __start_kubectl k' >> ~/.bashrc
    
    # For root if different
    if [ "$(whoami)" != "root" ]; then
        echo 'source <(kubectl completion bash)' | sudo tee -a /root/.bashrc
        echo 'alias k=kubectl' | sudo tee -a /root/.bashrc
        echo 'complete -F __start_kubectl k' | sudo tee -a /root/.bashrc
    fi
    
    source ~/.bashrc
}

verify_installation() {
    print_step "Проверка установки..."
    
    echo -e "\n${GREEN}=== ТЕКУЩАЯ КОНФИГУРАЦИЯ ===${NC}"
    echo "Kubernetes Version: ${K8S_VERSION}"
    echo "Container Runtime: ${CONTAINER_RUNTIME}"
    echo "Network Plugin: ${NETWORK_PLUGIN}"
    echo "Node Type: $(if $MASTER_NODE; then echo "Master"; else echo "Worker"; fi)"
    
    echo -e "\n${GREEN}=== ПРОВЕРКА СЕРВИСОВ ===${NC}"
    systemctl status kubelet --no-pager | grep -A 3 "Active:" || echo "Сервис kubelet не найден"
    
    if $MASTER_NODE; then
        echo -e "\n${GREEN}=== ПРОВЕРКА КЛАСТЕРА ===${NC}"
        kubectl cluster-info 2>/dev/null || echo "kubectl не может подключиться к кластеру"
        echo -e "\n${GREEN}=== СОСТОЯНИЕ УЗЛОВ ===${NC}"
        kubectl get nodes 2>/dev/null || echo "Не удалось получить список узлов"
        echo -e "\n${GREEN}=== СОСТОЯНИЕ PODS В СИСТЕМНЫХ NAMESPACE ===${NC}"
        kubectl get pods -n kube-system 2>/dev/null || echo "Не удалось получить список pods"
    fi
}

cleanup() {
    print_step "Очистка в случае ошибки..."
    
    if $MASTER_NODE; then
        kubeadm reset -f 2>/dev/null || true
    fi
    
    apt remove -y kubelet kubeadm kubectl 2>/dev/null || true
    apt autoremove -y
    
    rm -rf /etc/kubernetes
    rm -rf ~/.kube
    rm -rf /var/lib/etcd
}

show_help() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Опции:"
    echo "  --master              Установка как Master узел (по умолчанию)"
    echo "  --worker              Установка как Worker узел"
    echo "  --token=TOKEN         Токен для присоединения (для worker)"
    echo "  --hash=HASH           Hash токена для присоединения (для worker)"
    echo "  --master-ip=IP        IP адрес Master узла (для worker)"
    echo "  --runtime=docker      Использовать Docker вместо Containerd"
    echo "  --network=PLUGIN      Сетевой плагин (flannel, calico, weave)"
    echo "  --version=VERSION     Версия Kubernetes (по умолчанию: 1.28.0)"
    echo "  --help                Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  $0 --master --network=calico"
    echo "  $0 --worker --token=abc123 --hash=sha256:xyz --master-ip=192.168.1.100"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --master)
            MASTER_NODE=true
            JOIN_CLUSTER=false
            shift
            ;;
        --worker)
            MASTER_NODE=false
            JOIN_CLUSTER=true
            shift
            ;;
        --token=*)
            TOKEN="${1#*=}"
            shift
            ;;
        --hash=*)
            DISCOVERY_TOKEN_HASH="${1#*=}"
            shift
            ;;
        --master-ip=*)
            MASTER_IP="${1#*=}"
            shift
            ;;
        --runtime=*)
            CONTAINER_RUNTIME="${1#*=}"
            shift
            ;;
        --network=*)
            NETWORK_PLUGIN="${1#*=}"
            shift
            ;;
        --version=*)
            K8S_VERSION="${1#*=}"
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            print_error "Неизвестный параметр: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_step "Начало установки Kubernetes ${K8S_VERSION} на Ubuntu"
    
    check_root
    update_system
    disable_swap
    setup_network
    
    # Install container runtime
    if [ "$CONTAINER_RUNTIME" = "docker" ]; then
        install_docker
    else
        install_containerd
    fi
    
    install_kubernetes_tools
    
    if $MASTER_NODE && ! $JOIN_CLUSTER; then
        init_master_node
        install_network_plugin
        install_metrics_server
        setup_bash_completion
    elif $JOIN_CLUSTER; then
        join_worker_node
    fi
    
    verify_installation
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    if $MASTER_NODE && ! $JOIN_CLUSTER; then
        echo -e "\nЧтобы использовать kubectl как обычный пользователь:"
        echo "mkdir -p \$HOME/.kube"
        echo "sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
        echo "sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
        
        echo -e "\nЧтобы присоединить Worker узлы, выполните на них:"
        kubeadm token create --print-join-command 2>/dev/null || echo "Перезапустите скрипт для получения команды join"
    fi
}

# Trap for cleanup on error
trap cleanup ERR

# Run main function
main
