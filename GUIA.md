# Splunk desde cero: crear un índice, meter dentro un servicio de Docker y sacar los datos

Esta guía va de tres cosas concretas:

1. **Crear un índice** en un Splunk recién instalado.
2. **Meter dentro los eventos** de un servicio que tienes en `docker-compose`.
3. **Sacar esos datos** en `.json` y `.html` para montar un dashboard.

Todo el kit son veinte ficheros pequeños, y nueve de ellos son de la **vía B**
(el forwarder) y del servicio de ejemplo, que puedes ignorar si tu caso es el
normal. Lo imprescindible son cuatro: el `docker-compose.yml`, el
`indexes.conf`, el `inputs.conf` y `exportar.py`.

```
 mi-servicio (nginx) ──stdout──► driver de logging de Docker
                                          │  HEC · puerto 8088
                                          ▼
                                       SPLUNK      índice: mi_servicio
                                          │
                                          │  API REST · puerto 8089
                                          ▼
                                    exportar.py ──► salida/datos.json
                                                    salida/dashboard.html
                                                    salida/csv/*.csv
```

**Requisitos:** Docker y Docker Compose, unos **4 GB de RAM libres** (Splunk
pide 2 GB solo para él) y Python 3 para el exportador.

---

## Paso 1. Levantar Splunk vacío

```bash
cp .env.example .env      # ajusta la contraseña si quieres
docker compose up -d
docker compose ps         # espera a que splunk ponga (healthy)
```

El primer arranque tarda entre uno y tres minutos: el contenedor se
aprovisiona con Ansible por dentro. Cuando termine:

- **Splunk:** http://localhost:8000 — usuario `admin`, contraseña la del `.env`
- **Tu servicio:** http://localhost:8080

Dos detalles del `docker-compose.yml` que conviene mirar antes de seguir:

```yaml
- SPLUNK_START_ARGS=--accept-license
- SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
```

Desde la versión 10 hacen falta **las dos**. Si falta una, el contenedor
arranca y se queda a medias sin decir gran cosa.

```yaml
volumes:
  - splunk-var:/opt/splunk/var   # los datos indexados
  - splunk-etc:/opt/splunk/etc   # la configuración
```

Sin estos volúmenes, cada `docker compose down` te borra todo.

---

## Paso 2. Crear el índice

Un índice es **dónde viven los datos**. No es una carpeta cualquiera: define la
retención, el tamaño máximo y quién puede ver esos datos. Y esas tres cosas no
se pueden cambiar luego sin reindexar.

Hay tres formas de crearlo. Las tres funcionan; solo una es la buena.

### Forma 1 — desde la interfaz

**Settings → Indexes → New Index**. Le pones el nombre `mi_servicio`, aceptas
el resto de valores por defecto y ya está.

Vale para probar. El problema: ese índice vive dentro del contenedor. El día
que hagas `docker compose down -v`, o que quieras montar lo mismo en otra
máquina, no existe y no hay ni rastro de cómo lo creaste.

### Forma 2 — desde la línea de comandos

```bash
docker compose exec splunk /opt/splunk/bin/splunk add index mi_servicio \
  -auth admin:TU_CONTRASENA
```

Igual de efímero que el anterior, pero al menos se puede meter en un script.

### Forma 3 — en un fichero (la que usa este kit)

El índice está definido en `splunk/apps/mi_indice/default/indexes.conf`, y esa
carpeta se monta dentro de Splunk como una app:

```yaml
volumes:
  - ./splunk/apps/mi_indice:/opt/splunk/etc/apps/mi_indice
```

```ini
[mi_servicio]
homePath   = $SPLUNK_DB/mi_servicio/db
coldPath   = $SPLUNK_DB/mi_servicio/colddb
thawedPath = $SPLUNK_DB/mi_servicio/thaweddb
maxTotalDataSizeMB     = 2048      # 2 GB
frozenTimePeriodInSecs = 2592000   # 30 días
```

El índice se crea solo al arrancar Splunk, está en tu repositorio, se versiona
en Git y se puede llevar a otra máquina tal cual. **Esto es lo que se hace en
producción**, y es exactamente el mismo esfuerzo que las otras dos formas.

