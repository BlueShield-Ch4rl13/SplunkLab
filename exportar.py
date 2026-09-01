#!/usr/bin/env python3
"""
Saca los datos de Splunk y los deja en JSON y en HTML.

    python3 exportar.py                  una vez, escribe en salida/
    python3 exportar.py --servir         además lo sirve en http://localhost:8081
    python3 exportar.py --cada 60        se repite cada 60 segundos

Genera:
    salida/datos.json      todo junto, para consumir desde donde quieras
    salida/dashboard.html  un dashboard con los datos DENTRO del fichero
    salida/csv/<id>.csv    un CSV por consulta

El HTML es autocontenido: puedes copiarlo, adjuntarlo en un correo o subirlo a
tu web y sigue funcionando sin Splunk delante y sin conexión.

No necesita instalar nada: solo la librería estándar de Python 3.
"""

import argparse
import csv
import io
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# =============================================================================
#  EDITA AQUÍ: qué quieres exportar
# =============================================================================
#  Cada entrada es un panel. Tipos disponibles:
#     indicador -> un número grande      (usa campo_valor)
#     barras    -> ranking               (usa campo_etiqueta y campo_valor)
#     serie     -> evolución temporal    (la búsqueda debe llevar timechart)
#     tabla     -> lo que devuelva el SPL
#
#  Nota sobre el SPL: en la API la búsqueda tiene que empezar por "search" o
#  por "|". Este script lo añade solo si te olvidas (ver _normaliza).
# =============================================================================

TITULO = "Mi servicio en Docker"
SUBTITULO = "Datos sacados de Splunk por la API REST"
RANGO = {"earliest": "-24h", "latest": "now"}

CONSULTAS = [
    {
        "id": "total_eventos",
        "titulo": "Eventos recogidos",
        "tipo": "indicador",
        "spl": "index=mi_servicio | stats count AS valor",
        "campo_valor": "valor",
        "unidad": "eventos",
    },
    {
        "id": "errores",
        "titulo": "Peticiones con error",
        "tipo": "indicador",
        "spl": 'index=mi_servicio status>=400 | stats count AS valor',
        "campo_valor": "valor",
        "unidad": "respuestas 4xx y 5xx",
        "umbral_aviso": 10,
        "umbral_critico": 50,
    },
    {
        "id": "contenedores",
        "titulo": "Contenedores enviando",
        "tipo": "indicador",
        "spl": "index=mi_servicio | stats dc(contenedor) AS valor",
        "campo_valor": "valor",
        "unidad": "servicios",
    },
    {
        "id": "latencia",
        "titulo": "Latencia media",
        "tipo": "indicador",
        "spl": ("index=mi_servicio request_time=* "
                "| stats avg(request_time) AS valor | eval valor=round(valor*1000, 1)"),
        "campo_valor": "valor",
        "unidad": "milisegundos",
        "umbral_aviso": 300,
        "umbral_critico": 1000,
    },
    {
        "id": "en_el_tiempo",
        "titulo": "Actividad por contenedor",
        "descripcion": "Un valle aquí suele significar que el servicio ha dejado de enviar, no que no pase nada",
        "tipo": "serie",
        "spl": "index=mi_servicio | timechart span=10m count by contenedor limit=6",
        "campo_x": "_time",
    },
    {
        "id": "por_resultado",
        "titulo": "Cómo termina cada petición",
        "descripcion": "El campo resultado sale de un EVAL en props.conf: no hay que calcularlo cada vez",
        "tipo": "barras",
        "spl": "index=mi_servicio | stats count AS valor by resultado | sort - valor",
        "campo_etiqueta": "resultado",
        "campo_valor": "valor",
    },
    {
        "id": "rutas",
        "titulo": "Rutas más pedidas",
        "tipo": "barras",
        "spl": "index=mi_servicio uri=* | stats count AS valor by uri | sort - valor | head 10",
        "campo_etiqueta": "uri",
        "campo_valor": "valor",
    },
    {
        "id": "ultimos_errores",
        "titulo": "Últimos errores",
        "descripcion": "Lo primero que se mira cuando alguien dice que algo va mal",
        "tipo": "tabla",
        "spl": ("index=mi_servicio status>=400 "
                "| eval hora=strftime(_time, \"%d/%m %H:%M:%S\") "
                "| table hora contenedor method uri status remote_addr "
                "| sort - hora | head 20"),
        "columnas": ["hora", "contenedor", "method", "uri", "status", "remote_addr"],
    },
]

