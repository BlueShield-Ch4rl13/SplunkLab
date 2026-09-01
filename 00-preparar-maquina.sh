#!/usr/bin/env bash
# =============================================================================
#  Prepara una máquina Ubuntu Server recién instalada para levantar Splunk
#  en Docker.  De ISO recién puesta a "docker compose up" listo.
# =============================================================================
#
#  Uso:
#      sudo ./00-preparar-maquina.sh
#      sudo ./00-preparar-maquina.sh --sin-firewall     (si ya lo gestionas tú)
#      sudo ./00-preparar-maquina.sh --usuario juan     (crea/usa ese usuario)
#
#  Es IDEMPOTENTE: puedes ejecutarlo dos veces sin romper nada. Cada paso
#  comprueba si ya está hecho antes de tocar.
#
#  Qué hace, en orden:
#      1. Comprobaciones previas (SO, arquitectura, RAM, disco)
#      2. Zona horaria y sincronización de hora
#      3. Actualizar el sistema
#      4. Paquetes base
#      5. Usuario de trabajo con sudo
#      6. SSH: endurecido solo si ya tienes clave (para no dejarte fuera)
#      7. Cortafuegos
#      8. Límites del sistema que pide Splunk (ulimits y huge pages)
#      9. Docker Engine desde el repositorio oficial
#     10. Resumen y qué hacer después
#
#  Lo que NO hace: instalar Splunk. Eso es el docker-compose del kit.
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Ajustes. Cámbialos aquí o pásalos como variables de entorno.
# --------------------------------------------------------------------------- #
USUARIO="${USUARIO:-${SUDO_USER:-$(logname 2>/dev/null || echo splunkadmin)}}"
ZONA_HORARIA="${ZONA_HORARIA:-Europe/Madrid}"
# Puertos que se abren en el cortafuegos. Quita los que no vayas a usar.
PUERTOS_TCP="${PUERTOS_TCP:-22 8000 8088 8089 8081}"
RAM_MINIMA_MB=5800          # Splunk pide 2 GB solo para él; con 6 GB va bien
DISCO_MINIMO_GB=20

CON_FIREWALL=1
for arg in "$@"; do
  case "$arg" in
    --sin-firewall) CON_FIREWALL=0 ;;
    --usuario)      shift; USUARIO="${1:-$USUARIO}" ;;
    --usuario=*)    USUARIO="${arg#*=}" ;;
    -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Salida
# --------------------------------------------------------------------------- #
VERDE=$'\033[92m'; ROJO=$'\033[91m'; AMBAR=$'\033[93m'; AZUL=$'\033[96m'; FIN=$'\033[0m'
PASO_N=0
paso()  { PASO_N=$((PASO_N+1)); printf '\n%s[%02d]%s %s\n' "$AZUL" "$PASO_N" "$FIN" "$1"; }
ok()    { printf '     %sOK%s    %s\n' "$VERDE" "$FIN" "$1"; }
info()  { printf '           %s\n' "$1"; }
aviso() { printf '     %sAVISO%s %s\n' "$AMBAR" "$FIN" "$1"; }
error() { printf '     %sERROR%s %s\n' "$ROJO" "$FIN" "$1"; }
morir() { error "$1"; exit 1; }

[[ $EUID -eq 0 ]] || morir "ejecútalo con sudo:  sudo $0"

printf '%s\n' "============================================================"
printf ' Preparando la máquina para Splunk en Docker\n'
printf '%s\n' "============================================================"

# =========================================================================== #
paso "Comprobaciones previas"
# =========================================================================== #
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  aviso "esto está pensado para Ubuntu Server; detectado '${ID:-desconocido}'."
  aviso "en Debian suele funcionar igual; en otras distribuciones, no."
else
  ok "Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-?})"
fi

ARQ="$(dpkg --print-architecture)"
[[ "$ARQ" == "amd64" || "$ARQ" == "arm64" ]] || morir "arquitectura $ARQ no soportada por las imágenes de Splunk"
ok "arquitectura $ARQ"

RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if (( RAM_MB < RAM_MINIMA_MB )); then
  aviso "solo ${RAM_MB} MB de RAM. Splunk necesita 2 GB para él y el resto"
  aviso "para el sistema y tus contenedores: apaga la VM y súbela a 6-8 GB."
else
  ok "RAM: ${RAM_MB} MB"
fi

DISCO_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if (( DISCO_GB < DISCO_MINIMO_GB )); then
  aviso "solo ${DISCO_GB} GB libres en /. Las imágenes de Splunk ocupan bastante;"
  aviso "con menos de ${DISCO_MINIMO_GB} GB te vas a quedar sin sitio."
else
  ok "disco libre en /: ${DISCO_GB} GB"
fi

CPUS=$(nproc)
(( CPUS >= 2 )) || aviso "solo ${CPUS} CPU. Splunk va muy justo; ponle 2 o 4 en la VM."
(( CPUS >= 2 )) && ok "CPUs: ${CPUS}"

# =========================================================================== #
paso "Zona horaria y hora sincronizada"
# =========================================================================== #
# Esto no es cosmético: si la hora de la máquina va mal, TODOS los eventos que
# indexes llevarán la hora mal, y en un SIEM eso lo invalida todo.
ACTUAL_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo desconocida)"
if [[ "$ACTUAL_TZ" != "$ZONA_HORARIA" ]]; then
  timedatectl set-timezone "$ZONA_HORARIA" && ok "zona horaria: $ZONA_HORARIA"
else
  ok "zona horaria ya era $ZONA_HORARIA"
fi
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  ok "hora sincronizada por NTP"
else
  timedatectl set-ntp true 2>/dev/null || true
  aviso "NTP no confirmado todavía; compruébalo luego con 'timedatectl'"
fi

# =========================================================================== #
paso "Actualizando el sistema"
# =========================================================================== #
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
ok "paquetes al día"

