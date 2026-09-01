# SPL: sacar los datos y exportarlos

Los comandos que de verdad se usan, en orden de uso real: primero mirar qué hay,
luego filtrar, luego agrupar, y al final sacarlo fuera.

Todo lo de aquí está escrito contra el índice `mi_servicio` y los campos que
crea el `props.conf` de este kit (`status`, `uri`, `method`, `contenedor`,
`resultado`, `flujo`, `request_time`). Cambia el nombre del índice y te vale
para el tuyo.

---

## 0. Tres sitios donde escribir SPL, y una regla que los separa

| Dónde | Para qué | El `search` inicial |
|---|---|---|
| La barra de búsqueda de Splunk | explorar, probar | **implícito**, no lo escribes |
| `splunk search "..."` (CLI) | scripts en la propia máquina | **implícito**, no lo escribes |
| API REST (`curl`, `exportar.py`) | automatizar desde fuera | **obligatorio**, o falla |

La regla: **por la API, la búsqueda tiene que empezar por `search` o por una
tubería `|`**. Es el error número uno. Copias del navegador
`index=mi_servicio status>=500`, lo pegas en un `curl`, y te devuelve cero
resultados sin dar ningún error. Tiene que ser
`search index=mi_servicio status>=500`.

(`exportar.py` de este kit te lo añade solo, en `_normaliza()`.)

---

## 1. Reconocer: qué hay en este Splunk

Lo primero que haces al sentarte delante de un Splunk que no es tuyo.

**Qué índices existen y cuánto tienen dentro**

```spl
| eventcount summarize=false index=* index=_*
| stats sum(count) AS eventos by index
| sort - eventos
```

**Qué sourcetypes hay en un índice, y cuándo llegó el último evento**

```spl
| metadata type=sourcetypes index=mi_servicio
| eval ultimo=strftime(lastTime, "%d/%m/%Y %H:%M:%S")
| table sourcetype totalCount ultimo
| sort - totalCount
```

`metadata` no lee los eventos: lee los metadatos de los buckets. Por eso es
instantáneo aunque el índice tenga mil millones de eventos. Igual con
`type=hosts` y `type=sources`.

**Qué máquinas están mandando**

```spl
| metadata type=hosts index=*
| eval visto=strftime(recentTime, "%d/%m %H:%M")
| table host totalCount visto
| sort - recentTime
```

**Qué campos tiene realmente un sourcetype**

```spl
index=mi_servicio sourcetype=mi_servicio:docker
| head 1000
| fieldsummary
| table field count distinct_count values
```

Esto te dice si tus `FIELDALIAS` están funcionando. Si ves `line.status` en vez
de `status`, el alias no se ha aplicado.

**Ver un evento entero, con el sobre y todo**

```spl
index=mi_servicio | head 1 | table *
```

**Cómo está configurado el índice, sin salir de la búsqueda**

```spl
| rest /services/data/indexes
| table title currentDBSizeMB totalEventCount maxTotalDataSizeMB frozenTimePeriodInSecs
| sort - currentDBSizeMB
```

El comando `rest` llama a la API de Splunk desde dentro de SPL. Muy útil:
te ahorra abrir la interfaz para comprobar la configuración.

---

## 2. Filtrar: la parte que va antes de la primera tubería

Esta es la parte que decide si tu búsqueda tarda 2 segundos o 4 minutos.

```spl
index=mi_servicio sourcetype=mi_servicio:docker status>=500 earliest=-1h
```

Todo lo que pongas **antes de la primera `|`** lo resuelve el índice invertido.
Todo lo que pongas después obliga a leer eventos. La diferencia es de dos
órdenes de magnitud.

```spl
✓  index=mi_servicio status>=500 | stats count by uri
✗  index=mi_servicio | where status>=500 | stats count by uri
```

Las dos dan el mismo resultado. La segunda lee todos los eventos del índice.

Cosas que se pueden poner en el filtro base:

