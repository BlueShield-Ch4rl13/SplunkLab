# Splunk desde cero

Un laboratorio de SIEM en `docker-compose` que hace las tres cosas que hace un
SIEM de verdad, y las hace con ficheros versionados en vez de con clics:

1. **Indexar** — un servicio manda sus logs a Splunk, con el índice, el token
   de HEC y el parseo definidos en `.conf`, no en la interfaz.
2. **Detectar** — 21 reglas de detección agrupadas por tipo de dispositivo, con
   su ventana, su umbral, su silenciado y su severidad.
3. **Sacar los datos** — de vuelta a JSON, CSV y un dashboard HTML propio, por
   la API REST y sin instalar nada.

Todo lo importante está en cuatro ficheros: `docker-compose.yml`,
`indexes.conf` (el índice), `inputs.conf` (el token de HEC) y
`savedsearches.conf` (las reglas). El resto es el servicio de ejemplo, las vías
alternativas de ingesta y el exportador.

```
 mi-servicio ──stdout──► driver de logging ──HEC 8088──► SPLUNK
                                                            │  índice mi_servicio
                                                            │
                                  21 reglas, cada 5 min ────┤
                                                            │  índice mi_alertas
                                                            │  Triggered Alerts
                                              API REST 8089 │
                                                            ▼
                                                       exportar.py
                                                            │
                                    salida/datos.json · dashboard.html · csv/
```

---

## Los documentos

Cuatro, según lo que quieras hacer. Ninguno repite al otro.

| Documento | Para qué |
|---|---|
| **[MANUAL.md](MANUAL.md)** | El recorrido completo y en orden, desde instalar la máquina virtual hasta el dashboard, con notas de producción. **Empieza aquí si partes de cero.** |
| **[GUIA.md](GUIA.md)** | El detalle de cada pieza: las tres vías de ingesta, los formatos del driver de Docker, el parseo, los códigos de error de HEC. |
| **[REGLAS.md](REGLAS.md)** | Las detecciones: crear una alerta desde la interfaz paso a paso, llevarla al repositorio, gestionarla, la tabla de equivalencias interfaz ↔ `.conf` y el catálogo de las 21 reglas. |
| **[CONSULTAS.md](CONSULTAS.md)** | La chuleta de SPL: reconocer un Splunk que no conoces, filtrar, agrupar, y las cinco vías de exportación con los comandos listos para copiar. También en versión compacta en [CHULETA-SPL.md](CHULETA-SPL.md). |

---

## Arrancar

En una máquina Ubuntu recién instalada:

```bash
sudo ./scripts/00-preparar-maquina.sh   # límites, Docker, firewall, hora
sudo reboot
./scripts/01-verificar.sh               # comprueba que todo está en su sitio
```

Y luego el lab:

```bash
cp .env.example .env
make up          # Splunk + el servicio (1-3 min el primer arranque)
make comprobar   # ¿existe el índice? ¿funciona el token? ¿entran eventos?
```

- **Splunk:** http://localhost:8000 (`admin` / la contraseña del `.env`)
- **Tu servicio:** http://localhost:8080
- **Tu dashboard:** http://localhost:8081/dashboard.html (después de `make ver`)

## El recorrido de cinco minutos

```bash
make trafico     # tráfico normal: ninguna regla debe saltar
make ataque      # seis escenarios de ataque desde IPs simuladas distintas
                 # ... espera hasta 5 minutos, que es lo que tardan los cron ...
make alertas     # qué han disparado las reglas
make ver         # exporta y sirve el dashboard en :8081
```

Si `make ataque` no dispara nada, `REGLAS.md` termina con los cuatro pasos que
localizan cualquier regla muda.

---

## Las reglas de detección

Están todas en un solo fichero, `splunk/apps/mi_indice/default/savedsearches.conf`,
y se cargan solas al arrancar Splunk. Agrupadas por **tipo de dispositivo**:

| Familia | Reglas | Estado | Fuente que necesita |
|---|---|---|---|
| `DET-WEB-*` | 7 | **activas** | el nginx de este lab |
| `DET-SIEM-*` | 4 | **activas** | cualquiera: miran metadatos, no contenido |
| `DET-LNX-*` | 3 | desactivadas | `linux_secure` (auth.log) |
| `DET-WIN-*` | 3 | desactivadas | `WinEventLog:Security` y Sysmon |
| `DET-NET-*` | 2 | desactivadas | syslog de firewall o VPN |
| `DET-CLD-*` | 2 | desactivadas | `docker:daemon` o auditd |

Las diez desactivadas traen la búsqueda escrita y `disabled = 1`: el día que
conectes esa fuente, le quitas el `disabled` y ya tienes la detección. Cada una
dice en su comentario qué sourcetype espera.

