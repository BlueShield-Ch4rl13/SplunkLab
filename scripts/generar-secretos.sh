#!/usr/bin/env bash
# =============================================================================
#  Crea el .env y los secretos del laboratorio, sin valores de ejemplo.
#
#  Lo llama "make up" antes de arrancar. Se puede ejecutar a mano:
#      ./scripts/generar-secretos.sh
#
#  - Si no hay .env, lo copia de .env.example.
#  - Si SPLUNK_PASSWORD está vacía o es un valor de ejemplo, genera una.
#  - Si HEC_TOKEN está vacío o es el token de ejemplo antiguo, genera un UUID.
#  - Escribe la stanza del token en splunk/apps/mi_indice/local/inputs.conf,
#    que .gitignore deja fuera del repositorio.
#
#  No toca valores que ya hayas puesto tú.
# =============================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

ENV_FILE=".env"
LOCAL_DIR="splunk/apps/mi_indice/local"
LOCAL_INPUTS="$LOCAL_DIR/inputs.conf"
# Valores que estuvieron publicados en el repositorio: nunca valen como secreto.
TOKEN_PUBLICO="11112222-3333-4444-5555-666677778888"

[ -f "$ENV_FILE" ] || cp .env.example "$ENV_FILE"
chmod 600 "$ENV_FILE"

leer() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true; }

poner() {   # poner CLAVE VALOR: cambia la línea o la añade
  if grep -qE "^$1=" "$ENV_FILE"; then
    python3 - "$ENV_FILE" "$1" "$2" <<'PY'
import sys, re
ruta, clave, valor = sys.argv[1:]
texto = open(ruta, encoding="utf-8").read()
texto = re.sub(rf"^{re.escape(clave)}=.*$", f"{clave}={valor}", texto, count=1, flags=re.M)
open(ruta, "w", encoding="utf-8").write(texto)
PY
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

clave="$(leer SPLUNK_PASSWORD)"
case "$clave" in
  ""|CAMBIA_LA_CONTRASEÑA|CAMBIA_LA_CONTRASENA|changeme|Changeme123)
    clave="Lab-$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
    poner SPLUNK_PASSWORD "$clave"
    echo "  SPLUNK_PASSWORD generada (está en .env)"
    ;;
esac

token="$(leer HEC_TOKEN)"
if [ -z "$token" ] || [ "$token" = "$TOKEN_PUBLICO" ]; then
  token="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  poner HEC_TOKEN "$token"
  echo "  HEC_TOKEN generado (está en .env)"
fi

mkdir -p "$LOCAL_DIR"
cat > "$LOCAL_INPUTS" <<EOF
# GENERADO por scripts/generar-secretos.sh a partir de HEC_TOKEN del .env.
# No se sube al repositorio (.gitignore). Para cambiar el token, cámbialo en
# .env y vuelve a ejecutar el script (o "make up").
[http://mi_servicio]
disabled = 0
token = $token
index = mi_servicio
# Lista blanca de índices a los que este token puede escribir. Si alguien
# intenta mandar a otro, Splunk responde "Incorrect index" y lo rechaza.
indexes = mi_servicio
sourcetype = mi_servicio:docker
description = Logs del servicio de docker-compose
EOF
chmod 644 "$LOCAL_INPUTS"   # lo lee el usuario splunk del contenedor
