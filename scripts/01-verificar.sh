#!/usr/bin/env bash
# =============================================================================
#  Comprueba que la máquina y el laboratorio están como deben.
#  Ejecútalo después de 00-preparar-maquina.sh y después de "docker compose up".
#
#      ./scripts/01-verificar.sh
#
#  No cambia nada: solo mira y te dice qué falta.
# =============================================================================

set -uo pipefail

VERDE=$'\033[92m'; ROJO=$'\033[91m'; AMBAR=$'\033[93m'; AZUL=$'\033[96m'; FIN=$'\033[0m'
FALLOS=0; AVISOS=0
ok()    { printf '  %sOK%s    %s\n' "$VERDE" "$FIN" "$1"; }
mal()   { printf '  %sFALLO%s %s\n' "$ROJO" "$FIN" "$1"; FALLOS=$((FALLOS+1)); }
aviso() { printf '  %sAVISO%s %s\n' "$AMBAR" "$FIN" "$1"; AVISOS=$((AVISOS+1)); }
titulo(){ printf '\n%s--- %s%s\n' "$AZUL" "$1" "$FIN"; }

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ" || exit 1

# --------------------------------------------------------------------------- #
titulo "La máquina"
# --------------------------------------------------------------------------- #
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
(( RAM_MB >= 5800 )) && ok "RAM: ${RAM_MB} MB" || aviso "RAM: ${RAM_MB} MB (Splunk va justo por debajo de 6 GB)"

DISCO_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
(( DISCO_GB >= 20 )) && ok "disco libre: ${DISCO_GB} GB" || aviso "disco libre: ${DISCO_GB} GB (poco margen)"

if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  if grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled; then
    ok "transparent huge pages desactivadas"
  else
    aviso "THP activas: Splunk pierde rendimiento. Ejecuta 00-preparar-maquina.sh"
  fi
fi

LIMITE=$(ulimit -n)
if [[ "$LIMITE" == "unlimited" ]] || (( LIMITE >= 64000 )); then
  ok "límite de ficheros abiertos: $LIMITE"
else
  aviso "límite de ficheros abiertos: $LIMITE (Splunk recomienda 64000; ¿reiniciaste tras el script?)"
fi

if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  ok "hora sincronizada ($(timedatectl show -p Timezone --value))"
else
  aviso "la hora no está sincronizada por NTP: los eventos se indexarán con hora mal"
fi

# --------------------------------------------------------------------------- #
titulo "Docker"
# --------------------------------------------------------------------------- #
if command -v docker >/dev/null 2>&1; then
  ok "$(docker --version | cut -d, -f1)"
else
  mal "docker no está instalado"
fi
docker compose version >/dev/null 2>&1 && ok "docker compose disponible" || mal "falta el plugin docker compose"
if docker info >/dev/null 2>&1; then
  ok "puedes hablar con el demonio sin sudo"
else
  mal "no puedes usar docker sin sudo (¿cerraste sesión tras entrar en el grupo docker?)"
fi
if [[ -f /etc/docker/daemon.json ]] && grep -q max-size /etc/docker/daemon.json; then
  ok "rotación de logs de contenedores configurada"
else
  aviso "sin rotación de logs: un contenedor charlatán puede llenarte el disco"
fi

# --------------------------------------------------------------------------- #
titulo "El laboratorio"
# --------------------------------------------------------------------------- #
if [[ -f .env ]]; then
  ok "existe .env"
  CLAVE=$(grep -E '^SPLUNK_PASSWORD=' .env | cut -d= -f2-)
  TOKEN_ENV=$(grep -E '^HEC_TOKEN=' .env | cut -d= -f2-)
  (( ${#CLAVE} >= 8 )) && ok "la contraseña tiene ${#CLAVE} caracteres" \
                       || mal "SPLUNK_PASSWORD debe tener 8 caracteres o más"
  TOKEN_CONF=$(grep -E '^token *=' splunk/apps/mi_indice/default/inputs.conf | head -1 | cut -d= -f2- | tr -d ' ')
  if [[ "$TOKEN_ENV" == "$TOKEN_CONF" ]]; then
    ok "el token de HEC coincide en .env y en inputs.conf"
  else
    mal "el token de .env y el de inputs.conf NO coinciden: los logs no entrarán"
  fi
else
  mal "falta .env  (cp .env.example .env)"
fi

if docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | grep -q .; then
  while read -r servicio estado; do
    [[ "$estado" == "running" ]] && ok "contenedor $servicio: $estado" \
                                 || aviso "contenedor $servicio: $estado"
  done < <(docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null)
else
  aviso "no hay contenedores levantados (docker compose up -d)"
fi

# --------------------------------------------------------------------------- #
titulo "Splunk"
# --------------------------------------------------------------------------- #
if docker compose ps --services --filter status=running 2>/dev/null | grep -qx splunk; then
  SALUD=$(docker inspect --format '{{.State.Health.Status}}' splunk 2>/dev/null || echo desconocida)
  [[ "$SALUD" == "healthy" ]] && ok "Splunk healthy" || aviso "Splunk todavía '$SALUD' (el primer arranque tarda 1-3 min)"

  if [[ "$SALUD" == "healthy" && -n "${CLAVE:-}" ]]; then
    if docker compose exec -T splunk /opt/splunk/bin/splunk list index -auth "admin:${CLAVE}" 2>/dev/null | grep -qE '^mi_servicio'; then
      ok "el índice mi_servicio existe"
    else
      mal "no encuentro el índice mi_servicio: revisa indexes.conf y reinicia Splunk"
    fi

    RESP=$(docker compose exec -T splunk curl -sk https://localhost:8088/services/collector/event \
             -H "Authorization: Splunk ${TOKEN_ENV}" \
             -d '{"event":{"prueba":"01-verificar"},"sourcetype":"mi_servicio:docker"}' 2>/dev/null)
    if grep -q '"code":0' <<<"$RESP"; then
      ok "el token de HEC funciona"
    else
      mal "HEC responde: ${RESP:-sin respuesta}"
    fi

    EVENTOS=$(docker compose exec -T splunk /opt/splunk/bin/splunk search \
                'index=mi_servicio | stats count AS n | fields n' \
                -auth "admin:${CLAVE}" -earliest_time -24h 2>/dev/null | tr -dc '0-9')
    if [[ -n "$EVENTOS" && "$EVENTOS" -gt 0 ]]; then
      ok "hay ${EVENTOS} eventos en el índice (últimas 24 h)"
    else
      aviso "el índice está vacío: genera tráfico con 'make trafico'"
    fi
  fi
else
  aviso "Splunk no está levantado"
fi

# --------------------------------------------------------------------------- #
titulo "La salida"
# --------------------------------------------------------------------------- #
command -v python3 >/dev/null 2>&1 && ok "python3 disponible para exportar.py" \
                                   || mal "falta python3 (sudo apt install python3)"
if [[ -f salida/datos.json ]]; then
  ok "salida/datos.json ($(stat -c%s salida/datos.json) bytes)"
  [[ -f salida/dashboard.html ]] && ok "salida/dashboard.html generado" \
                                 || aviso "falta salida/dashboard.html"
else
  aviso "todavía no has exportado nada (make exportar)"
fi

# --------------------------------------------------------------------------- #
printf '\n============================================================\n'
if (( FALLOS )); then
  printf ' %s%d fallo(s)%s y %d aviso(s)\n' "$ROJO" "$FALLOS" "$FIN" "$AVISOS"
  exit 1
fi
printf ' %sTodo correcto%s (%d aviso(s))\n' "$VERDE" "$FIN" "$AVISOS"
printf '============================================================\n'
