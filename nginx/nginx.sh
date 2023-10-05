#!/usr/bin/env bash

INSTALL_SUCCESS=false

# Colores para la salida
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Función para mostrar el encabezado
function header_info {
  clear
  echo -e "${GREEN}"
  echo "---------------------------------------------------"
  echo "  Instalador de Ubuntu 23.04 en Proxmox by wizapol"
  echo "---------------------------------------------------"
  echo -e "${NC}"
}

# Función de limpieza
function cleanup {
  if [ "$INSTALL_SUCCESS" != "true" ]; then
    if [ -n "$VMID" ]; then
      echo -e "${RED}Ocurrió un error. Eliminando la VM con ID $VMID...${NC}"
      pct stop $VMID  # Detener el contenedor antes de destruirlo
      pct destroy $VMID
    fi
  fi
}    

# Registrar la función de limpieza para ejecutarse al salir del script
trap cleanup EXIT

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

# Confirmar HOSTNAME para el contenedor
while true; do
  read -p "Introduzca el nombre del HOSTNAME para el contenedor: " HOSTNAME
  if [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    break
  else
    echo -e "${RED}El nombre del HOSTNAME no es válido. Debe comenzar con una letra o número y puede contener letras, números y guiones.${NC}"
  fi
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

# Configuración de recursos de VM
read -p "¿Desea usar la configuración de recursos por defecto (1 CPU, 1GB RAM, 3GB de almacenamiento)? [y/N]: " yn
case $yn in
  [Yy]* ) 
    CPU=1
    RAM=1024
    STORAGE=3
    ;;
  * ) 
    read -p "Introduzca el número de CPUs: " CPU
    read -p "Introduzca la cantidad de RAM en MB: " RAM
    read -p "Introduzca la cantidad de almacenamiento en GB: " STORAGE
    ;;
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

# Confirmar puerto para Nginx Proxy Manager
while true; do
  read -p "El puerto por defecto para Nginx Proxy Manager es 81. ¿Desea cambiarlo? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    while true; do
      read -p "Introduzca el nuevo puerto para  Nginx Proxy ManagerI: " NEW_PORT
      if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ]; then
        break 2  # Salir de ambos bucles while
      else
        echo -e "${RED}Por favor, introduzca un número de puerto válido (1024-65535).${NC}"
      fi
    done
  else
    NEW_PORT=8200
    break  # Salir del bucle while externo
  fi
done

# Crear el contenedor en local-lvm
echo "Creando el contenedor en local-lvm..."
pct create $VMID local:vztmpl/ubuntu-23.04-standard_23.04-1_amd64.tar.zst \
  --hostname $HOSTNAME \
  --password $PASSWORD \
  --unprivileged 1 \
  --net0 name=eth0,bridge=vmbr0,ip=$STATIC_IP \
  --cores $CPU \
  --memory $RAM \
  --storage local-lvm \
  --rootfs local-lvm:${STORAGE}

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
      echo -e "${GREEN}Creando el contenedor en local-lvm...${NC}"
      pct create $VMID local:vztmpl/ubuntu-23.04-standard_23.04-1_amd64.tar.zst \
        --hostname $HOSTNAME \
        --password $PASSWORD \
        --unprivileged 1 \
        --net0 name=eth0,bridge=vmbr0,ip=$STATIC_IP \
        --cores $CPU \
        --memory $RAM \
        --storage local-lvm
        --rootfs local-lvm:${STORAGE}
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

# Preguntar al usuario si el contenedor debe iniciar automáticamente
read -p "¿Desea que el contenedor inicie automáticamente? [y/N]: " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  echo "Configurando el contenedor para que inicie automáticamente..."
  pct set $VMID -onboot 1
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Configuración de inicio automático actualizada con éxito.${NC}"
  else
    echo -e "${RED}No se pudo actualizar la configuración de inicio automático. Deteniendo y eliminando el contenedor...${NC}"
    pct stop $VMID
    pct destroy $VMID
    exit 1
  fi
else
  echo "El contenedor no se configurará para iniciar automáticamente."
fi


# Habilitar el anidamiento para Docker
pct set $VMID -features nesting=1

# Iniciar el contenedor
echo -e "${GREEN}Iniciando el contenedor...${NC}"
pct start $VMID

# Esperar a que el contenedor se inicie completamente
sleep 10

# Iniciar actualizacion de OS
echo -e "${GREEN}Actualizando OS...${NC}"
pct exec $VMID -- bash -c "apt update && apt upgrade -y"

echo "-------------------------------------"
echo "Resumen de la instalación:"
echo "ID del contenedor: $VMID"
echo "Nombre del Contenedor: $HOSTNAME"
echo "OS: Ubuntu 23.04"
echo "Contraseña CT: $PASSWORD"
echo "CPU: $CPU"
echo "RAM: ${RAM}MB"
echo "STORAGE: $STORAGE"
echo "Network: $STATIC_IP"
echo "Email: admin@example.com"
echo "Password: changeme"

echo "-------------------------------------"

# Instalar docker y docker-compose
echo -e "${GREEN}Instalando Docker y Docker-Compose...${NC}"
pct exec $VMID -- bash -c "apt install docker docker-compose -y"

# Descargar el archivo docker-compose.yml de Firefly III
echo "Descargando el archivo docker-compose.yml para Nginx Proxy Manager..."
DOCKER_COMPOSE_DIR="/root/nginx-proxy-manager"
pct exec $VMID -- bash -c "mkdir -p $DOCKER_COMPOSE_DIR && cd $DOCKER_COMPOSE_DIR && wget https://raw.githubusercontent.com/wizapol/Proxmox-scripts/main/nginx/env/docker-compose.yml"

# Modificar el puerto en el archivo docker-compose.yml descargado
if pct exec $VMID -- bash -c "sed -i 's/81:81/$NEW_PORT:81/g' $DOCKER_COMPOSE_DIR/docker-compose.yml"; then
  echo -e "${GREEN}Puerto actualizado con éxito en docker-compose.yml.${NC}"
else
  echo -e "${RED}Error al actualizar el puerto. Abortando.${NC}"
  exit 1
fi

# Instalar Nginx Proxy Manager
echo -e "${GREEN}Instalando Nginx Proxy Manager...${NC}"
pct exec $VMID -- bash -c "docker-compose up -d"

# Añadir tag al contenedor
pct set $VMID -tags "Reverse Proxy"

# Construir el resumen de la instalación
RESUMEN="Proxmox Script by wizapol"

# Añadir la descripción al contenedor
pct set $VMID -description "$RESUMEN"

# Final del script
echo -e "${GREEN}La instalación se ha completado con éxito.${NC}"
INSTALL_SUCCESS="true"
