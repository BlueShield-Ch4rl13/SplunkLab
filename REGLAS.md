# Reglas de detección: crearlas y gestionarlas

En Splunk **una regla de detección no es un objeto distinto**. Es una búsqueda
guardada a la que le pones horario y condición de disparo. Lo que en Sentinel
se llama *analytic rule*, en Wazuh una *rule* y en Elastic un *detection rule*,
aquí es una **alerta**: una stanza en `savedsearches.conf`.

Eso tiene una consecuencia práctica que conviene interiorizar desde el
principio: **si sabes escribir la búsqueda, ya sabes escribir la regla**. Todo
lo demás es rellenar seis campos.

Este documento va en dos direcciones a la vez:

- **de la interfaz al fichero** — crear la regla haciendo clic, y luego
  recogerla y meterla en el repositorio (apartados 2, 3 y 4);
- **del fichero a la interfaz** — las reglas que ya trae este repo en
  `splunk/apps/mi_indice/default/savedsearches.conf` y cómo se gestionan
  (apartados 5 en adelante).

Las dos acaban en el mismo sitio. La interfaz es para *descubrir* una regla; el
fichero es para *tenerla*.

---

## 1. Las cinco piezas

Toda regla, la escribas donde la escribas, tiene estas cinco y ninguna más:

| # | Pieza | En la interfaz | En el `.conf` |
|---|---|---|---|
| 1 | **Qué** busca | la barra de búsqueda | `search` |
| 2 | **Sobre qué ventana** de tiempo | *Time Range* | `dispatch.earliest_time` / `dispatch.latest_time` |
| 3 | **Cada cuánto** se ejecuta | *Cron Expression* | `cron_schedule` + `enableSched` |
| 4 | **Cuándo** hay hallazgo | *Trigger Conditions* | `counttype` / `relation` / `quantity` |
| 5 | **Qué pasa** entonces | *Trigger Actions* | `alert.track`, `action.*` |

Y una sexta que no es un campo sino una decisión: **a quién avisa y con qué
prioridad**. En un SOC esto es la mitad del trabajo. Una regla con la severidad
mal puesta o sin silenciado se convierte en ruido en dos días, y una regla que
nadie lee es exactamente igual de útil que no tenerla.

---

## 2. Crearla desde la interfaz, paso a paso

La interfaz de Splunk está en inglés por defecto; abajo van los nombres tal
cual aparecen en pantalla.

### 2.1 Primero la búsqueda, y probada

Entra en **http://localhost:8000** → app **Search & Reporting** y escribe el
SPL. Antes de guardar nada, dos comprobaciones que ahorran horas:

```spl
index=mi_servicio tipo=acceso status=404
| stats dc(uri) AS rutas_distintas, count AS peticiones by ip_cliente
| where rutas_distintas >= 10
```

1. **Ponle el mismo rango de tiempo que va a tener la regla** (arriba a la
   derecha: *Last 15 minutes*, o *Last 5 minutes* si la regla va a correr cada
   5). Una búsqueda que se ve preciosa en *All time* puede no devolver nada en
   una ventana de 5 minutos, y es justo en esa ventana donde va a vivir.
2. **Mira cuántas filas devuelve en un rato normal, sin ataque.** Si devuelve
   algo, tu umbral está bajo y acabas de crear ruido. Súbelo hasta que en
   condiciones normales devuelva cero.

Genera tráfico antes de calibrar:

```bash
make trafico    # trafico normal: la regla NO debe saltar
make ataque     # trafico malicioso: la regla SI debe saltar
```

### 2.2 `Save As` → `Alert`

Arriba a la derecha, **Save As** → **Alert**. Se abre el formulario. Campo a
campo:

