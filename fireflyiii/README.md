Firefly III
Proxmox automated scripts by wizapol

Este script genera un contenedor de Alpine 3.18 e instala por docker compose Firefly III.

    #Sistema Operativo: Alpine 3.18.
    #Configuración de VM: 1 CPU, 1GB RAM, 1GB Storage.

Corre este comando en la consola de Proxmox:

bash -c "$(wget -qLO - https://raw.githubusercontent.com/wizapol/Proxmox-scripts/main/fireflyiii/fireflyiii.sh)"

Para este aplicativo, ingresar a: "(IP_VM):8200"

Atascate!
