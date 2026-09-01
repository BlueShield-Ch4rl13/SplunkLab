#!/usr/bin/env python3
"""
Te escribe el FIELDALIAS que necesita TU aplicación.

El problema que resuelve: el driver de logging de Docker no manda tu línea tal
cual. La envuelve en un sobre:

    {"tag":"/mi-servicio", "source":"stdout", "attrs":{}, "line": <tu log>}

Con splunk-format=json, tu JSON va dentro de "line". Resultado: en Splunk tus
campos no se llaman "status" sino "line.status", y una consulta como
`index=mi_servicio status>=400` devuelve CERO resultados sin dar ningún error.

Este script coge una línea de log de tu aplicación y te escribe el FIELDALIAS
que hay que pegar en props.conf para que los campos suban al primer nivel.

Uso:
    # a partir de una línea suelta
    echo '{"status":200,"uri":"/","ms":12}' | python3 scripts/02-alias-para-mi-app.py

    # o directamente de lo que escupe tu contenedor
    docker compose logs --no-log-prefix --tail 50 mi-servicio | python3 scripts/02-alias-para-mi-app.py

    # o de un fichero
    python3 scripts/02-alias-para-mi-app.py access.log
"""

import json
import sys

SOURCETYPE = "mi_servicio:docker"


def aplanar(obj, prefijo=""):
    """Igual que hace Splunk con KV_MODE=json: las claves anidadas llevan punto."""
    campos = {}
    for clave, valor in obj.items():
        ruta = f"{prefijo}{clave}"
        if isinstance(valor, dict):
            campos.update(aplanar(valor, ruta + "."))
        elif isinstance(valor, list):
            campos[ruta] = f"(lista de {len(valor)})"
        else:
            campos[ruta] = valor
    return campos


def main():
    if len(sys.argv) > 1:
        texto = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    else:
        texto = sys.stdin.read()

    objetos, no_json = [], 0
    for linea in texto.splitlines():
        linea = linea.strip()
        if not linea:
            continue
        try:
            obj = json.loads(linea)
            if isinstance(obj, dict):
                objetos.append(obj)
            else:
                no_json += 1
        except json.JSONDecodeError:
            no_json += 1

    if not objetos:
        print("No he encontrado ni una línea de JSON válido.\n")
        print("Si tu aplicación escribe texto plano, el driver la mandará entera")
        print("dentro del campo 'line' como cadena, y en Splunk tendrás que")
        print("extraer los campos con una regex. Mira el bloque comentado del")
        print("final de props.conf: hay un ejemplo para un log de acceso clásico.\n")
        print(f"({no_json} líneas leídas, ninguna era JSON)")
        return 1

    # Unimos los campos de todas las líneas: unas peticiones traen campos que
    # otras no, y conviene mapearlos todos.
    campos = {}
    for obj in objetos:
        campos.update(aplanar(obj))

    print(f"He leído {len(objetos)} líneas JSON"
          + (f" ({no_json} no eran JSON y se ignoran)" if no_json else "") + ".\n")
    print(f"Campos de tu aplicación ({len(campos)}):\n")
    for clave in sorted(campos):
        valor = repr(campos[clave])
        print(f"    {clave:28s} ejemplo: {valor[:50]}")

    pares = " ".join(f'"line.{c}" AS {c.replace(".", "_")}' for c in sorted(campos))
    print("\n" + "=" * 70)
    print(f"Pega esto en la stanza [{SOURCETYPE}] de props.conf:\n")
    print(f"FIELDALIAS-campos_app = {pares}")
    print("=" * 70)
    print("\nDespués:  docker compose restart splunk")
    print("Y comprueba en Splunk que ahora salen sin el prefijo:")
    print("    index=mi_servicio | head 1 | table *")
    print("\nOjo: si algún campo tuyo se llama igual que uno del sobre")
    print("(tag, source, attrs) o que un campo interno de Splunk (host, index,")
    print("source, sourcetype), cámbiale el nombre a la derecha del AS para no")
    print("pisarlo. Por ejemplo:  \"line.source\" AS origen_app")
    return 0


if __name__ == "__main__":
    sys.exit(main())