| Campo | Qué poner | Por qué |
|---|---|---|
| **Title** | `DET-WEB-001 Escaneo de rutas` | El título es el identificador: aparece en las alertas, en los logs del planificador y en las búsquedas de `_internal`. Ponle un código delante y no lo cambies nunca; el texto de detrás sí lo puedes retocar. |
| **Description** | qué detecta **y qué hacer si salta** | Este campo es el que lee a las 4 de la mañana quien coge la alerta. Escribe el triaje ahí, no en una wiki aparte. |
| **Permissions** | **Shared in App** | *Private* significa que la regla es tuya y de nadie más: ni tu compañero la ve, ni sobrevive si te borran el usuario. |
| **Alert type** | **Scheduled** → *Run on Cron Schedule* | *Real-time* mantiene una búsqueda corriendo permanentemente y se come un hueco de ejecución fijo. En un SOC real casi todo es programado. |
| **Cron Expression** | `*/5 * * * *` | Cinco campos: minuto, hora, día del mes, mes, día de la semana. |
| **Time Range** | *Earliest* `-5m@m`, *Latest* `@m` | **Lo mismo que dura el cron.** Ver apartado 7. |
| **Expires** | 24 horas está bien | Cuánto se guarda la alerta disparada en *Triggered Alerts*. No afecta a los datos. |

### 2.3 Trigger Conditions

**Trigger alert when** te da cuatro opciones:

- **Number of Results** — el caso normal. Como la búsqueda ya lleva un
  `| where` que filtra, basta con *is greater than* `0`: "si sale alguna fila,
  avisa".
- **Number of Hosts** / **Number of Sources** — el umbral se aplica a cuántos
  hosts o fuentes distintas aparecen. Útil para "esto está pasando en más de
  10 máquinas a la vez", que es otra historia distinta de que pase en una.
- **Custom** — una condición en SPL que se evalúa **sobre los resultados** de
  la búsqueda, no sobre los eventos. Por ejemplo `search pico > 500`.

Debajo, **Trigger**:

- **Once** → una alerta por ejecución, con todos los resultados dentro.
- **For each result** → una alerta por fila. Úsalo cuando cada fila es un caso
  independiente que alguien va a trabajar por separado (una IP, un usuario), y
  ten cuidado: una búsqueda que devuelve 300 filas te genera 300 alertas.

### 2.4 Throttle

Marca **Throttle** y aparecen dos campos:

- **Suppress triggering for** — tiempo que la regla se calla después de
  disparar. Sin esto, un ataque que dura media hora con una regla que corre
  cada 5 minutos son 6 alertas del mismo incidente.
- **Suppress results containing field value** — silencia **por valor de
  campo**, no la regla entera. Poniendo `ip_cliente`, si la IP `203.0.113.10`
  ya ha disparado, se calla *esa* IP durante el periodo, pero una IP nueva
  sigue avisando. Es lo correcto casi siempre, y va con *For each result*.

### 2.5 Trigger Actions

**Add Actions** despliega lo que puede hacer la regla:

| Acción | Para qué |
|---|---|
| **Add to Triggered Alerts** | Deja la alerta en *Activity → Triggered Alerts*. Es la de por defecto y la que hay que dejar puesta siempre: es el registro de que la regla saltó. Lleva un desplegable de **Severity** (Info, Low, Medium, High, Critical). |
| **Send email** | Necesita un servidor SMTP configurado en *Settings → Server settings → Email settings*. |
| **Webhook** | Un `POST` con el resultado en JSON a la URL que le digas. Es la puerta de entrada a SOAR, a n8n o a un canal de Teams. |
| **Run a script** | Ejecuta algo en `$SPLUNK_HOME/bin/scripts`. Deprecado a favor de las *alert actions* empaquetadas, pero sigue funcionando. |
| **Output results to lookup** | Escribe a un CSV. Muy útil para listas: IPs vistas, hosts conocidos, cuentas a vigilar. |

**Lo que no está en este formulario y sí en el `.conf`:** mandar el resultado a
un índice de alertas (`action.summary_index`). Es lo que hacen las reglas de
este repo, y es lo que te permite luego hacer búsquedas *sobre las alertas*
(`index=mi_alertas`) en vez de ir mirándolas de una en una. Si quieres tocarlo
desde la interfaz: **Settings → Searches, reports, and alerts → la regla →
Edit → Advanced Edit**, que deja editar cualquier atributo del `.conf` a mano.

---