```spl
index=mi_servicio uri="/login*"                      comodín
index=mi_servicio (status=500 OR status=502)         booleanos, en MAYÚSCULAS
index=mi_servicio NOT uri="/health"                  negación
index=mi_servicio remote_addr="10.0.0.0/8"           CIDR, funciona aquí mismo
index=mi_servicio status=*                           el campo existe
index=mi_servicio earliest=-24h latest=-1h           ventana de tiempo
index=mi_servicio earliest="10/25/2026:08:00:00"     fecha concreta, formato US
```

Ojo con el CIDR: `remote_addr="10.0.0.0/8"` funciona en el filtro base, pero
`cidrmatch()` es una función de `eval`, y ahí sí necesita `| where`:

```spl
index=mi_servicio | where cidrmatch("10.0.0.0/8", remote_addr)
```

---

## 3. Contar y agrupar

**`stats` — el que usarás el 80% de las veces**

```spl
index=mi_servicio
| stats count AS peticiones,
        dc(remote_addr) AS ips_distintas,
        avg(request_time) AS media,
        max(request_time) AS peor,
        values(method) AS metodos
  by contenedor, resultado
| eval media=round(media*1000, 1)
| sort - peticiones
```

Funciones que se repiten: `count`, `dc` (distintos), `sum`, `avg`, `max`, `min`,
`values` (todos los valores únicos), `list` (todos, con repeticiones y en
orden), `latest`, `earliest`, `perc95`.

**`timechart` — lo mismo, pero contra el tiempo**

```spl
index=mi_servicio
| timechart span=10m count by resultado limit=6
```

`span` fija el ancho del cubo. Sin `span`, Splunk lo elige por ti y cambia según
el rango, lo que en un dashboard hace que la gráfica se deforme sola.
`limit=6` corta a las 6 series mayores y agrupa el resto en `OTHER`
(con `limit=0` no agrupa nada).

**`top` y `rare` — el ranking en una línea**

```spl
index=mi_servicio | top 10 uri by contenedor
index=mi_servicio | rare limit=10 user_agent
```

`rare` es la que importa en un SOC: lo que ocurre una sola vez es casi siempre
lo interesante.

**`chart` — dos dimensiones a la vez**

```spl
index=mi_servicio | chart count over contenedor by resultado
```

`over` es el eje de filas, `by` el de columnas. Sale una tabla cruzada.

**`eventstats` y `streamstats` — agregar sin perder los eventos**

`stats` te deja solo el resumen. `eventstats` añade el resumen a cada evento:

```spl
index=mi_servicio request_time=*
| eventstats avg(request_time) AS media, stdev(request_time) AS desv
| where request_time > media + 3*desv
| table _time contenedor uri request_time media
```

Esa es una detección de anomalías completa en cinco líneas: peticiones a más de
tres desviaciones típicas de la media.

`streamstats` calcula acumulando según avanza, y sirve para "cuántas veces ha
fallado esta IP seguidas":

```spl
index=mi_servicio status=401
| sort 0 _time
| streamstats count AS intentos by remote_addr
| where intentos >= 5
```

---

## 4. Cuando los campos no están

**`spath` — desenvolver un JSON que llegó como cadena**

Es el caso de la vía C (los ficheros `*-json.log` de Docker): tu JSON viaja
dentro del campo `log`.

```spl
index=mi_servicio sourcetype=docker:json
| spath input=log
| table _time container_id status uri
```

**`rex` — sacar campos con una expresión regular, en tiempo de búsqueda**

```spl
index=mi_servicio tipo=texto
| rex field=line "(?<nivel>ERROR|WARN|INFO)\s+(?<modulo>\w+):\s+(?<mensaje>.*)"
| stats count by nivel, modulo
```

`rex` es el laboratorio: pruebas aquí la regex hasta que funciona, y cuando
funciona la mueves a `props.conf` como `EXTRACT-`. Así deja de escribirse en
cada búsqueda y funciona para todo el mundo.