**Comprueba que existe:**

```bash
make comprobar
# o a mano:
docker compose exec splunk /opt/splunk/bin/splunk list index -auth admin:TU_CONTRASENA
```

> **Los tres caminos y el nombre.** `homePath` son los datos recientes,
> `coldPath` los antiguos (disco más barato) y `thawedPath` donde se restauran
> los que rescates de un archivo. Cuando se llega a `maxTotalDataSizeMB` **o** a
> `frozenTimePeriodInSecs`, lo más viejo se "congela", y congelar significa
> **borrar** salvo que configures `coldToFrozenDir`.

> **Nunca uses `main`.** Es el índice por defecto: no tiene retención pensada y
> acaba siendo el cajón de sastre donde se mezclan cuatro fuentes. Una vez
> mezcladas, separarlas es reindexar.

---

## Paso 3. Abrir la puerta: el token de HEC

El **HTTP Event Collector** es el puerto 8088 de Splunk. El driver de logging
de Docker habla exactamente eso, así que es lo que hay que tener levantado.

Igual que con el índice, se puede crear desde la interfaz
(**Settings → Data inputs → HTTP Event Collector → New Token**) o en un
fichero. Aquí está en `splunk/apps/mi_indice/default/inputs.conf`:

```ini
[http]
disabled = 0
port = 8088
enableSSL = 1

[http://mi_servicio]
disabled = 0
token = 11112222-3333-4444-5555-666677778888
index = mi_servicio
indexes = mi_servicio          # lista blanca: no puede escribir en otro sitio
sourcetype = mi_servicio:docker
```

**Un token por origen, nunca uno global.** Así puedes revocar el de una
aplicación sin tocar las demás, el índice y el sourcetype quedan forzados desde
el servidor (el cliente no puede mentir) y sabes quién te está gastando la
licencia.

> El token del `inputs.conf` y el `HEC_TOKEN` del `.env` **tienen que ser el
> mismo**. Si cambias uno, cambia el otro.

**Compruébalo a mano:**

```bash
curl -k https://localhost:8088/services/collector/event \
  -H "Authorization: Splunk 11112222-3333-4444-5555-666677778888" \
  -d '{"event":{"prueba":"hola"},"sourcetype":"mi_servicio:docker"}'
# {"text":"Success","code":0}
```

| Respuesta | Qué pasa |
|---|---|
| `{"text":"Success","code":0}` | Todo bien |
| `{"text":"Invalid token","code":4}` | El token no existe o no coincide |
| `{"text":"Incorrect index","code":7}` | El token no tiene ese índice en `indexes =` |
| `{"text":"Invalid data format","code":6}` | El JSON está mal, o falta la clave `event` |
| `Connection refused` | HEC apagado, o el 8088 sin publicar |

---

## Paso 4. Conectar tu servicio

Aquí hay una bifurcación, y depende de **dónde escribe tu servicio**.

### Vía A — tu servicio escribe a stdout (lo normal en Docker)

Si con `docker logs mi-servicio` ves los logs, es esta. Solo hay que añadir un
bloque `logging` al servicio en tu `docker-compose.yml`:

```yaml
services:
  mi-servicio:
    image: loquesea
    logging:
      driver: splunk
      options:
        splunk-url: "https://localhost:8088"
        splunk-token: "11112222-3333-4444-5555-666677778888"
        splunk-index: "mi_servicio"
        splunk-sourcetype: "mi_servicio:docker"
        splunk-insecureskipverify: "true"
        splunk-verify-connection: "false"
        splunk-format: "json"
        tag: "{{.Name}}"
```

**Tres cosas nada obvias:**

1. **`splunk-url` es `localhost`, no `splunk`.** Quien abre la conexión es el
   **demonio de Docker**, que corre en tu máquina, no el contenedor. El nombre
   `splunk` solo existe dentro de la red de Docker, y el demonio no la ve.
2. **El índice tiene que existir antes.** Si no, el driver falla y el
   contenedor no arranca. Por eso el Paso 2 va antes que este.
3. **`docker logs` deja de funcionar** para ese contenedor. Los logs ya no
   están en local: se consultan en Splunk. Es lo que hay.

**Los tres formatos, y cuál elegir:**

