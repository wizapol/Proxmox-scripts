#!/usr/bin/env bash

# Colores para la salida
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Función para mostrar el encabezado
function header_info {
  clear
  echo -e "${GREEN}"
  echo "---------------------------------------------------"
  echo "  Instalador de Nginx Proxy Manager en Proxmox"
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
if [ $? -ne 0 ]; then
  echo -e "${RED}Error al obtener el próximo ID valido de VM/CT. Abortando.${NC}"
  exit 1
fi

echo -e "${GREEN}El próximo ID de VM/CT disponible es: $NEXTID${NC}"

# Preguntar al usuario para confirmar
while true; do
  read -p "¿Desea continuar con este ID? [y/N]: " yn
  case $yn in
    [Yy]* ) 
      VMID=$NEXTID
      break
      ;;
    * ) 
      read -p "Introduzca un ID valido de VM/CT: " VMID
      # Verificar si el ID ya está en uso
      if pct list | awk '{print $1}' | grep -q "^${VMID}$"; then
        echo -e "${RED}Este ID ya está en uso. Por favor, elija otro.${NC}"
      else
        break
      fi
      ;;
  esac
done

# Inicialización de variables
PASSWORD=""
PASSWORD_CONFIRM=""

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

# Crear el contenedor en local-lvm
echo -e "${GREEN}Creando el contenedor en local-lvm...${NC}"
pct create $VMID local:vztmpl/alpine-3.18-default_20230607_amd64.tar.xz \
  --hostname nginx-proxy-manager \
  --password $PASSWORD \
  --unprivileged 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --cores 1 \
  --memory 1024 \
  --storage local-lvm

if [ $? -ne 0 ]; then
  echo -e "${RED}Error al crear el contenedor. La imagen de Alpine no se encuentra disponible.${NC}"
  read -p "¿Desea descargar la imagen de Alpine automáticamente? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    echo "Descargando la imagen de Alpine..."
    pveam download local alpine-3.18-default_20230607_amd64.tar.xz
    if [ $? -ne 0 ]; then
      echo -e "${RED}Error al descargar la imagen de Alpine. Verifique la conexión a Internet y los repositorios.${NC}"
      exit 1
    else
      echo -e "${GREEN}Imagen de Alpine descargada con éxito.${NC}"
      
      # Intentar crear el contenedor de nuevo
      echo -e "${GREEN}Creando contenedor...${NC}"
      pct create $VMID local:vztmpl/alpine-3.18-default_20230607_amd64.tar.xz \
        --hostname nginx-proxy-manager \
        --password $PASSWORD \
        --unprivileged 1 \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --cores 1 \
        --memory 1024 \
        --rootfs local-lvm:1 \
        --storage local-lvm
      if [ $? -ne 0 ]; then
        echo -e "${RED}Error al crear el contenedor incluso después de descargar la imagen de Alpine. Abortando.${NC}"
        exit 1
      fi
    fi
  else
    echo -e "${RED}Abortando la instalación. Por favor, descargue la imagen de Alpine manualmente y vuelva a intentarlo.${NC}"
    exit 1
  fi
fi

# Iniciar el contenedor
echo -e "${GREEN}Iniciando el contenedor...${NC}"
pct start $VMID

if [ $? -ne 0 ]; then
  echo -e "${RED}Error al iniciar el contenedor. Abortando.${NC}"
  exit 1
fi

# Esperar a que el contenedor se inicie completamente
sleep 10
${GREEN} ${NC}
# Instalar Bash en el contenedor
echo -e "${GREEN}Instalando Bash en el contenedor...${NC}"
pct exec $VMID -- apk add bash

if [ $? -ne 0 ]; then
  echo -e "${RED}Error al instalar Bash. Abortando.${NC}"
  exit 1
fi

# Instalar Docker
echo -e "${GREEN}Instalando Docker...${NC}"
pct exec $VMID -- bash -c "apk add docker"
if [ $? -ne 0 ]; then
  echo -e "${RED}Error al instalar Docker. Abortando.${NC}"
  exit 1
fi

# Instalar Docker Compose
echo -e "${GREEN}Instalando Docker-Compose...${NC}"
pct exec $VMID -- bash -c "apk add docker-compose"

if [ $? -ne 0 ]; then
  echo -e "${RED}Error al instalar Docker Compose. Abortando.${NC}"
  exit 1
fi

# Crear el archivo docker-compose.yml para Nginx Proxy Manager
echo -e "${GREEN}Creando el archivo docker-compose.yml para Nginx Proxy Manager...${NC}"
DOCKER_COMPOSE_DIR="/root/nginx-proxy-manager"
pct exec $VMID -- bash -c "mkdir -p $DOCKER_COMPOSE_DIR && echo \"version: '3.8'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '8581:81'
      - '443:443'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt\" > $DOCKER_COMPOSE_DIR/docker-compose.yml"

if [ $? -ne 0 ]; then
  echo -e "${RED}Error al crear el archivo docker-compose.yml. Abortando.${NC}"
  exit 1
fi

# Iniciar Nginx Proxy Manager
echo -e "${GREEN}Iniciando Nginx...${NC}"
pct exec $VMID -- bash -c "cd $DOCKER_COMPOSE_DIR && docker-compose up -d"

if [ $? -ne 0 ]; then
  echo -e "${RED}Error al iniciar Nginx Proxy Manager. Abortando.${NC}"
  exit 1
fi

# Añadir tag al contenedor
pct set $VMID -tags "proxy"

# Construir el resumen de la instalación
RESUMEN="Nginx Proxy Manager"

# Añadir la descripción al contenedor
pct set $VMID -description "$RESUMEN"

echo "-------------------------------------"
echo "Resumen de la instalación:"
echo "ID del contenedor: $VMID"
echo "OS: Alpine 3.18"
echo "Contraseña CT: $PASSWORD"
echo "CPU: 1"
echo "RAM: 1GB"
echo "STORAGE: 1GB"
echo "Network: DHCP"
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
