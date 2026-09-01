# Del índice al fichero

> Los comandos SPL que de verdad se usan, en el orden en que se usan: primero mirar qué hay, luego filtrar, luego agrupar, y al final sacarlo fuera de Splunk.

**Índice de ejemplo:** `mi_servicio` | **Entornos:** `Splunk Enterprise 9 y 10` | **Estado:** `Los curl están probados`

---

## 00 // TRES SITIOS DONDE ESCRIBIR SPL

Y una regla que los separa, responsable de la mitad de los "no me devuelve nada".

| Dónde | Para qué | El `search` inicial |
| :--- | :--- | :--- |
| La barra de búsqueda | explorar, probar | **implícito**, no lo escribes |
| `splunk search "..."` | scripts en la propia máquina | **implícito**, no lo escribes |
| API REST (`curl`, Python) | automatizar desde fuera | **obligatorio**, o falla |

> **OJO:** Por la API, la búsqueda tiene que empezar por `search` o por una tubería `|`. Copias del navegador `index=mi_servicio status>=500`, lo pegas en un `curl`, y te devuelve cero resultados. Tiene que ser `search index=mi_servicio status>=500`.

## 01 // RECONOCER: QUÉ HAY EN ESTE SPLUNK

Lo primero que haces al sentarte delante de un Splunk que no es tuyo.

### ▾ Qué índices existen y cuánto tienen dentro
```spl
| eventcount summarize=false index=* index=_*
| stats sum(count) AS eventos by index
| sort - eventos
```

### ▾ Qué sourcetypes hay, y cuándo llegó el último evento
```spl
| metadata type=sourcetypes index=mi_servicio
| eval ultimo=strftime(lastTime, "%d/%m/%Y %H:%M:%S")
| table sourcetype totalCount ultimo
| sort - totalCount
```
`metadata` no lee los eventos: lee los metadatos de los buckets. Por eso es instantáneo aunque el índice tenga mil millones de eventos. Igual con `type=hosts` y `type=sources`.

### ▾ Qué campos tiene realmente un sourcetype
```spl
index=mi_servicio sourcetype=mi_servicio:docker
| head 1000
| fieldsummary
| table field count distinct_count values
```
Esto te dice si tus `FIELDALIAS` están funcionando. Si ves `line.status` en vez de `status`, el alias no se ha aplicado.

### ▾ La configuración del índice, sin salir de la búsqueda
```spl
| rest /services/data/indexes
| table title currentDBSizeMB totalEventCount maxTotalDataSizeMB frozenTimePeriodInSecs
| sort - currentDBSizeMB
```
El comando `rest` llama a la API de Splunk desde dentro de SPL: te ahorra abrir la interfaz para comprobar la configuración.

## 02 // FILTRAR: LO QUE VA ANTES DE LA PRIMERA TUBERÍA

Esta es la parte que decide si tu búsqueda tarda dos segundos o cuatro minutos. Todo lo que pongas **antes de la primera `|`** lo resuelve el índice invertido. Todo lo que pongas después obliga a leer eventos.

✔️ **EL ÍNDICE HACE EL TRABAJO**
Filtra en el índice invertido y solo lee los eventos que importan.
```spl
index=mi_servicio status>=500
| stats count by uri
```

❌ **LEE TODO Y TIRA EL 99%**
Mismo resultado, dos órdenes de magnitud más lento.
```spl
index=mi_servicio
| where status>=500
| stats count by uri
```

### ▾ Lo que sí se puede poner en el filtro base
```spl
index=mi_servicio uri="/login*"                  # comodín
index=mi_servicio (status=500 OR status=502)     # booleanos, en MAYÚSCULAS
index=mi_servicio NOT uri="/health"              # negación
index=mi_servicio remote_addr="10.0.0.0/8"       # CIDR, funciona aquí mismo
index=mi_servicio status=*                       # el campo existe
index=mi_servicio earliest=-24h latest=-1h       # ventana de tiempo
index=mi_servicio earliest="10/25/2026:08:00:00" # fecha concreta, formato US
```

> **OJO CON EL CIDR:** `remote_addr="10.0.0.0/8"` funciona en el filtro base, pero `cidrmatch()` es una función de `eval`, y ahí sí necesita `| where cidrmatch("10.0.0.0/8", remote_addr)`.

