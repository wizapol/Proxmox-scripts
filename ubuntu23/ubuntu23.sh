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
  echo "  Instalador de Firefly III en Proxmox by wizapol"
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
read -p "¿Desea usar la configuración de recursos por defecto (1 CPU, 512MB RAM, 3GB de almacenamiento)? [y/N]: " yn
case $yn in
  [Yy]* ) 
    CPU=1
    RAM=512
    STORAGE=3072
    ;;
  * ) 
    read -p "Introduzca el número de CPUs: " CPU
    read -p "Introduzca la cantidad de RAM en MB: " RAM
    read -p "Introduzca la cantidad de almacenamiento en MB: " STORAGE
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

# Confirmar puerto para Firefly III
while true; do
  read -p "El puerto por defecto para Firefly III es 8200. ¿Desea cambiarlo? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    while true; do
      read -p "Introduzca el nuevo puerto para Firefly III: " NEW_PORT
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
  --hostname firefly-iii \
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
        --hostname firefly-iii \
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


# Habilitar el anidamiento para Docker
pct set $VMID -features nesting=1

echo -e "${GREEN}Imagen de Ubuntu Instalada con éxito.${NC}"


INSTALL_SUCCESS=true
