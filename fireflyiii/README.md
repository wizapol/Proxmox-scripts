Firefly III
Proxmox automated scripts by wizapol

Este script genera un contenedor de ubuntu 23 e instala por docker compose Firefly III.

    #Sistema Operativo: Alpine 3.18.
    #Configuración de VM:
        Recursos por defecto: 1 CPU, 1GB RAM.
        Opción para personalizar recursos.
    #Red: Opción para configurar IP estática o DHCP.

Corre este comando en la consola de Proxmox:

bash -c "$(wget -qLO - https://raw.githubusercontent.com/wizapol/Proxmox-scripts/main/fireflyiii/fireflyiii.sh)"

Para ingresar a este aplicativo:
ingresar a: "(IP_VM):8200"

Atascate!