## 03 // CONTAR Y AGRUPAR

### ▾ stats — el que usarás el 80% de las veces
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
Funciones que se repiten: `count`, `dc` (distintos), `sum`, `avg`, `max`, `min`, `values` (valores únicos), `list` (todos, con repeticiones), `latest`, `earliest`, `perc95`.

### ▾ timechart — lo mismo, contra el tiempo
```spl
index=mi_servicio
| timechart span=10m count by resultado limit=6
```
`span` fija el ancho del cubo. Sin él, Splunk lo elige por ti y cambia según el rango, lo que en un dashboard hace que la gráfica se deforme sola. `limit=6` corta a las seis series mayores y agrupa el resto en `OTHER`.

### ▾ top y rare — el ranking en una línea
```spl
index=mi_servicio | top 10 uri by contenedor
index=mi_servicio | rare limit=10 user_agent
```
`rare` es la que importa en un SOC: lo que ocurre una sola vez es casi siempre lo interesante.

### ▾ eventstats — agregar sin perder los eventos
`stats` te deja solo el resumen. `eventstats` añade el resumen a cada evento, y con eso tienes una detección de anomalías completa en cinco líneas:

**Peticiones a más de tres desviaciones típicas de la media:**
```spl
index=mi_servicio request_time=*
| eventstats avg(request_time) AS media, stdev(request_time) AS desv
| where request_time > media + 3*desv
| table _time contenedor uri request_time media
```

### ▾ streamstats — acumular según avanza
**IPs con cinco o más fallos seguidos:**
```spl
index=mi_servicio status=401
| sort 0 _time
| streamstats count AS intentos by remote_addr
| where intentos >= 5
```

## 04 // CUANDO LOS CAMPOS NO ESTÁN

### ▾ spath — desenvolver un JSON que llegó como cadena
El caso de los ficheros `*-json.log` de Docker: tu JSON viaja dentro del campo `log`.
```spl
index=mi_servicio sourcetype=docker:json
| spath input=log
| table _time container_id status uri
```

### ▾ rex — sacar campos con una regex, en tiempo de búsqueda
```spl
index=mi_servicio tipo=texto
| rex field=line "(?<nivel>ERROR|WARN|INFO)\s+(?<modulo>\w+):\s+(?<mensaje>.*)"
| stats count by nivel, modulo
```
`rex` es el laboratorio: pruebas aquí la regex hasta que funciona, y cuando funciona la mueves a `props.conf` como `EXTRACT-`. Así deja de escribirse en cada búsqueda y funciona para todo el mundo.

**Modo sed, para tapar datos sensibles en la salida:**
```spl
index=mi_servicio
| rex field=_raw mode=sed "s/([0-9]{4})[0-9]{8}([0-9]{4})/\1********\2/g"
```

### ▾ eval — campos calculados al vuelo
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

### ▾ lookup — cruzar con una tabla tuya
**IPs que hablan con mi servicio y no están en mi inventario:**
```spl
index=mi_servicio
| lookup ips_conocidas.csv ip AS remote_addr OUTPUT propietario, criticidad
| where isnull(propietario)
| stats count by remote_addr
```
Media hora de trabajo manual convertida en una línea.

## 05 // LAS CONSULTAS DEL SERVICIO WEB

Las mismas que trae `exportar.py` del kit, para tenerlas sueltas.

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

### ▾ Tres más que no están en el kit y vas a querer

**Percentil 95 por ruta: la media miente, el p95 no:**
```spl
index=mi_servicio request_time=*
| stats perc95(request_time) AS p95, count AS n by uri
| where n > 20
| eval p95=round(p95*1000, 1)
| sort - p95
```

**Errores nuevos: los que aparecen hoy y no aparecieron ayer:**
```spl
index=mi_servicio status>=500 earliest=-48h
| eval dia=if(_time > relative_time(now(), "-24h"), "hoy", "ayer")
| stats dc(dia) AS dias, values(dia) AS cuando, count by uri, status
| where dias=1 AND cuando="hoy"
```

**Lo que sale por stderr, que casi siempre merece una mirada:**
```spl
index=mi_servicio flujo=stderr
| stats count by contenedor, line
| sort - count
```

## 06 // LAS CONSULTAS DE ENDPOINTS

