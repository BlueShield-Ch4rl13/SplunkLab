# Splunk desde cero

Lo mínimo para: **crear un índice**, meter dentro los eventos de **un servicio
de `docker-compose`**, y volver a **sacarlos en JSON y HTML** para un dashboard.

Lo imprescindible son cuatro ficheros: el `docker-compose.yml`, el
`indexes.conf` (el índice), el `inputs.conf` (el token de HEC) y `exportar.py`.
El resto es el servicio de ejemplo y las vías alternativas de ingesta.

**Tres documentos, según por dónde empieces:**

- **[MANUAL.md](MANUAL.md)** — el recorrido completo y en orden: desde instalar
  la máquina virtual hasta el dashboard, con notas de producción. Empieza aquí
  si partes de cero.
- **[GUIA.md](GUIA.md)** — el detalle de cada pieza: las tres vías de ingesta,
  los formatos del driver de Docker, el parseo, los códigos de error de HEC.
- **[CONSULTAS.md](CONSULTAS.md)** — la chuleta de SPL: reconocer un Splunk que
  no conoces, filtrar, agrupar, y las cinco vías de exportación (interfaz,
  `outputcsv`, CLI, API REST y programado) con los comandos listos para copiar.

```
 mi-servicio ──stdout──► driver de logging ──HEC 8088──► SPLUNK (índice mi_servicio)
                                                            │
                                              API REST 8089 ▼
                                                       exportar.py
                                                            │
                                    salida/datos.json · dashboard.html · csv/
```

## En una máquina Ubuntu recién instalada

```bash
sudo ./scripts/00-preparar-maquina.sh   # límites, Docker, firewall, hora
sudo reboot
./scripts/01-verificar.sh               # comprueba que todo está en su sitio
```

## Y luego, en cuatro comandos

```bash
cp .env.example .env
make up          # Splunk + el servicio (1-3 min el primer arranque)
make trafico     # genera peticiones para tener datos
make ver         # exporta y sirve el dashboard en :8081
```

- Splunk: http://localhost:8000 (`admin` / la contraseña del `.env`)
- Tu servicio: http://localhost:8080
- Tu dashboard: http://localhost:8081/dashboard.html

## Qué hay dentro

| Fichero | Para qué |
|---|---|
| `docker-compose.yml` | Splunk + el servicio de ejemplo, con el bloque `logging` que lo manda todo a Splunk |
| `docker-compose.ficheros.yml` | Vía B: si tu servicio escribe a ficheros en vez de a stdout |
| `splunk/apps/mi_indice/default/indexes.conf` | **El índice**, definido en un fichero versionable |
| `splunk/apps/mi_indice/default/inputs.conf` | El token de HEC: la puerta por la que entran los logs |
| `splunk/apps/mi_indice/default/props.conf` | Cómo se leen esos logs (corto, porque el servicio escribe JSON) |
| `uf/apps/mi_uf/default/` | Configuración del Universal Forwarder (solo vía B) |
| `nginx/nginx.conf` | El servicio de ejemplo, configurado para escribir JSON |
| `exportar.py` | Consulta la API REST y escribe JSON, CSV y HTML. Sin dependencias |
| `plantilla.html` | El aspecto del dashboard |
| `Makefile` | Atajos. `make` a secas lista todo |
| `scripts/00-preparar-maquina.sh` | De Ubuntu recién instalado a listo para Docker. Idempotente |
| `scripts/01-verificar.sh` | Comprueba máquina, Docker, índice, token y salida. No cambia nada |
| `scripts/02-alias-para-mi-app.py` | Le das una muestra de tus logs y te escribe el `FIELDALIAS` que necesitas |

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

Tres cosas que no son obvias y están explicadas en la guía: `splunk-url` es
`localhost` porque quien conecta es el demonio de Docker, **no** el contenedor;
el índice tiene que existir **antes**; y a partir de ahí `docker logs` deja de
funcionar para ese contenedor.

## Comandos

```bash
make comprobar   # ¿existe el índice? ¿funciona el token? ¿cuántos eventos hay?
make buscar Q='index=mi_servicio | stats count by resultado'
make exportar    # solo escribe salida/, sin servidor
make ficheros    # levanta la vía B (ficheros + Universal Forwarder)
make reset       # borra los datos indexados y empieza de cero
```