`sed` mode, para tapar datos sensibles en la salida:

```spl
index=mi_servicio
| rex field=_raw mode=sed "s/([0-9]{4})[0-9]{8}([0-9]{4})/\1********\2/g"
```

**`eval` — campos calculados al vuelo**

```spl
index=mi_servicio
| eval hora=strftime(_time, "%d/%m %H:%M:%S"),
       ms=round(request_time*1000, 1),
       familia=substr(tostring(status), 1, 1) . "xx",
       pesado=if(bytes > 1000000, "sí", "no"),
       franja=case(date_hour<6, "madrugada", date_hour<14, "mañana",
                   date_hour<22, "tarde", 1=1, "noche")
| table hora contenedor uri familia ms pesado franja
```

**`lookup` — cruzar con una tabla tuya**

```spl
index=mi_servicio
| lookup ips_conocidas.csv ip AS remote_addr OUTPUT propietario, criticidad
| where isnull(propietario)
| stats count by remote_addr
```

Ahí tienes "IPs que hablan con mi servicio y no están en mi inventario", que es
media hora de trabajo manual convertida en una línea.

---

## 5. Las consultas del servicio web

Las mismas que trae `exportar.py`, para que las tengas sueltas.

```spl
# Volumen total
index=mi_servicio | stats count AS valor

# Errores
index=mi_servicio status>=400 | stats count AS valor

# Contenedores que están enviando ahora mismo
index=mi_servicio | stats dc(contenedor) AS valor

# Latencia media en milisegundos
index=mi_servicio request_time=*
| stats avg(request_time) AS valor
| eval valor=round(valor*1000, 1)

# Actividad por contenedor a lo largo del tiempo
index=mi_servicio | timechart span=10m count by contenedor limit=6

# Cómo termina cada petición
index=mi_servicio | stats count AS valor by resultado | sort - valor

# Rutas más pedidas
index=mi_servicio uri=* | stats count AS valor by uri | sort - valor | head 10

# Los últimos errores, para mirarlos de verdad
index=mi_servicio status>=400
| eval hora=strftime(_time, "%d/%m %H:%M:%S")
| table hora contenedor method uri status remote_addr
| sort - hora
| head 20
```

Tres más que no están en el kit y que vas a querer:

```spl
# Percentil 95 de latencia por ruta: la media miente, el p95 no
index=mi_servicio request_time=*
| stats perc95(request_time) AS p95, count AS n by uri
| where n > 20
| eval p95=round(p95*1000, 1)
| sort - p95

# Errores nuevos: los que aparecen hoy y no aparecieron ayer
index=mi_servicio status>=500 earliest=-48h
| eval dia=if(_time > relative_time(now(), "-24h"), "hoy", "ayer")
| stats dc(dia) AS dias, values(dia) AS cuando, count by uri, status
| where dias=1 AND cuando="hoy"

# Lo que sale por stderr, que casi siempre merece una mirada
index=mi_servicio flujo=stderr
| stats count by contenedor, line
| sort - count
```

---

## 6. Las consultas de endpoints

Si has montado forwarders en máquinas Windows y Linux.

**Ojo con el sourcetype**: si instalaste el forwarder con `renderXml = true`, el
sourcetype no es `WinEventLog:Security` sino `XmlWinEventLog:Security`, y los
campos salen distintos. Compruébalo antes con `| metadata type=sourcetypes`.