> **OJO CON EL SOURCETYPE:** Si instalaste el forwarder con `renderXml = true`, el sourcetype no es `WinEventLog:Security` sino `XmlWinEventLog:Security`, y los campos salen distintos. Compruébalo antes con `| metadata type=sourcetypes`.

**Fallos de autenticación en Windows, agrupados por origen:**
```spl
index=endpoints EventCode=4625
| stats count AS intentos, dc(Account_Name) AS cuentas,
        min(_time) AS primero, max(_time) AS ultimo
  by host, src_ip
| where intentos >= 5
| eval primero=strftime(primero, "%H:%M:%S"), ultimo=strftime(ultimo, "%H:%M:%S")
| sort - intentos
```

**Fuerza bruta seguida de un éxito: el patrón que de verdad importa:**
```spl
index=endpoints (EventCode=4625 OR EventCode=4624)
| sort 0 _time
| streamstats count(eval(EventCode=4625)) AS fallos by Account_Name, src_ip
| where EventCode=4624 AND fallos >= 10
| table _time host Account_Name src_ip fallos
```

**Servicio nuevo instalado (7045): persistencia clásica:**
```spl
index=endpoints EventCode=7045
| table _time host Service_Name Service_File_Name Service_Start_Type
```

**Sysmon: proceso hijo de un Office:**
```spl
index=endpoints sourcetype=XmlWinEventLog:Microsoft-Windows-Sysmon/Operational EventCode=1
| where match(lower(ParentImage), "(winword|excel|powerpnt|outlook)[.]exe$")
| table _time host User ParentImage Image CommandLine
```

**Linux: sudo y su:**
```spl
index=endpoints sourcetype=linux_secure ("sudo:" OR "su:")
| rex "(?<usuario>\w+) : TTY=(?<tty>\S+) ; PWD=(?<pwd>\S+) ; USER=(?<destino>\S+) ; COMMAND=(?<comando>.*)"
| table _time host usuario destino comando
```

## 07 // LA SALUD DEL PROPIO SPLUNK

Estas separan a alguien que sabe buscar de alguien que administra.

**Forwarders que han dejado de enviar:**
```spl
index=_internal source=*metrics.log group=tcpin_connections
| stats latest(_time) AS ultimo by hostname
| eval minutos=round((now()-ultimo)/60, 1)
| where minutos > 15
| sort - minutos
```

**Cuántos datos indexa cada índice al día (control de licencia):**
```spl
index=_internal source=*license_usage.log type=Usage
| eval GB=b/1024/1024/1024
| timechart span=1d sum(GB) AS GB by idx
```

**Errores del propio Splunk:**
```spl
index=_internal source=*splunkd.log log_level IN ("ERROR", "WARN")
| stats count by component, log_level
| sort - count
```

**Eventos que llegaron con la hora mal — el fallo silencioso más común:**
```spl
index=mi_servicio
| eval desfase=round((_indextime - _time)/60, 1)
| stats avg(desfase) AS medio, max(desfase) AS peor by sourcetype
| where abs(medio) > 5
```
`_time` es la hora del evento; `_indextime`, la hora en que Splunk lo escribió. Si difieren mucho, o tienes un `TZ` mal puesto en `props.conf`, o un forwarder atascado. En los dos casos tus alertas se disparan tarde y no te enteras.

## 08 // EXPORTAR

Cinco vías. La que elijas depende de si el destino está dentro o fuera de Splunk.

### ▾ Los tres límites que cortan tu fichero sin avisar
| Vía | Corta en | Se quita con |
| :--- | :--- | :--- |
| Interfaz, búsqueda con `stats` | `50.000 filas` | `limits.conf` → `maxresultrows` |
| CLI `splunk search` | `100 eventos` | `-maxout 0` |
| API, `/jobs/<sid>/results` | `100 filas` | `count=0` |

Ninguno de los tres da error. El fichero simplemente acaba antes.

### ▾ 8.1 · Interfaz — para una vez
Lanzas la búsqueda, botón **Export** arriba a la derecha. CSV, XML, JSON, y "Raw Events" si la búsqueda no transforma. Para volúmenes mayores, usa la API.