# =========================================================================== #
paso "Instalando paquetes base"
# =========================================================================== #
BASE=(ca-certificates curl gnupg git jq htop unzip ufw chrony)
FALTAN=()
for p in "${BASE[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || FALTAN+=("$p")
done
if (( ${#FALTAN[@]} )); then
  apt-get install -y -qq "${FALTAN[@]}"
  ok "instalados: ${FALTAN[*]}"
else
  ok "ya estaban todos"
fi

# =========================================================================== #
paso "Usuario de trabajo"
# =========================================================================== #
# Trabajar como root todo el rato es la forma más rápida de romper algo sin
# querer. Este usuario será el que use Docker.
if id "$USUARIO" >/dev/null 2>&1; then
  ok "el usuario '$USUARIO' ya existe"
else
  adduser --disabled-password --gecos "" "$USUARIO"
  aviso "usuario '$USUARIO' creado SIN contraseña."
  aviso "ponle una con:  sudo passwd $USUARIO"
fi
if id -nG "$USUARIO" | tr ' ' '\n' | grep -qx sudo; then
  ok "'$USUARIO' ya está en el grupo sudo"
else
  usermod -aG sudo "$USUARIO" && ok "'$USUARIO' añadido al grupo sudo"
fi

# =========================================================================== #
paso "SSH"
# =========================================================================== #
# Endurecer SSH está muy bien, pero desactivar la contraseña ANTES de tener una
# clave que funcione es la forma clásica de quedarse fuera de tu propia
# máquina. Por eso aquí solo se toca si ya hay clave autorizada.
CLAVES="/home/${USUARIO}/.ssh/authorized_keys"
if [[ -s "$CLAVES" ]]; then
  CONF="/etc/ssh/sshd_config.d/99-splunk-lab.conf"
  if [[ -f "$CONF" ]]; then
    ok "SSH ya endurecido ($CONF)"
  else
    cat > "$CONF" <<'EOF'
# Endurecido por 00-preparar-maquina.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
EOF
    if sshd -t 2>/dev/null; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
      ok "SSH: solo clave pública, sin root, sin contraseña"
    else
      rm -f "$CONF"
      error "la configuración de SSH no valida; se deja como estaba"
    fi
  fi
else
  aviso "no hay clave pública en $CLAVES: NO se toca SSH."
  info  "Cuando tengas una, desde tu PC:"
  info  "    ssh-copy-id ${USUARIO}@<ip-de-la-vm>"
  info  "y vuelve a ejecutar este script para endurecerlo."
fi

# =========================================================================== #
paso "Cortafuegos"
# =========================================================================== #
if (( CON_FIREWALL )); then
  ufw --force default deny incoming >/dev/null
  ufw --force default allow outgoing >/dev/null
  for p in $PUERTOS_TCP; do
    ufw allow "${p}/tcp" >/dev/null
  done
  if ufw status | grep -q "^Status: active"; then
    ok "ufw ya estaba activo; reglas actualizadas"
  else
    ufw --force enable >/dev/null
    ok "ufw activado"
  fi
  info "puertos TCP abiertos: $PUERTOS_TCP"
  aviso "OJO, Y ESTO SORPRENDE A MUCHA GENTE:"
  aviso "  Docker escribe sus propias reglas de iptables y SE SALTA ufw."
  aviso "  Un puerto que publiques con 'ports: 8000:8000' queda accesible"
  aviso "  desde fuera aunque ufw lo tenga cerrado."
  info  "  Solución: publica solo en local, con 127.0.0.1 delante:"
  info  "      ports:"
  info  "        - \"127.0.0.1:8000:8000\""
  info  "  y llega a la interfaz por un túnel SSH desde tu PC:"
  info  "      ssh -L 8000:127.0.0.1:8000 ${USUARIO}@<ip-de-la-vm>"
else
  aviso "cortafuegos omitido (--sin-firewall)"
fi

# =========================================================================== #
paso "Límites del sistema que pide Splunk"
# =========================================================================== #
# Splunk abre MUCHÍSIMOS ficheros a la vez (cada bucket son varios). Con los
# límites por defecto de Linux se queda corto y empieza a dar errores raros
# en splunkd.log que no parecen tener nada que ver.
LIMITES="/etc/security/limits.d/99-splunk.conf"
if [[ -f "$LIMITES" ]]; then
  ok "límites ya configurados ($LIMITES)"
else
  cat > "$LIMITES" <<'EOF'
# Valores recomendados por Splunk (ver documentación de ulimit de Splunk)
*   soft   nofile   64000
*   hard   nofile   64000
*   soft   nproc    16000
*   hard   nproc    16000
*   soft   fsize    unlimited
*   hard   fsize    unlimited
EOF
  ok "escrito $LIMITES (nofile 64000, nproc 16000, fsize sin límite)"
fi

# Y lo mismo para los servicios que arranca systemd, que NO leen limits.conf.
mkdir -p /etc/systemd/system.conf.d
SYSD="/etc/systemd/system.conf.d/99-splunk-limits.conf"
if [[ -f "$SYSD" ]]; then
  ok "límites de systemd ya configurados"
else
  cat > "$SYSD" <<'EOF'
[Manager]
DefaultLimitNOFILE=65536
DefaultLimitNPROC=16000
DefaultLimitFSIZE=infinity
EOF
  ok "escrito $SYSD"
  aviso "los límites de systemd se aplican del todo al reiniciar la máquina"
fi

# --- Transparent Huge Pages -------------------------------------------------
# Splunk documenta que las THP le degradan el rendimiento de forma notable.
# Es una opción del núcleo del ANFITRIÓN: aunque Splunk corra en contenedor,
# hay que desactivarla aquí.
THP_UNIT="/etc/systemd/system/desactivar-thp.service"
if [[ -f "$THP_UNIT" ]]; then
  ok "servicio de THP ya instalado"
else
  cat > "$THP_UNIT" <<'EOF'
[Unit]
Description=Desactivar Transparent Huge Pages (recomendado por Splunk)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
  systemctl daemon-reload
  systemctl enable --now desactivar-thp.service >/dev/null 2>&1 || true
  ok "servicio instalado: desactiva las THP en cada arranque"
fi
# No damos por hecho que ha funcionado: lo miramos.
if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  ESTADO_THP="$(cat /sys/kernel/mm/transparent_hugepage/enabled)"
  if [[ "$ESTADO_THP" == *"[never]"* ]]; then
    ok "THP desactivadas ahora mismo: $ESTADO_THP"
  else
    aviso "THP todavía activas: $ESTADO_THP"
    aviso "quedarán desactivadas en el próximo arranque; para hacerlo ya:"
    info  "    sudo systemctl start desactivar-thp.service"
  fi
else
  info "este núcleo no expone la opción de THP; nada que hacer"
fi

# =========================================================================== #
paso "Docker Engine"
# =========================================================================== #
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker ya instalado: $(docker --version | cut -d, -f1)"
else
  # Se quitan primero los paquetes de Docker que trae Ubuntu, que son viejos
  # y chocan con los oficiales.
  for viejo in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    dpkg -s "$viejo" >/dev/null 2>&1 && apt-get remove -y -qq "$viejo" || true
  done

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Formato deb822 (.sources), que es el que documenta Docker ahora.
  tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME}}
Components: stable
Architectures: ${ARQ}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
                         docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker >/dev/null 2>&1 || true
  ok "instalado $(docker --version | cut -d, -f1)"
  ok "instalado Docker Compose $(docker compose version --short 2>/dev/null || echo '(v2)')"
fi

# --- El usuario, al grupo docker -------------------------------------------
if id -nG "$USUARIO" | tr ' ' '\n' | grep -qx docker; then
  ok "'$USUARIO' ya está en el grupo docker"
else
  usermod -aG docker "$USUARIO"
  ok "'$USUARIO' añadido al grupo docker"
  aviso "tiene que CERRAR SESIÓN Y VOLVER A ENTRAR para que le haga efecto"
  aviso "(estar en el grupo docker es equivalente a ser root en la máquina)"
fi

# --- Rotación de los logs de los contenedores -------------------------------
# Sin esto, el json.log de un contenedor charlatán crece sin freno hasta
# llenar el disco. Le pasa a todo el mundo una vez.
DAEMON="/etc/docker/daemon.json"
if [[ -f "$DAEMON" ]]; then
  ok "ya existe $DAEMON; no se toca (revísalo tú)"
else
  mkdir -p /etc/docker
  cat > "$DAEMON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
  systemctl restart docker
  ok "rotación de logs de contenedores: 3 ficheros de 50 MB como mucho"
fi

# =========================================================================== #
paso "Comprobación final"
# =========================================================================== #
FALLOS=0
docker run --rm hello-world >/dev/null 2>&1 && ok "docker funciona" || { error "docker no arranca contenedores"; FALLOS=1; }
docker compose version >/dev/null 2>&1 && ok "docker compose disponible" || { error "falta docker compose"; FALLOS=1; }

printf '\n%s\n' "============================================================"
if (( FALLOS )); then
  printf ' %sTerminado con errores%s: revisa lo de arriba.\n' "$ROJO" "$FIN"
else
  printf ' %sMáquina lista.%s\n\n' "$VERDE" "$FIN"
  printf ' Ahora, como usuario %s (cierra sesión y vuelve a entrar):\n\n' "$USUARIO"
  printf '     cd splunk-inicio\n'
  printf '     cp .env.example .env\n'
  printf '     nano .env            # cambia la contraseña\n'
  printf '     docker compose up -d\n'
  printf '     ./scripts/01-verificar.sh\n\n'
  printf ' Y si has tocado los límites de systemd por primera vez,\n'
  printf ' reinicia la máquina antes:  sudo reboot\n'
fi
printf '%s\n' "============================================================"