```spl
# Fallos de autenticación en Windows, agrupados por origen
index=endpoints EventCode=4625
| stats count AS intentos, dc(Account_Name) AS cuentas,
        min(_time) AS primero, max(_time) AS ultimo
  by host, src_ip
| where intentos >= 5
| eval primero=strftime(primero, "%H:%M:%S"), ultimo=strftime(ultimo, "%H:%M:%S")
| sort - intentos

# Fuerza bruta seguida de un éxito: el patrón que de verdad importa
index=endpoints (EventCode=4625 OR EventCode=4624)
| sort 0 _time
| streamstats count(eval(EventCode=4625)) AS fallos by Account_Name, src_ip
| where EventCode=4624 AND fallos >= 10
| table _time host Account_Name src_ip fallos

# Servicio nuevo instalado (7045): persistencia clásica
index=endpoints EventCode=7045
| table _time host Service_Name Service_File_Name Service_Start_Type

# Sysmon: proceso hijo de un Office
index=endpoints sourcetype=XmlWinEventLog:Microsoft-Windows-Sysmon/Operational EventCode=1
| where match(lower(ParentImage), "(winword|excel|powerpnt|outlook)[.]exe$")
| table _time host User ParentImage Image CommandLine

# Linux: sudo y su
index=endpoints sourcetype=linux_secure ("sudo:" OR "su:")
| rex "(?<usuario>\w+) : TTY=(?<tty>\S+) ; PWD=(?<pwd>\S+) ; USER=(?<destino>\S+) ; COMMAND=(?<comando>.*)"
| table _time host usuario destino comando
```

---

## 7. Salud del propio Splunk

Estas son las que separan a alguien que "sabe buscar" de alguien que administra.

```spl
# Forwarders que han dejado de enviar
index=_internal source=*metrics.log group=tcpin_connections
| stats latest(_time) AS ultimo by hostname
| eval minutos=round((now()-ultimo)/60, 1)
| where minutos > 15
| sort - minutos

# Cuántos datos indexa cada índice al día (control de licencia)
index=_internal source=*license_usage.log type=Usage
| eval GB=b/1024/1024/1024
| timechart span=1d sum(GB) AS GB by idx

# Errores del propio Splunk
index=_internal source=*splunkd.log log_level IN ("ERROR", "WARN")
| stats count by component, log_level
| sort - count

# Búsquedas que se están comiendo la máquina
index=_audit action=search info=completed
| stats sum(total_run_time) AS segundos, count AS veces by user, search_id
| sort - segundos
| head 20

# Eventos que llegaron con la hora mal (el fallo silencioso más común)
index=mi_servicio
| eval desfase=round((_indextime - _time)/60, 1)
| stats avg(desfase) AS medio, max(desfase) AS peor by sourcetype
| where abs(medio) > 5
```

Esa última merece un comentario: `_time` es la hora del evento, `_indextime` la
hora en que Splunk lo escribió. Si difieren mucho, o tienes un `TZ` mal puesto
en `props.conf`, o un forwarder atascado. En los dos casos tus alertas se
disparan tarde y no te enteras.

---

## 8. Exportar

Cinco vías. La que elijas depende de si el destino está dentro o fuera de Splunk.

### 8.1. Desde la interfaz — para una vez

Lanzas la búsqueda, botón **Export** arriba a la derecha. Formatos: CSV, XML,
JSON, y "Raw Events" si la búsqueda no transforma.

El límite que te vas a encontrar: si la búsqueda tiene `stats`, `chart` o
`timechart`, la exportación se corta en **50.000 filas**
(`limits.conf`, `[searchresults] maxresultrows`). No avisa: simplemente el
fichero acaba antes. Para volúmenes mayores, usa la API.

### 8.2. Dentro de Splunk — `outputcsv`, `outputlookup`, `collect`

```spl
index=mi_servicio | stats count by uri | outputcsv informe_rutas
```

Escribe en `$SPLUNK_HOME/var/run/splunk/csv/informe_rutas.csv`. Sirve para
pasarle datos a otra búsqueda con `| inputcsv informe_rutas`.

```spl
index=mi_servicio | stats count by remote_addr
| outputlookup ips_vistas.csv createinapp=true
```

Un *lookup* sí es reutilizable: lo cruzas con `| lookup` desde cualquier
búsqueda. `createinapp=true` lo deja en la app actual en vez de en el directorio
del sistema.