### ▾ 8.2 · Dentro de Splunk — outputcsv, outputlookup, collect
```spl
index=mi_servicio | stats count by uri | outputcsv informe_rutas

index=mi_servicio | stats count by remote_addr
| outputlookup ips_vistas.csv createinapp=true

index=mi_servicio | stats count by uri, status | collect index=resumen
```
- `outputcsv` escribe en `$SPLUNK_HOME/var/run/splunk/csv/`, y lo recuperas con `| inputcsv`.
- `outputlookup` sí es reutilizable: lo cruzas con `| lookup` desde cualquier búsqueda.
- `collect` guarda el **resultado** como eventos nuevos en otro índice. Es la manera de conservar métricas dos años sin conservar dos años de logs en bruto.

### ▾ 8.3 · CLI — para scripts en la propia máquina
```bash
splunk search 'index=mi_servicio | stats count by resultado' \
  -earliest_time -24h -latest_time now \
  -output json -maxout 0 -preview 0 \
  -auth admin:tu_password \
  > salida.json
```
- `-output`: `json`, `csv`, `table`, `raw`, `rawdata`, `auto`.
- `-maxout 0` es imprescindible: por defecto son **100** eventos.
- Aquí el `search` inicial es implícito. Sí lo escribes si la búsqueda empieza por tubería.

### ▾ 8.4 · API REST — la que vas a usar de verdad

**Paso 1 · la sesión**
```bash
SESION=$(curl -sk https://localhost:8089/services/auth/login \
  -d username=admin -d password="$SPLUNK_PASSWORD" -d output_mode=json \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["sessionKey"])')
```

**Paso 2 · la búsqueda, en una sola petición**
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
En JSON la respuesta es **un objeto por línea**, no un array. Cada línea es `{"preview":false,"result":{...}}`. Si quieres un array de verdad:
```bash
... -d output_mode=json | python3 -c '
import sys, json
print(json.dumps([json.loads(l)["result"] for l in sys.stdin if l.strip() and "result" in l]))
' > salida.json
```
`output_mode` acepta `json`, `json_rows`, `json_cols`, `csv`, `xml`, `atom` y `raw`. Para una gráfica, `json_cols` te ahorra transponer.

**Búsquedas largas: el trabajo asíncrono**
`export` mantiene la conexión abierta; para una búsqueda de horas eso no aguanta. Se lanza, se pregunta, se recoge.
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

# recoger — sin count=0 te llevas solo 100 filas
curl -sk "https://localhost:8089/services/search/jobs/$SID/results" \
  -H "Authorization: Splunk $SESION" \
  -d output_mode=json -d count=0 -d offset=0 \
  > salida.json
```

> **EN PRODUCCIÓN:** No uses la contraseña de admin. En **Settings → Tokens** creas un token para un usuario con permisos mínimos, y la cabecera pasa a ser `-H "Authorization: Bearer $TOKEN"`. No caduca al reiniciar, se revoca solo y no expone nada. En Splunk 9 y 10 existe además `/services/search/v2/jobs` y su `/v2/jobs/export`. La v1 sigue funcionando; si empiezas de cero, usa la v2.

### ▾ 8.5 · Programado, sin que nadie lo lance
**savedsearches.conf**
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

## 09 // LOS FALLOS QUE VAS A COMETER UNA VEZ

| Síntoma | Casi siempre es |
| :--- | :--- |
| **Cero resultados y ningún error** | El `search` inicial que falta en la API; un campo que se llama `line.status` y no `status`; o el rango de tiempo, que por defecto son las últimas 24 horas. |
| **El fichero exportado se corta** | Los tres límites de arriba. `-maxout 100`, `count=100` o `maxresultrows=50000`. |
| **La búsqueda tarda una eternidad** | Mira dónde está la primera tubería. `index=* \| search algo` lee todo Splunk para tirar el 99%. |
| **El resultado sale desordenado** | `table` elige columnas, no ordena. Falta el `sort`. Y `sort` corta a 10.000 filas: `\| sort 0 campo` quita el límite — ese `0` no es una errata. |
| **Un `eval` devuelve texto en vez del campo** | Las comillas. En SPL, `"dobles"` para valores literales y `'simples'` para **nombres de campo**. Es al revés de casi todos los lenguajes que conoces. |

---

*Índice de ejemplo: `mi_servicio` · Campos del `props.conf` del kit.*  
*[Search Reference de Splunk](https://help.splunk.com/en/splunk-enterprise/search/spl-search-reference)*