| `splunk-format` | Qué llega a Splunk | Cuándo |
|---|---|---|
| `inline` (por defecto) | `{"line":"la línea", "source":"stdout", "tag":"/mi-servicio"}` | No sabes qué formato tiene el log |
| `json` | La línea parseada como JSON, con sus campos. Si no es JSON válido, la manda como texto | **Tu servicio ya escribe JSON** |
| `raw` | La línea tal cual, con el tag delante | Quieres el texto crudo y parsearlo tú en `props.conf` |

Este kit usa `json` y configura nginx para que escriba sus accesos en JSON
(mira `nginx/nginx.conf`). No es un capricho: **si tu servicio escribe JSON,
los campos salen solos en Splunk y te ahorras la mitad de `props.conf`**. Es la
mejor media hora que puedes invertir antes de conectar nada a un SIEM.

> **Regalo del driver:** manda la hora del log de Docker como metadato de HEC.
> Eso significa que Splunk **no tiene que adivinar la marca de tiempo**: ni
> `TIME_PREFIX`, ni `TIME_FORMAT`, ni problemas de zona horaria. Es la ventaja
> grande de esta vía frente a leer ficheros.


### Lo que llega de verdad: el sobre

Esto no es obvio y hace perder tardes enteras. **El driver no manda tu línea
tal cual: la envuelve en un sobre** con cuatro campos:

```json
{
  "tag":    "/mi-servicio",     ← el nombre del contenedor
  "source": "stdout",           ← stdout o stderr
  "attrs":  { },                ← labels y variables de entorno, si los declaraste
  "line":   { ...tu log... }    ← TU log va AQUÍ DENTRO
}
```

Con `splunk-format=json`, `line` es un **objeto** con tus campos. Con `inline`
es una **cadena** con la línea entera. Con `raw` no hay sobre, pero el tag va
pegado delante del mensaje, lo que rompe el JSON si tu app escribe JSON.

**La consecuencia práctica:** en Splunk tus campos no se llaman `status` ni
`uri`, sino **`line.status`** y **`line.uri`**. Y esto:

```spl
index=mi_servicio status>=400
```

devuelve **cero resultados y ningún error**. Es el fallo silencioso más común
al conectar un contenedor.

**La solución**, ya puesta en `props.conf`: un `FIELDALIAS` que sube tus campos
al primer nivel.

```ini
FIELDALIAS-campos_app = "line.status" AS status "line.uri" AS uri "line.method" AS method ...
```

Como los nombres dependen de tu aplicación, hay un script que te lo escribe.
Le das una muestra de tus logs y te devuelve la línea lista para pegar:

```bash
docker compose logs --no-log-prefix --tail 50 mi-servicio \
  | python3 scripts/02-alias-para-mi-app.py
```

Funciona también con JSON anidado: si tu app escribe `{"http":{"status":200}}`,
te propone `"line.http.status" AS http_status`.

Después de tocar `props.conf`: `docker compose restart splunk`.

### Cómo se ve un evento ya indexado

Con el ejemplo de nginx, esto es lo que tienes en Splunk después de una
petición. Búscalo tú con `index=mi_servicio | head 1`:

| Campo | Valor | De dónde sale |
|---|---|---|
| `_time` | la hora de la petición | La pone el driver desde el log de Docker |
| `host` | el nombre de tu máquina | Metadato de HEC |
| `source` | `docker` | Del `splunk-source` del compose |
| `sourcetype` | `mi_servicio:docker` | Del `splunk-sourcetype` del compose |
| `index` | `mi_servicio` | Del `splunk-index` del compose |
| `tag` | `/mi-servicio` | El sobre del driver |
| `contenedor` | `mi-servicio` | `EVAL` de props.conf: le quita la barra |
| `flujo` | `stdout` | `EVAL` sobre el `source` del sobre |
| `status` | `404` | `FIELDALIAS` desde `line.status` |
| `uri` | `/nope` | `FIELDALIAS` desde `line.uri` |
| `method`, `remote_addr`, `bytes`, `request_time` | … | Igual, por alias |
| `resultado` | `error_cliente` | `EVAL` que clasifica el `status` |
| `tipo` | `acceso` | `EVAL`: `texto` si la línea no era JSON |