```spl
index=mi_servicio | stats count by uri, status | collect index=resumen
```

`collect` guarda el **resultado** como eventos nuevos en otro índice. Es la
manera de conservar métricas durante dos años sin conservar dos años de logs en
bruto. Se programa como informe cada hora y ya tienes histórico barato.

### 8.3. CLI — para scripts en la propia máquina

```bash
splunk search 'index=mi_servicio | stats count by resultado' \
  -earliest_time -24h -latest_time now \
  -output json -maxout 0 -preview 0 \
  -auth admin:tu_password \
  > salida.json
```

- `-output`: `json`, `csv`, `table`, `raw`, `rawdata`, `auto`
- `-maxout 0`: **imprescindible**. El valor por defecto es **100** eventos, y si
  no lo pones te llevas un fichero truncado sin ningún aviso.
- `-preview 0`: no emitir resultados parciales según van saliendo.
- No escribas el `search` inicial: aquí es implícito. Sí lo escribes si la
  búsqueda empieza por tubería: `splunk search '| metadata type=sourcetypes index=mi_servicio'`.

Meter la contraseña en la línea de comandos la deja en el historial y en
`ps`. Para algo periódico, usa un token: `-auth` acepta también
`splunk search ... -auth ""` con la sesión ya iniciada por `splunk login`.

**Bonus para DFIR**: exportar un bucket entero sin pasar por el motor de
búsqueda, útil cuando quieres llevarte los datos crudos de una investigación:

```bash
splunk cmd exporttool \
  $SPLUNK_DB/mi_servicio/db/db_1730000000_1729900000_12 \
  /tmp/bucket.csv -csv
```

### 8.4. API REST — la que vas a usar de verdad

**Paso 1, la sesión** (solo si no usas token):

```bash
SESION=$(curl -sk https://localhost:8089/services/auth/login \
  -d username=admin -d password="$SPLUNK_PASSWORD" -d output_mode=json \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["sessionKey"])')
```

**Paso 2, la búsqueda en una sola petición** (`export`: Splunk va devolviendo
según produce, no espera a terminar):

```bash
curl -sk https://localhost:8089/services/search/jobs/export \
  -H "Authorization: Splunk $SESION" \
  -d search='search index=mi_servicio | stats count AS n by resultado' \
  -d earliest_time=-24h \
  -d latest_time=now \
  -d output_mode=json \
  -d count=0 \
  > salida.json
```

En JSON la respuesta es **un objeto por línea**, no un array. Cada línea es
`{"preview":false,"result":{...}}`. Por eso `exportar.py` la lee línea a línea.
Si quieres un array de verdad:

```bash
... -d output_mode=json | python3 -c '
import sys, json
print(json.dumps([json.loads(l)["result"] for l in sys.stdin if l.strip() and "result" in l]))
' > salida.json
```

Directo a CSV, que a veces es todo lo que hace falta:

```bash
curl -sk https://localhost:8089/services/search/jobs/export \
  -H "Authorization: Splunk $SESION" \
  -d search='search index=mi_servicio | table _time contenedor uri status' \
  -d earliest_time=-24h -d output_mode=csv -d count=0 \
  > salida.csv
```

`output_mode` acepta: `json`, `json_rows`, `json_cols`, `csv`, `xml`, `atom`,
`raw`. Para una gráfica, `json_cols` te ahorra el trabajo de transponer.

**Búsquedas largas: el trabajo asíncrono.** `export` mantiene la conexión
abierta; para una búsqueda de horas eso no aguanta. Se lanza, se pregunta, se
recoge:

