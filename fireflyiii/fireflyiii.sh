#!/usr/bin/env bash

# Colores para la salida
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Función para mostrar el encabezado
function header_info {
  clear
  echo -e "${GREEN}"
  echo " _____ _          _____ _         ___ ___ ___  "
  echo "|  ___(_)_ __ ___|  ___| |_   _  |_ _|_ _|_ _| "
  echo "| |_  | | '__/ _ \\ |_  | | | | |  | | | | | |  "
  echo "|  _| | | | |  __/  _| | | |_| |  | | | | | |  "
  echo "|_|   |_|_|  \\___|_|   |_|\\__, | |___|___|___| "
  echo "                          |___/                "
  echo "---------------------------------------------------"
  echo "  Instalador de Firefly III en Proxmox by wizapol"
  echo "---------------------------------------------------"
  echo -e "${NC}"
}

header_info

# Comprobar si el usuario es root
if [[ $EUID -ne 0 ]]; then
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

# Inicialización de variables
PASSWORD=""
PASSWORD_CONFIRM=""
DB_PASSWORD=""
DB_PASSWORD_CONFIRM=""

# Confirmar contraseña para el contenedor
while true; do
  read -s -p "Introduzca la contraseña para el contenedor: " PASSWORD
  echo ""
  read -s -p "Confirme la contraseña: " PASSWORD_CONFIRM
  echo ""
  if [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
    break
  else
    echo -e "${RED}Las contraseñas no coinciden. Inténtelo de nuevo.${NC}"
  fi
done

# Confirmar contraseña para la base de datos
while true; do
  read -s -p "Introduzca la contraseña para la base de datos: " DB_PASSWORD
  echo ""
  read -s -p "Confirme la contraseña para la base de datos: " DB_PASSWORD_CONFIRM
  echo ""
  if [ "$DB_PASSWORD" == "$DB_PASSWORD_CONFIRM" ]; then
    break
  else
    echo -e "${RED}Las contraseñas de la base de datos no coinciden. Inténtelo de nuevo.${NC}"
  fi
done

# Configuración de recursos de VM
read -p "¿Desea usar la configuración de recursos por defecto (1 CPU, 512MB RAM)? [y/N]: " yn
case $yn in
  [Yy]* ) CPU=1; RAM=512;;
  * ) read -p "Introduzca el número de CPUs: " CPU; read -p "Introduzca la cantidad de RAM en MB: " RAM;;
esac

# Validación de IP estática
while true; do
  read -p "¿Desea configurar una IP estática? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -p "Introduzca la IP estática (ejemplo: 192.168.1.2): " IP
    read -p "Introduzca la máscara de red (ejemplo: 24): " NETMASK
    read -p "Introduzca la puerta de enlace (ejemplo: 192.168.1.1): " GATEWAY
    STATIC_IP="${IP}/${NETMASK},gw=${GATEWAY}"
    if [[ "$STATIC_IP" =~ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+,gw=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
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
pct create $VMID local:vztmpl/ubuntu-23.04-standard_23.04-1_amd64.tar.zst \
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
pct exec $VMID -- bash -c "apt update && apt install -y docker.io docker-compose git"

# Descargar el archivo docker-compose.yml de Firefly III
echo "Descargando el archivo docker-compose.yml de Firefly III..."
DOCKER_COMPOSE_DIR="/root/firefly"
pct exec $VMID -- bash -c "mkdir -p $DOCKER_COMPOSE_DIR && cd $DOCKER_COMPOSE_DIR && wget https://raw.githubusercontent.com/wizapol/Proxmox-scripts/main/fireflyiii/env/docker-compose.yml"

# Descargar el archivo .env de Firefly III
echo "Descargando el archivo .env de Firefly III..."
pct exec $VMID -- bash -c "cd $DOCKER_COMPOSE_DIR && wget https://raw.githubusercontent.com/wizapol/Proxmox-scripts/main/fireflyiii/env/.env"

# Modificar la contraseña de la base de datos en los archivos descargados
pct exec $VMID -- bash -c "sed -i 's/firefly_password/$DB_PASSWORD/g' $DOCKER_COMPOSE_DIR/docker-compose.yml"
pct exec $VMID -- bash -c "sed -i 's/firefly_password/$DB_PASSWORD/g' $DOCKER_COMPOSE_DIR/.env"
echo "inyectando nuevo password en los archivos descargados..."

# Iniciar Firefly III
pct exec $VMID -- bash -c "cd $DOCKER_COMPOSE_DIR && docker-compose up -d"

# Verificar que la contraseña de la base de datos se ha cambiado correctamente
sleep 10  # Esperar a que el contenedor de la base de datos se inicie
DB_VERIFICATION=$(pct exec $VMID -- bash -c "docker exec db mysql -ufirefly -p$DB_PASSWORD -e 'SHOW DATABASES;' 2>&1")
if [[ "$DB_VERIFICATION" == *"Access denied"* ]]; then
  echo -e "${RED}La verificación de la contraseña de la base de datos ha fallado.${NC}"
else
  echo -e "${GREEN}La verificación de la contraseña de la base de datos ha sido exitosa, la instalacion se ah completado correctamente${NC}"
fi

echo "-------------------------------------"
echo "Resumen de la instalación:"
echo "ID del contenedor: $VMID"
echo "CPU: $CPU"
echo "RAM: ${RAM}MB"
echo "IP estática: $STATIC_IP"
echo "Puerto de Firefly III: 8200"
echo "Usuario de la base de datos: firefly"
echo "Contraseña de la base de datos: $DB_PASSWORD"
echo "-------------------------------------"
