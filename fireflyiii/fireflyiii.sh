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

# Confirmar puerto para Firefly III
read -p "El puerto por defecto para Firefly III es 8200. ¿Desea cambiarlo? [y/N]: " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  read -p "Introduzca el nuevo puerto para Firefly III: " NEW_PORT
else
  NEW_PORT=8200
fi

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

if [ $? -ne 0 ]; then
  echo -e "${RED}Error al crear el contenedor. La imagen de Ubuntu no se encuentra disponible.${NC}"
  read -p "¿Desea descargar la imagen de Ubuntu automáticamente? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    echo "Descargando la imagen de Ubuntu..."
    pveam download local ubuntu-23.04-standard_23.04-1_amd64.tar.zst
    if [ $? -ne 0 ]; then
      echo -e "${RED}Error al descargar la imagen de Ubuntu. Verifique la conexión a Internet y los repositorios.${NC}"
      exit 1
    else
      echo -e "${GREEN}Imagen de Ubuntu descargada con éxito.${NC}"
      # Intentar crear el contenedor de nuevo
      pct create $VMID local:vztmpl/ubuntu-23.04-standard_23.04-1_amd64.tar.zst \
        --hostname firefly-iii \
        --password $PASSWORD \
        --unprivileged 1 \
        --net0 name=eth0,bridge=vmbr0,ip=$STATIC_IP \
        --cores $CPU \
        --memory $RAM \
        --storage local-lvm
      if [ $? -ne 0 ]; then
        echo -e "${RED}Error al crear el contenedor incluso después de descargar la imagen de Ubuntu. Abortando.${NC}"
        exit 1
      fi
    fi
  else
    echo -e "${RED}Abortando la instalación. Por favor, descargue la imagen de Ubuntu manualmente y vuelva a intentarlo.${NC}"
    exit 1
  fi
fi

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
if pct exec $VMID -- bash -c "sed -i 's/firefly_password/$DB_PASSWORD/g' $DOCKER_COMPOSE_DIR/docker-compose.yml"; then
  echo -e "${GREEN}Contraseña actualizada con éxito en docker-compose.yml.${NC}"
else
  echo -e "${RED}Error al actualizar la contraseña en docker-compose.yml. Abortando.${NC}"
  exit 1
fi

if pct exec $VMID -- bash -c "sed -i 's/firefly_password/\"$DB_PASSWORD\"/g' $DOCKER_COMPOSE_DIR/.env"; then
  echo -e "${GREEN}Contraseña actualizada con éxito en .env.${NC}"
else
  echo -e "${RED}Error al actualizar la contraseña en .env. Abortando.${NC}"
  exit 1
fi

# Modificar el puerto en el archivo docker-compose.yml descargado
if pct exec $VMID -- bash -c "sed -i 's/8200:8080/$NEW_PORT:8080/g' $DOCKER_COMPOSE_DIR/docker-compose.yml"; then
  echo -e "${GREEN}Puerto actualizado con éxito en docker-compose.yml.${NC}"
else
  echo -e "${RED}Error al actualizar el puerto. Abortando.${NC}"
  exit 1
fi

# Iniciar Firefly III
pct exec $VMID -- bash -c "cd $DOCKER_COMPOSE_DIR && docker-compose up -d"

# Añadir tag al contenedor
pct set $VMID -tags "administracion"

# Construir el resumen de la instalación
RESUMEN="Resumen de la instalación: "
RESUMEN+="Firefly III, "
RESUMEN+="ID del contenedor: $VMID, "
RESUMEN+="OS: Ubuntu 23.04, "
RESUMEN+="CPU: $CPU, "
RESUMEN+="RAM: ${RAM}MB, "
RESUMEN+="STORAGE: 4GB, "
RESUMEN+="Network: $STATIC_IP, "
RESUMEN+="Puerto: $NEW_PORT, "
RESUMEN+="by wizapol"

# Añadir la descripción al contenedor
pct set $VMID -description "$RESUMEN"

echo "-------------------------------------"
echo "Resumen de la instalación:"
echo "ID del contenedor: $VMID"
echo "OS: Ubuntu 23.04"
echo "Contraseña CT: $PASSWORD"
echo "CPU: $CPU"
echo "RAM: ${RAM}MB"
echo "STORAGE: 4GB"
echo "Network: $STATIC_IP"
echo "Puerto: $NEW_PORT"
echo "Usuario DB: firefly"
echo "Contraseña DB: $DB_PASSWORD"
echo "-------------------------------------"

# Preguntar al usuario si el contenedor debe iniciar automáticamente
read -p "¿Desea que el contenedor inicie automáticamente? [y/N]: " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  echo "Configurando el contenedor para que inicie automáticamente..."
  pct set $VMID -onboot 1
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Configuración de inicio automático actualizada con éxito.${NC}"
  else
    echo -e "${RED}No se pudo actualizar la configuración de inicio automático.${NC}"
  fi
else
  echo "El contenedor no se configurará para iniciar automáticamente."
fi