```bash
# lanzar
SID=$(curl -sk https://localhost:8089/services/search/jobs \
  -H "Authorization: Splunk $SESION" \
  -d search='search index=mi_servicio earliest=-30d | stats count by uri' \
  -d output_mode=json | python3 -c 'import sys,json; print(json.load(sys.stdin)["sid"])')

# preguntar si ha terminado
curl -sk "https://localhost:8089/services/search/jobs/$SID" \
  -H "Authorization: Splunk $SESION" -d output_mode=json \
  | python3 -c 'import sys,json; c=json.load(sys.stdin)["entry"][0]["content"]; print(c["dispatchState"], c["doneProgress"])'

# recoger
curl -sk "https://localhost:8089/services/search/jobs/$SID/results" \
  -H "Authorization: Splunk $SESION" \
  -d output_mode=json -d count=0 -d offset=0 \
  > salida.json
```

**El fallo clásico aquí**: en `/results`, `count` vale **100** por defecto.
Mucha gente exporta media tabla y no se da cuenta. `count=0` es "sin límite";
para tablas enormes, pagina con `count=50000` y `offset` creciente.

En Splunk 9 y 10 existe además `/services/search/v2/jobs` (y su
`/v2/jobs/export`), con un manejo más estricto de la cadena de búsqueda. La v1
sigue funcionando; si empiezas de cero, usa la v2.

**Autenticación en producción**: no uses la contraseña de admin. En
**Settings → Tokens** creas un token para un usuario con permisos mínimos, y la
cabecera pasa a ser `-H "Authorization: Bearer $TOKEN"`. No caduca al reiniciar,
se revoca solo y no expone nada.

### 8.5. Programado, sin que nadie lo lance

Un informe guardado que se ejecute solo y escupa el fichero
(`savedsearches.conf`):

```ini
[Informe diario del servicio]
search = index=mi_servicio | stats count AS peticiones, dc(remote_addr) AS ips by contenedor, resultado
dispatch.earliest_time = -24h@h
dispatch.latest_time = now
cron_schedule = 5 7 * * *
enableSched = 1
action.email = 1
action.email.to = tu@correo.com
action.email.format = csv
action.email.sendcsv = 1
```

O el propio `exportar.py` de este kit en un `systemd` timer, que es lo que hace
`make ver`:

```bash
python3 exportar.py --cada 300 --servir
```

---

## 9. Errores que vas a cometer una vez

**Cero resultados y ningún error.** Casi siempre es una de tres: el `search`
inicial que falta en la API; un campo que se llama `line.status` y no `status`
porque falta el `FIELDALIAS`; o el rango de tiempo, que por defecto en la
interfaz son las últimas 24 horas y tus datos son de anteayer.

**El fichero exportado se corta.** `-maxout 100` en el CLI, `count=100` en
`/results`, o `maxresultrows=50000` en la interfaz. Tres límites distintos, los
tres silenciosos.

**La búsqueda tarda una eternidad.** Mira dónde está la primera tubería. Si has
escrito `index=* | search algo`, estás leyendo todo Splunk para tirar el 99%.

**`| table` no ordena.** Ordena `sort`, y `table` solo elige columnas. Si el
resultado sale desordenado, es que falta el `sort`.

**`sort` corta a 10.000 filas** por defecto. `| sort 0 campo` quita el límite —
ese `0` no es un error tipográfico.

**Las comillas.** En SPL, `"comillas dobles"` para valores literales,
`'comillas simples'` para **nombres de campo** con caracteres raros. Es al
revés de casi todos los lenguajes que conoces y muerde a todo el mundo:
`| eval x='line.status'` se refiere al campo, `| eval x="line.status"` es el
texto.

---

## Referencias

- [Export data using the Splunk REST API](https://help.splunk.com/en/splunk-enterprise/search/search-manual/10.4/export-search-results/export-data-using-the-splunk-rest-api)
- [Export data using the CLI](https://help.splunk.com/en/splunk-cloud-platform/search/search-manual/10.5.2605/export-search-results/export-data-using-the-cli)
- [Search Reference (todos los comandos SPL)](https://help.splunk.com/en/splunk-enterprise/search/spl-search-reference)