## 3. Del clic al fichero: dónde ha ido a parar eso

Splunk acaba de escribir la regla en un fichero. **En cuál depende de los
permisos que le pusiste**, y esto explica el 90% de los "no encuentro mi
alerta":

| Permisos | Fichero |
|---|---|
| *Private* | `$SPLUNK_HOME/etc/users/<usuario>/<app>/local/savedsearches.conf` |
| *Shared in App* | `$SPLUNK_HOME/etc/apps/<app>/local/savedsearches.conf` |

Como la creaste desde *Search & Reporting*, `<app>` es `search`. Para verlo:

```bash
make shell
cat /opt/splunk/etc/apps/search/local/savedsearches.conf
```

Y el comando que resuelve cualquier duda sobre de qué fichero sale cada valor:

```bash
docker compose exec -u splunk splunk /opt/splunk/bin/splunk btool savedsearches list --debug
```

`--debug` pone delante de cada línea el fichero del que viene. Cuando dos
ficheros definen lo mismo, `btool` te enseña quién gana.

---

## 4. Llevarla al repositorio

Una regla que solo existe dentro del contenedor no existe. Si haces
`make reset`, o recreas el contenedor, o te llevas el lab a otra máquina, se
va con él. El sitio de las reglas es el repositorio:

1. Copia la stanza de `etc/apps/search/local/savedsearches.conf` a
   **`splunk/apps/mi_indice/default/savedsearches.conf`** de este repo.
2. Quita lo que Splunk añade y no aporta: `request.ui_dispatch_app`,
   `request.ui_dispatch_view`, `display.*`, `workload_pool`. Son estado de la
   interfaz, no de la detección.
3. Añade `description` si no la pusiste, y comenta el *por qué* del umbral.
4. Reinicia y comprueba:

```bash
docker compose restart splunk
make reglas
```

> **`default/` o `local/`.** En una app, `default/` es lo que trae el paquete y
> `local/` lo que ha cambiado el administrador de esa instalación; `local/`
> gana siempre. Aquí las reglas van en `default/` porque el paquete **eres tú**
> y así quien instale tu app puede ajustar umbrales en su `local/` sin tocar tu
> fichero ni perder los cambios en la siguiente actualización. Es exactamente
> como lo hacen las apps de Splunkbase.

---

## 5. Gestionarlas una vez existen

### 5.1 El inventario — `Settings → Searches, reports, and alerts`

Es la pantalla donde vive todo. Filtra por **App: Mi servicio** y por
**Type: Alerts**. Desde ahí, por cada regla:

- **Enable / Disable** — apagar una regla ruidosa a las 3 de la mañana sin
  borrarla. Equivale a `disabled = 1`.
- **Edit → Edit Alert** — el mismo formulario del apartado 2.
- **Edit → Edit Permissions** — quién la ve y quién la puede tocar.
- **Edit → Advanced Edit** — todos los atributos del `.conf`, en crudo.
- **Clone** — la forma normal de escribir la regla número dos: clonas la
  primera y cambias la búsqueda.
- **Run** — la ejecuta ya, sin esperar al cron.

### 5.2 Lo que ha saltado — `Activity → Triggered Alerts`

El histórico de disparos: qué regla, cuándo, con qué severidad y un enlace a
los resultados de aquella ejecución concreta. Es la pantalla del turno.

Solo aparecen aquí las reglas con **Add to Triggered Alerts** puesto
(`alert.track = 1`). Una regla que solo manda un correo no deja rastro en esta
lista, y eso es un problema de trazabilidad: **deja siempre el tracking
puesto**, aunque además hagas otra cosa.

Si además mandas las alertas a un índice, como hace este repo, tienes algo
mejor todavía: puedes *buscar sobre las alertas*.

```bash
make alertas
```

```spl
index=mi_alertas
| stats count AS veces, max(_time) AS ultima by regla, familia
| eval ultima=strftime(ultima, "%d/%m %H:%M:%S")
| sort - veces
```

Con eso contestas preguntas que la pantalla de *Triggered Alerts* no contesta:
qué regla es la más ruidosa del mes, qué IP ha disparado tres reglas distintas,
cuántas alertas por turno.