Fíjate en que `status` llega como **número**, no como cadena: por eso funcionan
`status>=400` y `avg(request_time)` sin convertir nada. Eso es porque el
`log_format` de nginx pone `$status` sin comillas. Merece la pena cuidarlo en
tu aplicación.

### Las diez búsquedas de una web

```spl
# 1. ¿Está llegando algo?
index=mi_servicio | stats count by sourcetype

# 2. Un evento entero, con el sobre y todo (para ver qué campos tienes)
index=mi_servicio | head 1

# 3. Tráfico en el tiempo, por contenedor
index=mi_servicio | timechart span=5m count by contenedor

# 4. Cómo termina cada petición
index=mi_servicio | stats count by resultado

# 5. Los errores, los últimos primero
index=mi_servicio status>=400
| table _time contenedor method uri status remote_addr | sort - _time

# 6. Las rutas que más fallan (no las que más se piden: las que más fallan)
index=mi_servicio status>=400 | top limit=10 uri

# 7. Latencia: la media miente, mira los percentiles
index=mi_servicio | stats avg(request_time) AS media
    perc95(request_time) AS p95 perc99(request_time) AS p99 by uri
| sort - p95

# 8. Quién genera más errores
index=mi_servicio status>=400 | stats count dc(uri) AS rutas by remote_addr | sort - count

# 9. Lo que la aplicación escribe por stderr (arranques, trazas, pánicos)
index=mi_servicio flujo=stderr | table _time contenedor line

# 10. Un pico de errores comparado con lo normal
index=mi_servicio | bin _time span=5m
| stats count(eval(status>=500)) AS errores by _time
| eventstats avg(errores) AS media stdev(errores) AS desv
| eval z=round((errores-media)/desv, 2) | where z > 3
```

La 2 es la que más vas a usar al principio: te enseña el evento tal cual, con
el sobre, y así ves exactamente cómo se llama cada campo.


### Vía B — tu servicio escribe a ficheros

Si los logs van a un fichero dentro del contenedor o a un volumen, el driver no
sirve: ese solo recoge lo que sale por consola. Aquí hace falta un **Universal
Forwarder**: un agente ligero (unos 100 MB de RAM) que lee ficheros y los manda
al puerto 9997.

Está montado en `docker-compose.ficheros.yml`:

```bash
docker compose -f docker-compose.yml -f docker-compose.ficheros.yml up -d
```

Lo que cambia: el servicio escribe en un volumen compartido, y el forwarder lo
lee **en solo lectura** (`:ro` — un agente de recolección no debe poder tocar
la evidencia que recoge). En `uf/apps/mi_uf/default/inputs.conf`:

```ini
[monitor:///var/log/mi-servicio/]
disabled = 0
index = mi_servicio
sourcetype = mi_servicio:docker
whitelist = \.log$
```

**Ventaja de esta vía:** si Splunk se cae, los ficheros siguen en disco y el
forwarder los recupera al volver. Con HEC, lo que pase mientras Splunk no está,
se pierde.

**Inconveniente:** un agente más que mantener, y la hora hay que sacarla del
texto (con lo que vuelven `TIME_FORMAT` y las zonas horarias).

### Vía C — recoger los ficheros que escribe Docker

Existe una tercera vía, y es la respuesta literal a "¿qué fichero recojo?".
Cuando **no** pones ningún `logging`, Docker usa su driver por defecto,
`json-file`, y guarda el stdout y el stderr de cada contenedor aquí:

```
/var/lib/docker/containers/<id-del-contenedor>/<id-del-contenedor>-json.log
```

Cada línea es un JSON con tres campos:

```json
{"log":"la línea que escribió tu app\n","stream":"stdout","time":"2026-08-25T10:14:22.123456789Z"}
```

Fíjate en que **tu log va dentro del campo `log`**, envuelto. Eso significa que
si tu aplicación escribe JSON, en Splunk te llega un JSON metido dentro de otro
JSON como cadena de texto, y hay que desenvolverlo (`spath` sobre el campo
`log`, o un `SEDCMD`). Es feo, y es una de las razones para no ir por aquí.

El input, en el forwarder:

