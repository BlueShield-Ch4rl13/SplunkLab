# De máquina vacía a dashboard

El recorrido completo, en orden, sin saltar a otro sitio: instalar la máquina,
prepararla, levantar Splunk, crear el índice, meter dentro los logs de tu
aplicación de Docker y sacarlos en JSON y HTML.

Si ya tienes la máquina y solo quieres la parte de Splunk, ve directo a la
[Parte 3](#parte-3--traer-el-kit-y-levantar-splunk). Y si lo que quieres es el
detalle de una pieza concreta —las tres vías de ingesta, los formatos del
driver, el parseo— eso está en **[GUIA.md](GUIA.md)**; aquí va lo justo para
avanzar sin pararse.

**Índice**

| | |
|---|---|
| [Parte 0](#parte-0--el-mapa) | El mapa y las decisiones |
| [Parte 1](#parte-1--la-máquina-virtual) | La máquina virtual, desde la ISO |
| [Parte 2](#parte-2--preparar-el-sistema) | Preparar el sistema |
| [Parte 3](#parte-3--traer-el-kit-y-levantar-splunk) | Traer el kit y levantar Splunk |
| [Parte 4](#parte-4--el-índice) | El índice |
| [Parte 5](#parte-5--la-puerta-de-entrada) | La puerta de entrada (HEC) |
| [Parte 6](#parte-6--conectar-tu-aplicación) | Conectar tu aplicación |
| [Parte 7](#parte-7--comprobar-que-llegan-los-datos) | Comprobar que llegan |
| [Parte 8](#parte-8--sacar-los-datos) | Sacar los datos |
| [Parte 9](#parte-9--el-dashboard) | El dashboard |
| [Parte 10](#parte-10--que-siga-funcionando-solo) | Que siga funcionando solo |
| [Parte 11](#parte-11--notas-de-producción) | Notas de producción |

---

## Parte 0 — El mapa

```
   ┌─────────────────────── VM Ubuntu Server ────────────────────────┐
   │                                                                 │
   │   tu app ──stdout──► driver de logging ──┐                      │
   │   (docker compose)                       │ HEC · 8088           │
   │                                          ▼                      │
   │                                    ┌───────────┐                │
   │                                    │  SPLUNK   │ índice:        │
   │                                    │           │ mi_servicio    │
   │                                    └─────┬─────┘                │
   │                                          │ API REST · 8089      │
   │                                          ▼                      │
   │                                    exportar.py                  │
   │                                          │                      │
   │                        datos.json · dashboard.html · csv/       │
   └─────────────────────────────────────────────────────────────────┘
                                   │
                          tu PC ───┘  navegador y SSH
```

**Tres decisiones que se toman aquí y condicionan todo lo demás:**

1. **Splunk va en Docker, no instalado en el sistema.** Se levanta y se tira en
   segundos, la configuración vive en ficheros de tu repositorio, y no ensucia
   la máquina. El único precio: hay que entender cómo pasan los datos entre el
   contenedor y el resto, que es justo lo que explica la Parte 6.
2. **Los logs entran por HEC, no leyendo ficheros.** Es lo natural en Docker y
   te ahorra media configuración de parseo. Las otras dos vías están en
   [GUIA.md](GUIA.md), paso 4.
3. **Los datos salen por la API REST a un fichero.** Así puedes enseñarlos sin
   dar acceso a Splunk, publicarlos o guardarlos como evidencia.

---

## Parte 1 — La máquina virtual

### 1.1 Cuánto ponerle

Splunk pide 2 GB de RAM solo para arrancar, y por debajo de eso ni lo intenta.
Súmale el sistema y tus contenedores:

| | Mínimo para que arranque | Recomendado para trabajar |
|---|---|---|
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | **8 GB** |
| Disco | 25 GB | 40-60 GB |

El disco es lo que más se subestima: las imágenes de Splunk ocupan bastante, y
encima están los datos indexados. Con 25 GB llegas justo a fin de mes.

> Para comparar: el servidor de referencia que Splunk documenta para un
> indexador de **producción** es de 12 CPU y 12 GB de RAM, con discos que den
> 800 IOPS. Lo de arriba es para un laboratorio, no para dar servicio.

### 1.2 La ISO

Descarga **Ubuntu Server 26.04 LTS** (nombre en clave *Resolute Raccoon*,
salió en abril de 2026) de <https://ubuntu.com/download/server>. La versión
*Server*, no la *Desktop*: no necesitas escritorio y te ahorras 1 GB de RAM.

Si prefieres ir sobre seguro, 24.04 LTS también vale y está igual de soportada
por Docker.

### 1.3 Crear la VM

Da igual VirtualBox, VMware Workstation o Hyper-V. Lo que importa:

- **Tipo:** Linux / Ubuntu 64-bit.
- **Memoria:** 8192 MB.
- **Procesadores:** 4 (o 2 si vas justo).
- **Disco:** 40 GB, *dinámico* si tu hipervisor lo ofrece.
- **Red:** **adaptador puente** (*bridged*), no NAT. Con puente, la VM tiene su
  propia IP en tu red y llegas a ella desde el navegador de tu PC sin pelearte
  con redirecciones de puertos. Con NAT tendrías que mapear el 8000, el 8081 y
  el 22 a mano.
- Si usas VirtualBox, habilita **VT-x/AMD-V** en la BIOS de tu PC o irá a paso
  de tortuga.

### 1.4 Instalar el sistema

El instalador de Ubuntu Server es un asistente de texto. Las respuestas que
importan:

| Pantalla | Qué poner |
|---|---|
| Idioma / teclado | Lo que te apañe; el teclado, español si el tuyo lo es |
| Tipo de instalación | **Ubuntu Server** (no *minimized*: te faltarían herramientas) |
| Red | Anota la IP que le da el DHCP. Mejor aún: ponla **fija** (ver abajo) |
| Proxy | Vacío |
| Espejo de paquetes | El que proponga |
| Disco | **Use an entire disk**. Sin LVM si no lo necesitas: menos piezas |
| Perfil | Tu nombre, nombre de la máquina (p. ej. `splunk-lab`) y usuario |
| SSH | **Marca "Install OpenSSH server"**. Sin esto no entras por SSH |
| Snaps | Ninguno. Docker lo instalaremos del repositorio oficial, no como snap |

**Ponle IP fija.** Si el DHCP le cambia la dirección, tus marcadores dejan de
funcionar y el `splunk-url` del driver de logging apunta a la nada. En el
instalador, en la pantalla de red, edita el interfaz y pasa de *DHCP* a
*Manual*. O después, con netplan:

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

```yaml
network:
  version: 2
  ethernets:
    enp0s3:                      # el nombre real lo ves con: ip a
      dhcp4: false
      addresses: [192.168.1.50/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

```bash
sudo netplan apply
ip a                             # comprueba que la tiene
```

### 1.5 Entrar por SSH desde tu PC

Trabajar en la consola de la VM es incómodo: no puedes copiar y pegar. Desde tu
PC (PowerShell o el terminal de Windows valen, traen `ssh` de serie):

```bash
ssh tu-usuario@192.168.1.50
```

Y para no teclear la contraseña cada vez —y poder endurecer SSH después—,
genera una clave y súbela:

```bash
ssh-keygen -t ed25519 -C "mi-pc"        # solo la primera vez, en TU PC
ssh-copy-id tu-usuario@192.168.1.50
```

**Haz esto antes de la Parte 2.** El script de preparación solo desactiva el
acceso por contraseña si ve que ya tienes una clave que funciona; es a
propósito, para que no te quedes fuera de tu propia máquina.

---

## Parte 2 — Preparar el sistema

Ya dentro de la VM, trae el kit y ejecuta el primer script:

```bash
# copia el kit a la VM (desde TU PC, con scp) o clónalo con git
cd ~/splunk-inicio
sudo ./scripts/00-preparar-maquina.sh
```

Es **idempotente**: puedes ejecutarlo dos veces sin romper nada; cada paso mira
si ya está hecho. Y esto es lo que hace, con el porqué de cada cosa:

| Paso | Qué hace | Por qué importa |
|---|---|---|
| 1 | Comprueba SO, arquitectura, RAM, disco y CPU | Te avisa **antes** de perder media hora si la VM se queda corta |
| 2 | Zona horaria y NTP | Si la hora de la máquina va mal, **todos** los eventos que indexes llevarán la hora mal, y en un SIEM eso lo invalida todo |
| 3 | Actualiza el sistema | Lo de siempre |
| 4 | Paquetes base (`curl`, `git`, `jq`, `ufw`, `chrony`…) | Herramientas que vas a usar sí o sí |
| 5 | Usuario de trabajo con `sudo` | Trabajar como root todo el rato es la forma más rápida de romper algo sin querer |
| 6 | Endurece SSH — **solo si ya tienes clave** | Sin root, sin contraseña, tres intentos. La condición evita el clásico autobloqueo |
| 7 | Cortafuegos `ufw` | Deniega todo lo entrante salvo los puertos que usas |
| 8 | Límites del sistema y *huge pages* | Ver abajo: es lo menos evidente y lo que más problemas raros causa |
| 9 | Docker Engine del repositorio oficial | El `docker.io` de Ubuntu va por detrás y choca con los paquetes de Docker |
| 10 | Rotación de logs de contenedores | Sin esto, un contenedor charlatán te llena el disco. Le pasa a todo el mundo una vez |

### 2.1 Los límites del sistema (paso 8)

Es la parte que nadie espera y la que produce errores incomprensibles meses
después.

**Ficheros abiertos.** Splunk abre muchísimos a la vez —cada *bucket* de un
índice son varios ficheros— y con los límites por defecto de Linux se queda
corto. Los valores que documenta Splunk:

```
nofile   64000        # ficheros abiertos
nproc    16000        # procesos de usuario
fsize    unlimited    # tamaño máximo de fichero
```

El script los escribe en `/etc/security/limits.d/99-splunk.conf` **y** en
`/etc/systemd/system.conf.d/`, porque los servicios que arranca systemd no leen
`limits.conf`. Los de systemd se aplican del todo al **reiniciar la máquina**.

**Transparent Huge Pages.** Splunk documenta que le degradan el rendimiento de
forma notable. Es una opción del núcleo del **anfitrión**: aunque Splunk corra
dentro de un contenedor, hay que desactivarla en la VM. El script instala un
servicio de systemd que las apaga en cada arranque.

### 2.2 El cortafuegos y Docker (paso 7)

Esto sorprende a mucha gente y conviene saberlo antes de exponer nada:

> **Docker escribe sus propias reglas de iptables y se salta `ufw`.** Un puerto
> que publiques con `ports: "8000:8000"` queda accesible desde fuera **aunque
> `ufw` lo tenga cerrado**.

En una VM de tu red local no es dramático. Si la máquina está expuesta, la
forma correcta es publicar solo en local y llegar por un túnel SSH:

```yaml
ports:
  - "127.0.0.1:8000:8000"       # solo accesible desde la propia VM
```

```bash
# desde TU PC
ssh -L 8000:127.0.0.1:8000 tu-usuario@192.168.1.50
# y abres http://localhost:8000 en tu navegador
```

### 2.3 Después del script

```bash
sudo reboot        # para que los límites de systemd se apliquen del todo
```

Y al volver a entrar, comprueba:

```bash
./scripts/01-verificar.sh
```

Ese script no cambia nada: mira la máquina, Docker, el laboratorio y Splunk, y
te dice qué falta. Vuelve a él cada vez que algo no cuadre.

---

## Parte 3 — Traer el kit y levantar Splunk

```bash
cd ~/splunk-inicio
cp .env.example .env
nano .env                  # cambia SPLUNK_PASSWORD (mínimo 8 caracteres)
docker compose up -d
docker compose ps          # espera a que splunk ponga (healthy)
```

El primer arranque tarda entre uno y tres minutos: el contenedor se aprovisiona
con Ansible por dentro. Puedes ver el proceso con `docker compose logs -f splunk`.

Cuando esté listo, desde el navegador de tu PC:

- **Splunk:** `http://192.168.1.50:8000` — usuario `admin`, la contraseña del `.env`
- **El servicio de ejemplo:** `http://192.168.1.50:8080`

> Dos variables del compose que no puedes quitar: desde la versión 10 de Splunk
> hacen falta **las dos** líneas de licencia, `SPLUNK_START_ARGS=--accept-license`
> y `SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com`. Si falta una, el
> contenedor arranca y se queda a medias sin decir gran cosa.

---

## Parte 4 — El índice

Ya está creado: viene definido en
`splunk/apps/mi_indice/default/indexes.conf`, y esa carpeta se monta dentro de
Splunk como una app, así que el índice se crea solo al arrancar.

```ini
[mi_servicio]
homePath   = $SPLUNK_DB/mi_servicio/db
coldPath   = $SPLUNK_DB/mi_servicio/colddb
thawedPath = $SPLUNK_DB/mi_servicio/thaweddb
maxTotalDataSizeMB     = 2048      # 2 GB
frozenTimePeriodInSecs = 2592000   # 30 días
```

Se podría crear igual desde la interfaz (**Settings → Indexes → New Index**) o
con `splunk add index`, pero entonces vive dentro del contenedor: lo recreas y
desaparece, sin rastro de cómo lo hiciste. En un fichero está en tu
repositorio, se versiona y se lleva a otra máquina tal cual.

**Compruébalo:**

```bash
docker compose exec splunk /opt/splunk/bin/splunk list index -auth admin:TU_CLAVE | grep mi_servicio
```

Dos cosas que conviene tener claras desde el principio:

- **Congelar significa borrar.** Cuando se llega a `maxTotalDataSizeMB` *o* a
  `frozenTimePeriodInSecs`, lo más viejo se elimina — salvo que configures
  `coldToFrozenDir` para archivarlo.
- **No uses `main`.** Es el índice por defecto y acaba siendo el cajón de
  sastre donde se mezclan cuatro fuentes. Separarlas después es reindexar.

---

## Parte 5 — La puerta de entrada

El **HTTP Event Collector** es el puerto 8088. El driver de logging de Docker
habla exactamente eso. También viene ya configurado, en
`splunk/apps/mi_indice/default/inputs.conf`:

```ini
[http://mi_servicio]
token = 11112222-3333-4444-5555-666677778888
index = mi_servicio
indexes = mi_servicio          # lista blanca: no puede escribir en otro sitio
sourcetype = mi_servicio:docker
```

**Un token por origen, nunca uno global**: así revocas el de una aplicación sin
tocar las demás, el índice queda forzado desde el servidor y sabes quién te
está gastando la licencia.

> El token de `inputs.conf` y el `HEC_TOKEN` del `.env` **tienen que ser el
> mismo**. Es el fallo número uno al empezar, y `01-verificar.sh` lo comprueba.

**Pruébalo:**

```bash
curl -k https://localhost:8088/services/collector/event \
  -H "Authorization: Splunk 11112222-3333-4444-5555-666677778888" \
  -d '{"event":{"prueba":"hola"},"sourcetype":"mi_servicio:docker"}'
# {"text":"Success","code":0}
```

---

## Parte 6 — Conectar tu aplicación

Añade este bloque al servicio en tu propio `docker-compose.yml`:

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

**Tres cosas que no son nada obvias:**

1. **`splunk-url` es `localhost`, no `splunk`.** Quien abre la conexión es el
   **demonio de Docker**, que corre en la VM, no el contenedor. El nombre
   `splunk` solo existe dentro de la red de Docker y el demonio no la ve.
2. **El índice tiene que existir antes**, o el driver falla.
3. **`docker logs` deja de funcionar** para ese contenedor: los logs ya no
   están en local, se consultan en Splunk.


> **Y lo que no es obvio:** el driver **no manda tu línea tal cual**, la
> envuelve en un sobre `{tag, source, attrs, line}` y tu log va dentro de
> `line`. En Splunk tus campos se llamarán `line.status`, no `status`, y una
> búsqueda como `index=mi_servicio status>=400` devolverá **cero resultados sin
> dar ningún error**. El `props.conf` del kit ya trae el `FIELDALIAS` que los
> sube al primer nivel; para adaptarlo a tu aplicación:
>
> ```bash
> docker compose logs --no-log-prefix --tail 50 mi-servicio \
>   | python3 scripts/02-alias-para-mi-app.py
> ```
>
> Te escribe la línea de `FIELDALIAS` lista para pegar. El detalle completo, con
> cómo se ve un evento ya indexado y diez búsquedas para una web, está en
> [GUIA.md](GUIA.md), paso 4.


**Sin tocar tu proyecto:** crea un `compose.splunk.yml` junto a tu compose con
solo el bloque `logging` y arranca con los dos, así tu fichero original se
queda intacto:

```bash
docker compose -f docker-compose.yml -f compose.splunk.yml up -d
```

**Si tu servicio escribe a ficheros** en vez de a stdout, o si prefieres
recoger los `json.log` que escribe el propio Docker, esas son las vías B y C:
están en [GUIA.md](GUIA.md), paso 4, con sus ventajas y sus pegas.

> **Media hora bien invertida:** haz que tu aplicación escriba **JSON** antes de
> conectarla. Los campos salen solos en Splunk y te ahorras la mitad de
> `props.conf`. El nginx del kit está configurado así a propósito
> (`nginx/nginx.conf`), para que veas la diferencia.

---

## Parte 7 — Comprobar que llegan los datos

```bash
make trafico          # genera 160 peticiones contra el servicio de ejemplo
make comprobar        # índice + token + cuántos eventos hay
```

O en Splunk, con el rango en "Últimas 24 horas":

```spl
index=mi_servicio
```

Si sale vacío, en este orden:

```bash
docker compose logs mi-servicio | tail -20          # ¿arranca bien?
./scripts/01-verificar.sh                           # ¿índice y token bien?
make buscar Q='index=_internal log_level=ERROR | stats count by component'
```

El índice `_internal` son los logs del propio Splunk. Cuando algo no llega, la
respuesta suele estar ahí.

---

## Parte 8 — Sacar los datos

Splunk escucha en el **8089** para la API REST. La forma cruda, para ver que no
hay magia:

```bash
curl -k https://localhost:8089/services/search/jobs/export \
  -u admin:TU_CLAVE \
  -d search='search index=mi_servicio | stats count by resultado' \
  -d earliest_time=-24h \
  -d output_mode=json
```

Devuelve **un JSON por línea**, no un array. Cambiando `output_mode` cambias el
formato: `json`, `json_rows`, `json_cols`, `csv`, `xml`, `raw`.

> **Los tres errores garantizados.** El SPL tiene que empezar por `search` o por
> `|` — en la interfaz ese `search` es implícito, en la API no, y si lo olvidas
> *no falla*: devuelve cero resultados. `count=0` significa «sin límite», no
> «ninguno». Y el certificado es autofirmado: `curl -k`.

El script del kit hace eso con todas las consultas de golpe:

```bash
make exportar
```

```
salida/datos.json         todo junto, para consumir desde donde quieras
salida/dashboard.html     el dashboard, con los datos DENTRO del fichero
salida/csv/*.csv          un CSV por consulta
```

**Para cambiar qué se exporta**, edita la lista `CONSULTAS` al principio de
`exportar.py`. Un panel es un diccionario de cinco líneas.

**Con un token en vez de la contraseña** (lo correcto para algo automatizado):
créalo en **Settings → Tokens → New Token** y úsalo así:

```bash
SPLUNK_TOKEN=eyJraWQiOi... python3 exportar.py
```

---

## Parte 9 — El dashboard

```bash
make ver
```

y abres `http://192.168.1.50:8081/dashboard.html` desde tu PC.

O sin servidor: `make exportar` y te llevas `salida/dashboard.html` a donde
quieras. **Los datos van incrustados dentro del fichero**, así que funciona sin
Splunk delante y sin conexión. Para enseñar un proyecto sin dar acceso a tu
laboratorio, es justo lo que quieres.

**¿Y el dashboard de dentro de Splunk?** También: buscas, **Save As → Dashboard
Panel**, y ya lo tienes. Cuándo usar cada uno:

| | Dashboard de Splunk | Tu `dashboard.html` |
|---|---|---|
| Datos | En vivo cada vez que se abre | Congelados en cada exportación |
| Quién lo ve | Quien tenga cuenta en Splunk | Cualquiera con el fichero |
| Investigar | Pinchas y sigues (*drilldown*) | Lo que programes |
| Publicar fuera | No | Sí |

---

## Parte 10 — Que siga funcionando solo

**Arranque automático.** Ya está: los servicios llevan
`restart: unless-stopped`, así que al encender la VM se levantan solos. Docker
arranca con el sistema porque el script hizo `systemctl enable docker`.

**Exportar cada hora sin tenerlo abierto.** Un cron del usuario:

```bash
crontab -e
```

```cron
0 * * * * cd /home/tu-usuario/splunk-inicio && SPLUNK_PASSWORD='TU_CLAVE' /usr/bin/python3 exportar.py >> /tmp/exportar.log 2>&1
```

Mejor aún: usa un **token** en vez de la contraseña, y no lo pongas en el
`crontab` a la vista, sino en un fichero con permisos `600` que el script lea.

**Copia de seguridad de lo que importa.** Los datos indexados son reproducibles
(vuelven a entrar); **la configuración no**. Lo que hay que guardar es la
carpeta del repositorio, que es de texto y cabe en cualquier sitio:

```bash
tar czf ~/copia-splunk-$(date +%F).tar.gz \
    --exclude=salida ~/splunk-inicio
```

Si además quieres los datos:

```bash
docker run --rm -v splunk-inicio_splunk-var:/datos -v "$PWD":/copia alpine \
    tar czf /copia/splunk-var-$(date +%F).tar.gz -C /datos .
```

**Actualizar Splunk.** Cambia `SPLUNK_TAG` en el `.env` a la versión que
quieras y:

```bash
docker compose pull && docker compose up -d
```

Los volúmenes se conservan. Aun así, haz la copia antes: las subidas de versión
mayor de Splunk migran los índices y no hay marcha atrás.

**Vigilar el disco.** Es lo que se llena. Dos comandos que conviene mirar de vez
en cuando:

```bash
df -h /                        # el disco de la VM
docker system df               # cuánto ocupan imágenes, contenedores y volúmenes
docker system prune -a         # limpia lo que ya no se usa (cuidado: -a borra imágenes)
```

---

## Parte 11 — Notas de producción

Lo que montas aquí es un laboratorio. Esto es lo que cambiarías si fuera un
servidor de verdad, en orden de importancia:

**1. Certificados de verdad.** Splunk arranca con un certificado autofirmado, y
por eso vas poniendo `-k` y `splunk-insecureskipverify: "true"` por todas
partes. En producción se despliega el certificado de tu CA en Splunk y se quita
ese `insecureskipverify`: si no, cualquiera en la red puede ponerse en medio.

**2. Nada de la contraseña de admin en ficheros.** Se crea un usuario de
servicio con un rol recortado (solo búsqueda sobre el índice que necesita) y se
usa un **token de autenticación**, que se revoca solo y no expone al admin.
Splunk tiene control de acceso por rol: úsalo.

**3. No publiques el 8000 ni el 8089 a Internet.** La interfaz y la API de
gestión se quedan detrás de la VPN o accesibles solo desde la red de
administración. Y recuerda lo del apartado 2.2: `ufw` no protege lo que publica
Docker; hay que publicar en `127.0.0.1` o tocar la cadena `DOCKER-USER`.

**4. Separa índices por retención, no por equipo.** Los logs de aplicación
duran días; los de autenticación, meses. Un índice por tiempo de vida. Y
calcula el tamaño: `maxTotalDataSizeMB` mal puesto es la causa de que
desaparezcan datos que alguien esperaba tener.

**5. Filtra el ruido antes de indexarlo.** Los *healthchecks* suelen ser el 25%
del volumen y no aportan nada. Se tiran con un `TRANSFORMS-` a `nullQueue`, y
cada GB que no indexas es licencia que no gastas.

**6. Vigila la propia ingesta.** Si una fuente deja de llegar, tus búsquedas
salen vacías y **nadie te avisa**. Una alerta sobre esto vale más que muchas
detecciones:

```spl
| tstats count latest(_time) AS ultimo WHERE index=mi_servicio BY sourcetype
| eval minutos=round((now()-ultimo)/60, 1)
| where minutos > 30
```

**7. Un servidor de despliegue en cuanto haya varios agentes.** Con más de diez
forwarders no se entra máquina por máquina: se monta un *deployment server* y
cambiar el `inputs.conf` de cuarenta servidores es editar un fichero en un
sitio.

**8. La licencia.** Las imágenes arrancan con una **Trial de 60 días** (500 MB
al día, con alertas programadas). Al caducar pasa a **Free**, que sigue
indexando 500 MB/día pero **pierde las alertas programadas y el control de
usuarios**. Para un laboratorio basta con recrear el contenedor; para algo
serio, hay que licenciar.

**9. Copias probadas.** Una copia que no has restaurado nunca no es una copia.
Prueba a levantar el `tar.gz` en una VM limpia una vez.

---

## Anexo — Problemas típicos

| Síntoma | Causa casi seguro |
|---|---|
| Splunk no arranca | Contraseña de menos de 8 caracteres, falta una variable de licencia, o poca RAM |
| Se queda en `starting` para siempre | Mira `docker compose logs splunk`: suele ser un fallo de Ansible por permisos del volumen |
| El contenedor de tu app no arranca | El índice no existe todavía, o Splunk no estaba listo |
| `Invalid token` | El token del `.env` y el de `inputs.conf` no coinciden |
| `Incorrect index` | El token no tiene ese índice en su lista `indexes =` |
| Llegan eventos pero sin campos | El sourcetype no es el que crees: `index=mi_servicio \| stats count by sourcetype` |
| El JSON es bueno y aun así no hay campos | Falta `KV_MODE = json`, o tocaste `props.conf` y no reiniciaste Splunk |
| Todo aparece a la misma hora | Splunk no supo leer la marca de tiempo y usó la de indexación |
| Horas desplazadas | La VM tiene la hora mal, o falta `TZ` en `props.conf` |
| Errores raros en `splunkd.log` a las pocas horas | Los límites de ficheros abiertos: ¿reiniciaste tras el paso 8? |
| El disco se llena solo | Sin rotación de logs de contenedores, o `maxTotalDataSizeMB` demasiado alto |
| No llego a la VM desde mi PC | La VM está en NAT en vez de en puente, o `ufw` bloquea el puerto |
| `docker logs` no muestra nada | Es lo esperado con el driver de Splunk |

Y el comodín que resuelve cualquier discusión sobre configuración —pone delante
de cada línea **el fichero de donde sale ese valor**:

```bash
docker compose exec splunk /opt/splunk/bin/splunk btool props list mi_servicio:docker --debug
docker compose exec splunk /opt/splunk/bin/splunk btool inputs list --debug
```

---

## Anexo — Chuleta

```bash
# --- la máquina ---
./scripts/00-preparar-maquina.sh     # preparar (idempotente, con sudo)
./scripts/01-verificar.sh            # comprobar que todo está en su sitio

# --- el laboratorio ---
make up          # levantar        make down     # parar
make estado      # ver estado      make logs     # logs de Splunk
make trafico     # generar datos   make comprobar# índice + token + eventos
make reset       # borrar los datos indexados y empezar de cero

# --- buscar y sacar ---
make buscar Q='index=mi_servicio | stats count by resultado'
make exportar    # escribe salida/
make ver         # exporta cada 60 s y lo sirve en el 8081
make json        # ver el JSON por consola

# --- diagnóstico ---
docker compose logs -f splunk
docker compose exec splunk /opt/splunk/bin/splunk btool inputs list --debug
df -h / && docker system df
```