### 5.3 Vigilar al que las ejecuta

El planificador es el que de verdad hace correr las reglas, y falla en
silencio. Estas dos búsquedas deberían estar en tu dashboard de turno:

```spl
index=_internal sourcetype=scheduler savedsearch_name=DET-*
| stats count by savedsearch_name, status
```

```spl
index=_internal sourcetype=scheduler savedsearch_name=DET-* status=skipped
| stats count by savedsearch_name, reason
```

`status=skipped` significa que había más búsquedas programadas que huecos de
ejecución y Splunk se saltó esa. La regla sigue figurando como activa, no da
ningún error en la interfaz, y sin embargo hay ventanas de tiempo que nadie ha
mirado. Es el fallo más traicionero de todos y por eso este repo trae una
regla, `DET-SIEM-004`, que lo vigila.

### 5.4 Desde la línea de comandos

```bash
make reglas                                   # que reglas hay y en que estado
make probar R='DET-WEB-001 Escaneo de rutas'  # lanzarla ahora, con sus acciones
make alertas                                  # que ha disparado en 24 h
```

`make probar` usa el endpoint `dispatch` de la API REST, que es la forma
correcta de ejecutar una búsqueda guardada bajo demanda **y ejecutar también
sus acciones**. El comando SPL `| savedsearch "nombre"` también la lanza, pero
según la documentación de Splunk no funciona con búsquedas escritas en varias
líneas, que son casi todas las de este repo.

---

## 6. La tabla de equivalencias

Para traducir en las dos direcciones sin pensar:

| En la interfaz | En `savedsearches.conf` | Notas |
|---|---|---|
| Title | `[nombre de la stanza]` | |
| Description | `description = ...` | |
| Run on Cron Schedule | `enableSched = 1` + `cron_schedule` | |
| Time Range: Earliest / Latest | `dispatch.earliest_time` / `dispatch.latest_time` | |
| (no está en la interfaz) | `realtime_schedule = 0` | recupera ventanas saltadas en vez de saltar al presente |
| Number of Results | `counttype = number of events` | |
| is greater than 0 | `relation = greater than` + `quantity = 0` | |
| Custom condition | `alert_condition = <SPL>` | |
| Trigger: Once | `alert.digest_mode = 1` | |
| Trigger: For each result | `alert.digest_mode = 0` | |
| Throttle | `alert.suppress = 1` | |
| Suppress triggering for | `alert.suppress.period = 30m` | |
| Suppress results containing field value | `alert.suppress.fields = ip_cliente` | |
| Add to Triggered Alerts | `alert.track = 1` | |
| Severity | `alert.severity = 1..6` | 1 debug · 2 info · 3 warn · 4 error · 5 severe · 6 fatal |
| Send email | `action.email = 1` + `action.email.to` | |
| Webhook | `action.webhook = 1` + `action.webhook.param.url` | |
| (solo por fichero / Advanced Edit) | `action.summary_index = 1` + `action.summary_index._name` | a qué índice se escribe la alerta |
| Enable / Disable | `disabled = 0` / `1` | |

---

## 7. Las cinco trampas

**1. La ventana y el cron tienen que durar lo mismo.**
Cron cada 5 minutos → ventana de 5 minutos. Si la ventana es más larga, cada
ejecución vuelve a ver los eventos de la anterior: alertas duplicadas, y si la
regla escribe a un índice, **eventos duplicados en el índice**. Si es más
corta, dejas huecos ciegos. Y usa `@m` para redondear (`-5m@m` a `@m`): sin el
redondeo las ventanas bailan unos segundos en cada ejecución y se solapan o se
separan. El caso extremo de esto es programar una búsqueda con `collect` en
rango *All time*: cada ejecución vuelve a copiar **todo** el histórico al
índice de destino, y acabas con un índice de alertas cinco veces más grande que
el número real de hallazgos.

**2. `realtime_schedule` no significa lo que parece.**
Con el valor por defecto (`1`), si el planificador va con retraso, se salta la
ventana atrasada y ejecuta la actual. Para una regla de seguridad eso es perder
datos sin enterarte. Ponle `realtime_schedule = 0` a todas tus detecciones.