```ini
[monitor:///var/lib/docker/containers/*/*-json.log]
disabled = 0
index = mi_servicio
sourcetype = docker:json
# El quinto trozo de la ruta es el ID del contenedor: /var/lib/docker/containers/<ID>/...
host_segment = 5
```

Y el parseo, en el indexador (ya está puesto en `props.conf`):

```ini
[docker:json]
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)
KV_MODE = json
TIME_PREFIX = "time":"
TIME_FORMAT = %Y-%m-%dT%H:%M:%S.%9NZ    # RFC3339 con nanosegundos
```

**Cuatro pegas, y son gordas:**

1. **El `host` es el ID del contenedor, un hash**, no `mi-servicio`. Ese ID
   cambia cada vez que recreas el contenedor, así que un dashboard por host se
   te rompe en cada despliegue. Hay que enriquecerlo con una lookup, y
   mantenerla.
2. **En Docker Desktop (Windows y macOS) ese directorio no existe en tu
   máquina**: vive dentro de la máquina virtual de WSL2 o de LinuxKit. Llegar
   ahí es posible pero frágil y cambia entre versiones. En la práctica, por
   aquí no vas.
3. **Docker lo desaconseja explícitamente.** Su documentación dice que esos
   ficheros están pensados para uso exclusivo del demonio y que tocarlos con
   herramientas externas puede provocar comportamientos inesperados.
4. **Si alguien cambia el driver a `local`** (formato binario) o a `journald`,
   los ficheros dejan de ser texto y el `monitor://` deja de servir.

Se usa cuando no te queda otra: máquinas Linux donde no puedes tocar el compose
de cada servicio, pero sí instalar un agente. En ese caso se monta
`/var/lib/docker/containers` en el forwarder **en solo lectura**:

```yaml
volumes:
  - /var/lib/docker/containers:/var/lib/docker/containers:ro
```

### Cómo aplicarlo a TU docker-compose

No hace falta que muevas tu proyecto aquí. Dos opciones:

**Opción 1 — un fichero extra en tu proyecto.** Crea `compose.splunk.yml` junto
a tu `docker-compose.yml`, con solo el bloque de logging:

```yaml
services:
  tu-servicio:
    logging:
      driver: splunk
      options:
        splunk-url: "https://localhost:8088"
        splunk-token: "11112222-3333-4444-5555-666677778888"
        splunk-index: "mi_servicio"
        splunk-sourcetype: "mi_servicio:docker"
        splunk-insecureskipverify: "true"
        splunk-verify-connection: "false"
        splunk-format: "json"
        tag: "{{.Name}}"
```

y arranca con los dos:

```bash
docker compose -f docker-compose.yml -f compose.splunk.yml up -d
```

Así tu compose original se queda intacto y puedes quitar Splunk cuando quieras.

**Opción 2 — un solo servicio.** Si solo quieres uno concreto, añádele el
bloque `logging` directamente y ya.

> **Todos los contenedores de golpe:** se puede configurar el driver por
> defecto del demonio en `/etc/docker/daemon.json`, y entonces TODO lo que
> corra en esa máquina va a Splunk. Es potente y es peligroso: si Splunk no
> responde, no arranca nada. En una máquina de trabajo, mejor servicio por
> servicio.

---

## Paso 5. Comprobar que están llegando

Genera algo de tráfico y mira:

```bash
make trafico       # 160 peticiones al servicio de ejemplo
make comprobar     # índice + token + cuántos eventos hay
```

