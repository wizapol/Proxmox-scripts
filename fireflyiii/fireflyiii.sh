#!/bin/sh

# Colores para la salida
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Función para mostrar el encabezado
header_info() {
  clear
  echo -e "${GREEN}"
  echo " _____ _          _____ _         ___ ___ ___  "
  echo "|  ___(_)_ __ ___|  ___| |_   _  |_ _|_ _|_ _| "
  echo "| |_  | | '__/ _ \\ |_  | | | | |  | | | | | |  "
  echo "|  _| | | | |  __/  _| | | |_| |  | | | | | |  "
  echo "|_|   |_|_|  \\___|_|   |_|\\__, | |___|___|___| "
  echo "                          |___/                "
  echo "-------------------------------------"
  echo "  Instalador de Firefly III en Proxmox by wizapol"
  echo "-------------------------------------"
  echo -e "${NC}"
}

header_info

# Comprobar si el usuario es root
if [ "$(id -u)" -ne 0 ]; then
  echo "Este script debe ser ejecutado como root"
  exit 1
fi

# Obtener el próximo ID de VM/CT
NEXTID=$(pvesh get /cluster/nextid)
echo -e "${GREEN}El próximo ID de VM/CT disponible es: $NEXTID${NC}"

# Preguntar al usuario para confirmar
read -p "¿Desea continuar con este ID? [y/N]: " yn
case $yn in
  [Yy]* ) VMID=$NEXTID;;
  * ) read -p "Introduzca un ID de VM/CT: " VMID;;
esac

# Confirmar contraseña con validación
while true; do
  read -s -p "Introduzca la contraseña para el contenedor: " PASSWORD
  echo ""
  read -s -p "Confirme la contraseña: " PASSWORD_CONFIRM
  echo ""
  if [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
    break
  else
    echo -e "${RED}Las contraseñas no coinciden. Inténtelo de nuevo.${NC}"
  fi
done

# Configuración de recursos de VM
read -p "¿Desea usar la configuración de recursos por defecto (1 CPU, 1GB RAM)? [y/N]: " yn
case $yn in
  [Yy]* ) CPU=1; RAM=1024;;
  * ) read -p "Introduzca el número de CPUs: " CPU; read -p "Introduzca la cantidad de RAM en MB: " RAM;;
esac

# Configuración de IP estática con validación
while true; do
  read -p "¿Desea configurar una IP estática? [y/N]: " yn
  if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
    read -p "Introduzca la IP estática (ejemplo: 192.168.1.2): " IP
    read -p "Introduzca la máscara de red (ejemplo: 24): " NETMASK
    read -p "Introduzca la puerta de enlace (ejemplo: 192.168.1.1): " GATEWAY
    STATIC_IP="${IP}/${NETMASK},gw=${GATEWAY}"
    if echo "$STATIC_IP" | grep -E -q '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+,gw=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
      break
    else
      echo -e "${RED}Formato de IP estática incorrecto. Siga el formato indicado en los ejemplos.${NC}"
    fi
  else
    STATIC_IP="dhcp"
    break
  fi
done

# Crear el contenedor en local-lvm
echo "Creando el contenedor en local-lvm..."
pct create $VMID local:vztmpl/alpine-3.18-default_20230607_amd64.tar.xz \
  --hostname firefly-iii \
  --password $PASSWORD \
  --unprivileged 1 \
  --net0 name=eth0,bridge=vmbr0,ip=$STATIC_IP \
  --cores $CPU \
  --memory $RAM \
  --storage local-lvm

# Habilitar el anidamiento para Docker
pct set $VMID -features nesting=1

# Iniciar el contenedor
echo "Iniciando el contenedor..."
pct start $VMID

# Esperar a que el contenedor se inicie completamente
sleep 10

# Instalar Docker y Docker Compose
pct exec $VMID -- sh -c "apk update && apk add docker docker-compose git"

# Clonar el repositorio de Firefly III para obtener los archivos .env
DOCKER_COMPOSE_DIR="/root/firefly"
pct exec $VMID -- sh -c "git clone https://github.com/jmlcas/fireflyIII $DOCKER_COMPOSE_DIR"

# Descargar el archivo docker-compose.yml de Firefly III (solo si no existe)
if [ ! -f "$DOCKER_COMPOSE_DIR/docker-compose.yml" ]; then
  echo "Descargando el archivo docker-compose.yml de Firefly III..."
  pct exec $VMID -- sh -c "cd $DOCKER_COMPOSE_DIR && wget https://raw.githubusercontent.com/firefly-iii/docker/master/docker-compose.yml"
fi

# Iniciar Firefly III
pct exec $VMID -- sh -c "cd $DOCKER_COMPOSE_DIR && docker-compose up -d"

echo "-------------------------------------"
echo "Resumen de la instalación:"
echo "ID del contenedor: $VMID"
echo "CPU: $CPU"
echo "RAM: ${RAM}MB"
echo "IP estática: $STATIC_IP"
echo "Puerto de Firefly III: 8200"
echo "-------------------------------------"