**3. El dueño de la regla es quien la ejecuta.**
El planificador corre cada búsqueda con los permisos de su propietario. Si el
propietario es `nobody` o un usuario sin acceso al índice, la regla funciona
cuando la lanzas tú a mano y devuelve cero cuando la lanza el planificador. Es
desesperante porque no da ningún error. En este repo se fija en
`metadata/default.meta` con `owner = admin`.

**4. Sin silenciado, una regla buena se vuelve ruido.**
Un escaneo que dura 40 minutos, con una regla cada 5, son ocho alertas del
mismo suceso. A la tercera vez que pasa, el turno deja de mirarlas. Pon
siempre `alert.suppress`, y cuando cada fila sea un caso independiente,
silencia por campo (`alert.suppress.fields`).

**5. Los umbrales se calibran con tus datos, no con los de nadie.**
`>= 10 rutas distintas` es un número razonable para este lab; en un sitio con
mil usuarios puede ser ruido y en una API interna puede ser altísimo. Antes de
activar una regla, ejecútala sobre las últimas 24 horas *sin* ataque y mira
cuántas veces habría saltado. Si la respuesta es "muchas", el umbral está mal
puesto, la regla no está mal escrita.

---

## 8. El catálogo que trae este repo

21 reglas en `splunk/apps/mi_indice/default/savedsearches.conf`, agrupadas por
tipo de dispositivo. Las familias **WEB** y **SIEM** funcionan con lo que este
lab ya indexa y vienen **activas**; las otras cuatro vienen **desactivadas**
(`disabled = 1`) porque esperan una fuente que todavía no has conectado.

| Regla | Qué detecta | Fuente que necesita |
|---|---|---|
| `DET-WEB-001` | Escaneo de rutas (muchos 404 distintos desde una IP) | el nginx del lab |
| `DET-WEB-002` | Fuerza bruta contra `/login` | el nginx del lab |
| `DET-WEB-003` | Pico de errores 5xx | el nginx del lab |
| `DET-WEB-004` | Herramienta de ataque en el User-Agent | el nginx del lab |
| `DET-WEB-005` | Inyección o salto de directorio en la URI | el nginx del lab |
| `DET-WEB-006` | Método HTTP inusual (PUT, DELETE, TRACE…) | el nginx del lab |
| `DET-WEB-007` | Ráfaga de peticiones desde una IP | el nginx del lab |
| `DET-SIEM-001` | Una fuente ha dejado de enviar | **cualquiera** |
| `DET-SIEM-002` | Dispositivo nuevo enviando al SIEM | **cualquiera** |
| `DET-SIEM-003` | Errores de ingesta en el propio Splunk | `_internal` |
| `DET-SIEM-004` | Una regla se está saltando ejecuciones | `_internal` |
| `DET-LNX-001` | Fuerza bruta SSH | `linux_secure` (auth.log) |
| `DET-LNX-002` | Escalada de privilegios con sudo | `linux_secure` |
| `DET-LNX-003` | Cuenta o clave SSH nueva en un servidor | `linux_secure` |
| `DET-WIN-001` | Fuerza bruta y password spraying (4625) | `WinEventLog:Security` |
| `DET-WIN-002` | PowerShell codificado | Sysmon |
| `DET-WIN-003` | Registro de seguridad borrado (1102) | `WinEventLog:Security` |
| `DET-NET-001` | Barrido de puertos | syslog del firewall |
| `DET-NET-002` | Viaje imposible en la VPN | logs de VPN con usuario e IP |
| `DET-CLD-001` | Contenedor nuevo enviando logs | el propio lab |
| `DET-CLD-002` | Shell interactiva dentro de un contenedor | `docker:daemon` o auditd |

Las de la familia **SIEM** son las que más se agradecen y las que más se
olvidan: no detectan ataques, detectan que **has dejado de poder detectarlos**.
Un dispositivo que se calla es un punto ciego, y apagar el agente antes de
actuar es de las primeras cosas que hace un atacante con acceso.