O en Splunk (http://localhost:8000), con el rango en "Últimas 24 horas":

```spl
index=mi_servicio
```

Si sale vacío, en este orden:

```bash
# 1. ¿el contenedor está arrancando bien?
docker compose logs mi-servicio | tail -20

# 2. ¿el índice existe de verdad?
docker compose exec splunk /opt/splunk/bin/splunk list index -auth admin:CLAVE

# 3. ¿qué dice Splunk de sí mismo?
docker compose exec -T splunk /opt/splunk/bin/splunk search \
  'index=_internal log_level=ERROR | stats count by component' -auth admin:CLAVE
```

El índice `_internal` son los logs del propio Splunk. Cuando algo no llega, la
respuesta suele estar ahí.

---

## Paso 6. Darles forma

Con los datos dentro, `props.conf` decide **cómo se leen**. Fíjate en lo corto
que es el de este kit (`splunk/apps/mi_indice/default/props.conf`):

```ini
[mi_servicio:docker]
SHOULD_LINEMERGE = false
KV_MODE = json

EVAL-contenedor = replace(coalesce(tag, "desconocido"), "^/", "")
EVAL-resultado  = case(status<300, "ok", status<400, "redireccion",
                       status<500, "error_cliente", status>=500, "error_servidor",
                       1=1, "sin_status")
```

Y ya está. No hay `TIME_PREFIX`, ni `TIME_FORMAT`, ni `TZ`, ni `LINE_BREAKER`,
porque las dos decisiones de antes (JSON en el origen + HEC) le quitaron a
Splunk todo lo que tendría que adivinar.

Los `EVAL-` son **campos calculados**: se aplican al buscar, no ocupan espacio y
los puedes cambiar cuando quieras — el cambio afecta también a los datos ya
indexados. `resultado` te deja escribir `resultado=error_servidor` en vez de
`status>=500` cada vez.

Después de tocar `props.conf`:

```bash
docker compose restart splunk
```

**Si tu servicio escribe texto plano en vez de JSON**, ahí sí hay trabajo: hay
un ejemplo comentado al final de ese mismo fichero, con la regex y los
atributos de tiempo que harían falta.

---

## Paso 7. Sacar los datos

Splunk escucha en el **8089** para la API REST. Todo lo que se puede hacer en
la interfaz se puede hacer por ahí.

La forma cruda, para que veas que no hay magia:

```bash
curl -k https://localhost:8089/services/search/jobs/export \
  -u admin:TU_CONTRASENA \
  -d search='search index=mi_servicio | stats count by resultado' \
  -d earliest_time=-24h \
  -d output_mode=json
```

Devuelve **un JSON por línea**, no un array:

```json
{"preview":false,"offset":0,"result":{"resultado":"ok","count":"120"}}
{"preview":false,"offset":1,"result":{"resultado":"error_cliente","count":"40"}}
```

Cambiando `output_mode` cambias el formato: `json`, `json_rows`, `json_cols`,
`csv`, `xml`, `raw`.

> **Los tres errores garantizados de esta API.** El SPL tiene que empezar por
> `search` o por `|` — en la interfaz ese `search` es implícito, en la API no, y
> si lo olvidas no falla: devuelve cero resultados. `count=0` significa "sin
> límite", no "ninguno". Y el certificado es autofirmado, así que `curl -k`
> mientras no despliegues la CA.

### El script del kit

`exportar.py` hace eso mismo con todas las consultas de golpe:

```bash
make exportar
# equivale a:  SPLUNK_PASSWORD=... python3 exportar.py
```

Deja tres cosas en `salida/`:

```
salida/datos.json         todos los paneles en un JSON
salida/dashboard.html     el dashboard, con los datos DENTRO
salida/csv/<id>.csv       un CSV por consulta
```

**Para cambiar qué se exporta**, edita la lista `CONSULTAS` que hay al principio
de `exportar.py`. Un panel es un diccionario:

```python
{
    "id": "codigos_http",
    "titulo": "Códigos de respuesta",
    "tipo": "barras",                       # indicador | barras | serie | tabla
    "spl": "index=mi_servicio | stats count AS valor by status | sort - valor",
    "campo_etiqueta": "status",
    "campo_valor": "valor",
},
```

**Con un token en vez de la contraseña** (lo correcto para algo automatizado):
créalo en Splunk (**Settings → Tokens → New Token**) y exporta la variable:

```bash
SPLUNK_TOKEN=eyJraWQiOi... python3 exportar.py
```

---

## Paso 8. El dashboard

```bash
make ver     # exporta cada 60 s y lo sirve
```

y abres **http://localhost:8081/dashboard.html**.

O sin servidor: `make exportar` y doble clic en `salida/dashboard.html`. **Los
datos van incrustados dentro del propio fichero**, así que puedes copiarlo,
adjuntarlo en un correo o subirlo a tu web y sigue funcionando sin Splunk
delante y sin conexión. Para enseñar un proyecto sin dar acceso a tu Splunk, es
justo lo que quieres.

El aspecto sale de `plantilla.html`. Si quieres tocarlo, dos cosas que están
puestas a propósito y conviene no romper:

- **La paleta está validada para daltonismo** (protanopía y deuteranopía), no
  elegida a ojo. Y cada gráfico tiene un botón "ver datos" que enseña la tabla:
  la información nunca depende solo del color.
- **Los estados llevan punto de color *y* texto.** Un semáforo sin etiquetas es
  inaccesible, y además ilegible en una captura en blanco y negro.

### ¿Y el dashboard de dentro de Splunk?

También puedes hacerlo ahí: buscas, le das a **Save As → Dashboard Panel**, y
ya tienes un dashboard nativo. Cuándo usar cada uno:

| | Dashboard de Splunk | Tu `dashboard.html` |
|---|---|---|
| Datos | En vivo cada vez que se abre | Congelados en cada exportación |
| Quién lo ve | Quien tenga cuenta en Splunk | Cualquiera con el fichero |
| Investigar | Pinchas y sigues (drilldown) | Lo que programes |
| Publicar fuera | No | Sí |

---

## Problemas típicos

| Síntoma | Causa casi seguro |
|---|---|
| El contenedor del servicio no arranca | El índice no existe, o Splunk aún no estaba listo. Arranca Splunk primero |
| `Invalid token` | El token del `.env` y el de `inputs.conf` no coinciden |
| `Incorrect index` | El token no tiene ese índice en su lista `indexes =` |
| Llegan eventos pero sin campos | El sourcetype no es el que crees. Míralo: `index=mi_servicio \| stats count by sourcetype` |
| Los campos no salen aunque el JSON es bueno | Falta `KV_MODE = json`, o tocaste `props.conf` y no reiniciaste Splunk |
| Todo aparece a la misma hora | Splunk no supo leer la marca de tiempo y usó la de indexación |
| Horas desplazadas | Zona horaria: falta `TZ` en `props.conf` (solo pasa leyendo ficheros, no con HEC) |
| Splunk no arranca | `SPLUNK_PASSWORD` de menos de 8 caracteres, falta una de las dos variables de licencia, o poca RAM |
| `docker logs` ya no muestra nada | Es lo esperado con el driver de Splunk: los logs están en Splunk |

Y el comodín, que resuelve cualquier discusión sobre configuración:

```bash
docker compose exec splunk /opt/splunk/bin/splunk btool props list mi_servicio:docker --debug
docker compose exec splunk /opt/splunk/bin/splunk btool inputs list --debug
```

`--debug` pone delante de cada línea **el fichero de donde sale ese valor**.

---

## Qué hacer después

- **Añade un segundo servicio** al mismo índice, con otro `sourcetype`. Cuando
  tengas dos, ya puedes cruzarlos, y eso es lo que separa un SIEM de un visor
  de logs.
- **Separa índices por retención**: los logs de aplicación duran días, los de
  autenticación meses. Un índice por tiempo de vida, no por equipo ni por
  cliente.
- **Filtra el ruido antes de indexarlo.** Los healthchecks suelen ser el 25% del
  volumen y no aportan nada: se tiran con un `TRANSFORMS-` a `nullQueue`, y cada
  GB que no indexas es licencia que no gastas.
- **Monta una alerta**: una búsqueda guardada con `cron_schedule` que avise
  cuando los `error_servidor` pasen de X en cinco minutos.

Cuando quieras el siguiente escalón —varias fuentes, normalización de campos,
detecciones mapeadas a MITRE ATT&CK, dashboards nativos— eso es el otro
repositorio, el `splunk-soc-lab`.

---

## Licencia de Splunk, para que no te pille

Las imágenes arrancan con una **Trial de 60 días**: 500 MB al día, con
búsquedas programadas y alertas. Al caducar pasa a **Free**, que sigue
indexando 500 MB/día pero **pierde las alertas programadas y el control de
usuarios**. Para un laboratorio basta con recrear el contenedor. Y con este
kit no te vas a acercar al límite: nginx a este ritmo genera unos pocos MB al
día.