Las cuatro de la familia **SIEM** son las que más se agradecen y las que más se
olvidan: no detectan ataques, detectan que **has dejado de poder detectarlos**
— una fuente que se calla, un host nuevo que aparece, errores de ingesta, y una
regla que vigila que las demás reglas no se estén saltando ejecuciones.

```bash
make reglas                                   # las 21, con su estado
make probar R='DET-WEB-001 Escaneo de rutas'  # lanzar una ahora, con sus acciones
make alertas                                  # qué ha disparado en 24 h
```

---

## Qué hay dentro

| Fichero | Para qué |
|---|---|
| `docker-compose.yml` | Splunk + el servicio de ejemplo, con el bloque `logging` que lo manda todo a Splunk |
| `docker-compose.ficheros.yml` | Vía B: si tu servicio escribe a ficheros en vez de a stdout |
| `splunk/apps/mi_indice/default/indexes.conf` | **Los índices**: `mi_servicio` para los logs, `mi_alertas` para lo que disparan las reglas |
| `splunk/apps/mi_indice/default/inputs.conf` | El token de HEC: la puerta por la que entran los logs |
| `splunk/apps/mi_indice/default/props.conf` | Cómo se leen esos logs, y los campos calculados que usan las reglas (`ip_cliente`, `resultado`, `tipo`) |
| `splunk/apps/mi_indice/default/savedsearches.conf` | **Las 21 reglas de detección** |
| `splunk/apps/mi_indice/metadata/default.meta` | Permisos y propietario: quién ve las reglas y con qué permisos las ejecuta el planificador |
| `uf/apps/mi_uf/default/` | Configuración del Universal Forwarder (solo vía B) |
| `nginx/nginx.conf` | El servicio de ejemplo: escribe JSON, tiene un `/login` que devuelve 401 y un 404 para todo lo que no existe |
| `exportar.py` | Consulta la API REST y escribe JSON, CSV y HTML. Sin dependencias |
| `plantilla.html` | El aspecto del dashboard |
| `Makefile` | Atajos. `make` a secas los lista todos |
| `scripts/00-preparar-maquina.sh` | De Ubuntu recién instalado a listo para Docker. Idempotente |
| `scripts/01-verificar.sh` | Comprueba máquina, Docker, índice, token y salida. No cambia nada |
| `scripts/02-alias-para-mi-app.py` | Le das una muestra de tus logs y te escribe el `FIELDALIAS` que necesitas |

---

## Para usarlo con TU servicio

Copia este bloque al servicio de tu propio `docker-compose.yml`:

```yaml
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

Tres cosas que no son obvias y están explicadas en `GUIA.md`: `splunk-url` es
`localhost` porque quien conecta es el demonio de Docker, **no** el contenedor;
el índice tiene que existir **antes**; y a partir de ahí `docker logs` deja de
funcionar para ese contenedor.

Y para que las reglas `DET-WEB-*` te valgan con tus logs, lo único que hay que
tocar es el `FIELDALIAS` de `props.conf`: las reglas buscan `status`, `uri`,
`method` e `ip_cliente`, así que basta con que los campos de tu aplicación
lleguen con esos nombres. `scripts/02-alias-para-mi-app.py` te escribe esa
línea a partir de una muestra de tus logs.

---

## Todos los comandos

```bash
# levantar y comprobar
make up          # Splunk + el servicio
make estado      # estado de los contenedores
make comprobar   # índice, token de HEC y cuántos eventos hay
make logs        # logs de arranque de Splunk

# datos
make trafico     # peticiones normales
make ataque      # tráfico malicioso, para que disparen las reglas
make buscar Q='index=mi_servicio | stats count by resultado'

# detección
make reglas      # qué reglas hay cargadas y en qué estado
make probar R='DET-WEB-001 Escaneo de rutas'
make alertas     # qué han disparado en las últimas 24 h

# sacar los datos
make exportar    # escribe salida/datos.json, dashboard.html y los CSV
make ver         # lo mismo, y lo sirve en :8081 refrescando cada 60 s

# otros
make ficheros    # vía B: ficheros + Universal Forwarder
make shell       # una shell dentro del contenedor de Splunk
make reset       # BORRA los datos indexados y empieza de cero
```

> Después de tocar cualquier `.conf` de `splunk/apps/mi_indice/`, hay que
> reiniciar para que Splunk lo lea: `docker compose restart splunk`.

---

## Requisitos

Splunk pide 6 GB de RAM para ir cómodo y no arranca bien por debajo de 4. El
primer arranque tarda entre uno y tres minutos mientras la imagen se aprovisiona
sola; `make estado` te dice cuándo pasa a `healthy`.

Probado con `splunk/splunk:latest` (Splunk Enterprise 10) y el plugin
`docker compose` v2.