---

## 9. Añadir una regla para un dispositivo nuevo

La receta completa, de conectar el aparato a tener la detección funcionando:

**1. Mete los datos.** Forwarder si el aparato deja instalar agente, syslog al
puerto 514 si es un firewall o un switch, HEC si es una aplicación o una API.
Las tres vías están en `GUIA.md`.

**2. Mira qué ha llegado de verdad**, antes de escribir nada:

```spl
index=* sourcetype=lo_que_sea | head 1
```

No des por hecho ningún nombre de campo. El 80% de las reglas que no funcionan
es que el campo se llama distinto de lo que creías.

**3. Normaliza los campos que vas a usar** en `props.conf`, con `FIELDALIAS` si
el campo existe con otro nombre y con `EXTRACT` si hay que sacarlo del texto.
Si puedes, usa los nombres del **Common Information Model** de Splunk
(`src_ip`, `dest_ip`, `user`, `action`): así tus reglas valen igual para el
firewall de hoy y el de dentro de dos años.

**4. Escribe la búsqueda y calíbrala** contra 24 horas de datos reales, como en
el apartado 2.1.

**5. Guárdala como alerta** con el formulario del apartado 2, o copia una
stanza parecida del `savedsearches.conf` de este repo y cámbiale la búsqueda:
es más rápido y ya lleva la ventana, el silenciado y la severidad puestos.

**6. Demuestra que salta.** Una regla que nunca has visto disparar no es una
regla, es una intención. Provoca el evento a propósito —un `ssh` fallido, un
`4625`, un escaneo— y comprueba que aparece en *Triggered Alerts*.

---

## 10. Probarlo todo de una vez

```bash
make up                 # Splunk y el servicio
make trafico            # trafico normal: NINGUNA regla debe saltar
make ataque             # seis escenarios desde IPs simuladas distintas
# ... espera hasta 5 minutos, que es lo que tardan los cron ...
make alertas            # que ha disparado
make reglas             # estado de las 21 reglas
```

`make ataque` lanza, desde IPs simuladas distintas (`203.0.113.x`, el rango que
la RFC 5737 reserva para documentación, así no señalas a nadie real):

| Escenario | IP simulada | Regla que debe disparar |
|---|---|---|
| 30 rutas inexistentes | `203.0.113.10` | `DET-WEB-001` |
| 25 intentos contra `/login` | `203.0.113.20` | `DET-WEB-002` |
| Path traversal, SQLi y XSS | `203.0.113.30` | `DET-WEB-005` |
| User-Agents de sqlmap, Nikto, Nmap | `203.0.113.40` | `DET-WEB-004` |
| PUT, DELETE, TRACE, PATCH | `203.0.113.50` | `DET-WEB-006` |
| 120 peticiones en ráfaga | `203.0.113.60` | `DET-WEB-007` |
| 20 respuestas 500 | — | `DET-WEB-003` |

El truco de las IPs está en la cabecera `X-Forwarded-For`: todas las peticiones
salen en realidad de la misma máquina, y sin esa cabecera Splunk vería una sola
IP de origen y ninguna regla que agrupe por IP tendría sentido. El campo
`ip_cliente` que usan las reglas sale de ahí (`props.conf`), y es el mismo
mecanismo que necesitas de verdad el día que pongas tu servicio detrás de un
balanceador: sin `X-Forwarded-For` todo tu tráfico parecería venir del proxy.

Si una regla no salta, en este orden:

1. ¿Llegaron los eventos? → `make buscar Q='index=mi_servicio | stats count by ip_cliente'`
2. ¿Existe el campo? → `make buscar Q='index=mi_servicio | head 1 | table ip_cliente uri status user_agent'`
3. ¿Devuelve filas la búsqueda de la regla lanzada a mano? → `make probar R='...'`
4. ¿La ejecutó el planificador? → `make buscar Q='index=_internal sourcetype=scheduler savedsearch_name=DET-* | stats count by savedsearch_name status'`

Los cuatro pasos, en ese orden, localizan cualquier regla muda.