# =============================================================================
#  Conexión con Splunk (todo por variables de entorno)
# =============================================================================
API = os.environ.get("SPLUNK_API", "https://localhost:8089")
USUARIO = os.environ.get("SPLUNK_USER", "admin")
CLAVE = os.environ.get("SPLUNK_PASSWORD", "")
TOKEN = os.environ.get("SPLUNK_TOKEN", "").strip()
SALIDA = os.environ.get("SALIDA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "salida"))
PLANTILLA = os.environ.get("PLANTILLA",
                           os.path.join(os.path.dirname(os.path.abspath(__file__)), "plantilla.html"))

# El certificado de Splunk es autofirmado. En el laboratorio no se valida;
# en producción se despliega la CA y se quita esto.
_ctx = ssl.create_default_context()
_ctx.check_hostname = False
_ctx.verify_mode = ssl.CERT_NONE


class ErrorSplunk(Exception):
    pass


def log(msg):
    print(f"[exportar] {msg}", flush=True)


def _normaliza(spl):
    """La API exige que la búsqueda empiece por 'search' o por una tubería.

    Es el error número uno al llamar a esta API: pegas el SPL tal cual lo
    tenías en la interfaz —donde el 'search' inicial es implícito— y te
    devuelve cero resultados sin decirte por qué.
    """
    limpia = spl.strip()
    if limpia.startswith("|") or limpia.lower().startswith("search "):
        return limpia
    return "search " + limpia


def login():
    """Cambia usuario y contraseña por una clave de sesión.

    Con un token de autenticación (Settings > Tokens en Splunk) esto no hace
    falta, y es lo correcto para cualquier cosa automatizada: no caduca al
    reiniciar, se revoca solo y no expone la contraseña de admin.
    """
    if TOKEN:
        return None
    if not CLAVE:
        raise ErrorSplunk("define SPLUNK_PASSWORD (o SPLUNK_TOKEN) antes de ejecutar")
    datos = urllib.parse.urlencode({
        "username": USUARIO, "password": CLAVE, "output_mode": "json"}).encode()
    req = urllib.request.Request(f"{API}/services/auth/login", data=datos, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ctx) as resp:
            return json.loads(resp.read().decode())["sessionKey"]
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise ErrorSplunk("usuario o contraseña incorrectos") from exc
        raise ErrorSplunk(f"login fallido ({exc.code})") from exc
    except urllib.error.URLError as exc:
        raise ErrorSplunk(f"no se puede llegar a {API}: {exc.reason}") from exc


def buscar(sesion, spl, earliest, latest):
    """Lanza la búsqueda y devuelve una lista de diccionarios.

    Usa /services/search/jobs/export: una sola petición, y Splunk va
    devolviendo los resultados según los produce. La respuesta es un JSON por
    línea, no un array.
    """
    cabeceras = {"Authorization": f"Bearer {TOKEN}"} if TOKEN else \
                {"Authorization": f"Splunk {sesion}"}
    datos = urllib.parse.urlencode({
        "search": _normaliza(spl),
        "earliest_time": earliest,
        "latest_time": latest,
        "output_mode": "json",   # json | json_rows | json_cols | csv | xml | raw
        "count": 0,              # 0 = sin límite (no "ninguno")
    }).encode()
    req = urllib.request.Request(f"{API}/services/search/jobs/export",
                                 data=datos, headers=cabeceras, method="POST")
    filas, avisos = [], []
    try:
        with urllib.request.urlopen(req, timeout=180, context=_ctx) as resp:
            for linea in resp:
                linea = linea.decode("utf-8").strip()
                if not linea:
                    continue
                try:
                    obj = json.loads(linea)
                except json.JSONDecodeError:
                    continue
                if "result" in obj:
                    filas.append(obj["result"])
                elif "messages" in obj:
                    avisos.extend(m.get("text", "") for m in obj["messages"])
    except urllib.error.HTTPError as exc:
        raise ErrorSplunk(f"búsqueda rechazada ({exc.code}): "
                          f"{exc.read()[:200].decode(errors='replace')}") from exc
    except urllib.error.URLError as exc:
        raise ErrorSplunk(f"no se puede llegar a {API}: {exc.reason}") from exc
    if avisos and not filas:
        raise ErrorSplunk("Splunk avisa: " + " | ".join(avisos))
    return filas


# =============================================================================
#  De resultados de Splunk a paneles
# =============================================================================
def _num(valor, por_defecto=0.0):
    try:
        return float(valor)
    except (TypeError, ValueError):
        return por_defecto


def preparar(consulta, filas):
    tipo = consulta.get("tipo", "tabla")
    panel = {
        "id": consulta["id"], "titulo": consulta["titulo"], "tipo": tipo,
        "descripcion": consulta.get("descripcion", ""), "spl": consulta["spl"],
        "filas_devueltas": len(filas),
    }
    if tipo == "indicador":
        campo = consulta.get("campo_valor", "valor")
        panel.update({
            "valor": _num(filas[0].get(campo)) if filas else 0,
            "unidad": consulta.get("unidad", ""),
            "umbral_aviso": consulta.get("umbral_aviso"),
            "umbral_critico": consulta.get("umbral_critico"),
        })
    elif tipo == "barras":
        et, va = consulta.get("campo_etiqueta"), consulta.get("campo_valor", "valor")
        panel["datos"] = [{"etiqueta": str(f.get(et, "-")), "valor": _num(f.get(va))}
                          for f in filas]
    elif tipo == "serie":
        campo_x = consulta.get("campo_x", "_time")
        series, ejex = {}, []
        for f in filas:
            ejex.append(f.get(campo_x, ""))
            for clave, valor in f.items():
                if clave == campo_x or clave.startswith("_"):
                    continue
                series.setdefault(clave, []).append(_num(valor))
        panel["eje_x"] = ejex
        panel["series"] = [{"nombre": k, "valores": v} for k, v in sorted(series.items())]
    else:
        columnas = consulta.get("columnas") or (list(filas[0].keys()) if filas else [])
        panel["columnas"] = columnas
        panel["filas"] = [[str(f.get(c, "")) for c in columnas] for f in filas]
    return panel


def a_csv(consulta, filas):
    if not filas:
        return "sin resultados\n"
    columnas = consulta.get("columnas") or list(filas[0].keys())
    buffer = io.StringIO()
    escritor = csv.DictWriter(buffer, fieldnames=columnas, extrasaction="ignore")
    escritor.writeheader()
    for fila in filas:
        escritor.writerow({c: fila.get(c, "") for c in columnas})
    return buffer.getvalue()


# =============================================================================
#  Escribir la salida
# =============================================================================
def exportar_una_vez():
    sesion = login()
    paneles, errores = [], []
    for consulta in CONSULTAS:
        try:
            filas = buscar(sesion, consulta["spl"],
                           consulta.get("earliest", RANGO["earliest"]),
                           consulta.get("latest", RANGO["latest"]))
            paneles.append(preparar(consulta, filas))
            ruta = os.path.join(SALIDA, "csv", f"{consulta['id']}.csv")
            os.makedirs(os.path.dirname(ruta), exist_ok=True)
            with open(ruta, "w", encoding="utf-8") as fh:
                fh.write(a_csv(consulta, filas))
            log(f"  {consulta['id']:18s} {len(filas):5d} filas")
        except ErrorSplunk as exc:
            errores.append({"panel": consulta["id"], "error": str(exc)})
            paneles.append({"id": consulta["id"], "titulo": consulta["titulo"],
                            "tipo": consulta.get("tipo", "tabla"), "error": str(exc),
                            "descripcion": consulta.get("descripcion", ""),
                            "spl": consulta["spl"]})
            log(f"  {consulta['id']:18s} ERROR: {exc}")

    datos = {
        "titulo": TITULO, "subtitulo": SUBTITULO,
        "generado": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "rango": RANGO, "origen": API, "paneles": paneles, "errores": errores,
    }

    os.makedirs(SALIDA, exist_ok=True)
    ruta_json = os.path.join(SALIDA, "datos.json")
    with open(ruta_json, "w", encoding="utf-8") as fh:
        json.dump(datos, fh, ensure_ascii=False, indent=2)

    with open(PLANTILLA, encoding="utf-8") as fh:
        plantilla = fh.read()
    # Los datos se incrustan en el HTML. El "</" escapado evita que un valor
    # de los datos cierre la etiqueta <script> antes de tiempo.
    incrustado = json.dumps(datos, ensure_ascii=False).replace("</", "<\\/")
    with open(os.path.join(SALIDA, "dashboard.html"), "w", encoding="utf-8") as fh:
        fh.write(plantilla.replace("/*__DATOS__*/null", incrustado))

    log(f"escrito {ruta_json} ({os.path.getsize(ruta_json)} bytes), "
        f"dashboard.html y {len(CONSULTAS)} CSV")
    return len(errores)


def servir(puerto):
    import threading
    from functools import partial
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    os.makedirs(SALIDA, exist_ok=True)
    manejador = partial(SimpleHTTPRequestHandler, directory=SALIDA)
    manejador.log_message = lambda *a, **k: None
    srv = ThreadingHTTPServer(("0.0.0.0", puerto), manejador)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"sirviendo en http://localhost:{puerto}/dashboard.html")


def main():
    ap = argparse.ArgumentParser(description="Exporta datos de Splunk a JSON, CSV y HTML")
    ap.add_argument("--servir", action="store_true", help="sirve la salida por HTTP")
    ap.add_argument("--puerto", type=int, default=8081)
    ap.add_argument("--cada", type=int, default=0,
                    help="repetir cada N segundos (0 = una sola vez)")
    args = ap.parse_args()

    if args.servir:
        servir(args.puerto)

    while True:
        try:
            log(f"consultando {API} ...")
            exportar_una_vez()
        except ErrorSplunk as exc:
            log(f"ERROR: {exc}")
            if not (args.cada or args.servir):
                return 1
        if not args.cada:
            break
        time.sleep(args.cada)

    if args.servir and not args.cada:
        log("Ctrl+C para parar el servidor")
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
