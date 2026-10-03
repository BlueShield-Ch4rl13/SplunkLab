# =============================================================================
#  Atajos.  Ejecuta "make" a secas para ver la lista.
# =============================================================================
SHELL := /bin/bash
COMPOSE := docker compose
CLAVE = $(shell grep -E "^SPLUNK_PASSWORD=" .env 2>/dev/null | cut -d= -f2)
TOKEN = $(shell grep -E "^HEC_TOKEN=" .env 2>/dev/null | cut -d= -f2)

# Para meter el nombre de una regla (lleva espacios) en una URL: espacio -> %20
empty :=
space := $(empty) $(empty)

.DEFAULT_GOAL := ayuda
.PHONY: ayuda up down estado logs comprobar trafico ataque buscar reglas probar alertas exportar ver json ficheros shell reset

ayuda:  ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up:  ## Levanta Splunk y el servicio (el primer arranque tarda 1-3 min)
	@test -f .env || cp .env.example .env
	$(COMPOSE) up -d
	@echo ""
	@echo "  Splunk    : http://localhost:8000   (admin / la del .env)"
	@echo "  Tu servicio: http://localhost:8080"
	@echo ""
	@echo "  Espera a que el estado sea healthy:  make estado"
	@echo "  Luego comprueba que todo esta bien:  make comprobar"

down:  ## Para los contenedores (conserva los datos)
	$(COMPOSE) down

estado:  ## Estado de los contenedores
	$(COMPOSE) ps

logs:  ## Logs de arranque de Splunk
	$(COMPOSE) logs -f splunk

comprobar:  ## Comprueba que el indice existe y que el token de HEC funciona
	@echo "--- 1. el indice existe? ---"
	@$(COMPOSE) exec -T splunk /opt/splunk/bin/splunk list index -auth admin:$(CLAVE) 2>/dev/null | grep -E "^mi_servicio" \
		&& echo "    OK: el indice mi_servicio existe" || echo "    FALTA: revisa splunk/apps/mi_indice/default/indexes.conf"
	@echo "--- 2. el token de HEC funciona? ---"
	@$(COMPOSE) exec -T splunk curl -sk https://localhost:8088/services/collector/event \
		-H "Authorization: Splunk $(TOKEN)" \
		-d '{"event":{"prueba":"hola desde make comprobar"},"sourcetype":"mi_servicio:docker"}'; echo
	@echo "--- 3. cuantos eventos hay ya? ---"
	@$(COMPOSE) exec -T splunk /opt/splunk/bin/splunk search 'index=mi_servicio | stats count by sourcetype' \
		-auth admin:$(CLAVE) -earliest_time -24h

trafico:  ## Genera peticiones al servicio para tener datos que mirar
	@for i in $$(seq 1 40); do \
		curl -s -o /dev/null http://localhost:8080/ ; \
		curl -s -o /dev/null http://localhost:8080/ok ; \
		curl -s -o /dev/null http://localhost:8080/nope ; \
		[ $$((i % 5)) -eq 0 ] && curl -s -o /dev/null http://localhost:8080/error ; \
		sleep 0.2 ; \
	done; echo "  160 peticiones enviadas"

ataque:  ## Tráfico malicioso: 6 escenarios desde IPs simuladas, para que disparen las DET-WEB-*
	@echo "  [203.0.113.10] escaneo de rutas -> 30 x 404 distintos (DET-WEB-001)"
	@for i in $$(seq 1 30); do \
		curl -s -o /dev/null -H "X-Forwarded-For: 203.0.113.10" "http://localhost:8080/nope/ruta-inexistente-$$i" ; \
	done
	@echo "  [203.0.113.20] fuerza bruta -> 25 intentos contra /login (DET-WEB-002)"
	@for i in $$(seq 1 25); do \
		curl -s -o /dev/null -H "X-Forwarded-For: 203.0.113.20" "http://localhost:8080/login?u=admin&try=$$i" ; \
	done
	@echo "  [203.0.113.30] inyeccion / salto de directorio en la URI (DET-WEB-005)"
	@for u in "/..%2f..%2fetc/passwd" "/?id=1+union+select+1,2,3" "/?q=<script>alert(1)</script>" "/?p=%27+or+1=1--" "/..%00" "/?cmd=;cat+/etc/passwd"; do \
		curl -s -o /dev/null -H "X-Forwarded-For: 203.0.113.30" "http://localhost:8080$$u" ; \
	done
	@echo "  [203.0.113.40] herramientas de ataque en el User-Agent (DET-WEB-004)"
	@for ua in "sqlmap/1.7" "Nikto/2.5" "Nmap Scripting Engine" "masscan/1.3" "gobuster/3.6" "WPScan v3.8"; do \
		curl -s -o /dev/null -A "$$ua" -H "X-Forwarded-For: 203.0.113.40" "http://localhost:8080/" ; \
	done
	@echo "  [203.0.113.50] metodos HTTP inusuales: PUT DELETE TRACE PATCH (DET-WEB-006)"
	@for m in PUT DELETE TRACE PATCH; do \
		curl -s -o /dev/null -X $$m -H "X-Forwarded-For: 203.0.113.50" "http://localhost:8080/" ; \
	done
	@echo "  [203.0.113.60] rafaga: 120 peticiones en un minuto (DET-WEB-007)"
	@for i in $$(seq 1 120); do \
		curl -s -o /dev/null -H "X-Forwarded-For: 203.0.113.60" "http://localhost:8080/" ; \
	done
	@echo "  [sin IP]       20 respuestas 500 (DET-WEB-003)"
	@for i in $$(seq 1 20); do curl -s -o /dev/null "http://localhost:8080/error" ; done
	@echo ""
	@echo "  Hecho. Los cron tardan hasta 5 min:  espera y luego  make alertas"

buscar:  ## Busca desde la CLI:  make buscar Q='index=mi_servicio | stats count'
	@test -n "$(Q)" || (echo "Uso: make buscar Q='<SPL>'"; exit 1)
	$(COMPOSE) exec -T splunk /opt/splunk/bin/splunk search "$(Q)" -auth admin:$(CLAVE) -earliest_time -24h

reglas:  ## Lista las reglas DET-* cargadas y si estan activas o desactivadas
	$(COMPOSE) exec -T splunk /opt/splunk/bin/splunk search \
		'| rest /servicesNS/-/-/saved/searches | search title=DET-* | eval estado=if(disabled=1,"desactivada","activa") | table title estado cron_schedule | sort title' \
		-auth admin:$(CLAVE)

probar:  ## Lanza una regla ahora Y ejecuta sus acciones:  make probar R='DET-WEB-001 Escaneo de rutas'
	@test -n "$(R)" || (echo "Uso: make probar R='<nombre exacto de la regla>'"; exit 1)
	$(COMPOSE) exec -T splunk curl -sk \
		https://localhost:8089/servicesNS/nobody/mi_indice/saved/searches/$(subst $(space),%20,$(R))/dispatch \
		-u admin:$(CLAVE) -d trigger_actions=1 ; echo

alertas:  ## Qué han disparado las reglas en las últimas 24 h (index=mi_alertas)
	$(COMPOSE) exec -T splunk /opt/splunk/bin/splunk search \
		'index=mi_alertas | stats count AS veces, max(_time) AS ultima by regla, familia | eval ultima=strftime(ultima, "%d/%m %H:%M:%S") | sort - veces' \
		-auth admin:$(CLAVE) -earliest_time -24h

exportar:  ## Saca los datos a salida/datos.json y salida/dashboard.html
	SPLUNK_PASSWORD=$(CLAVE) python3 exportar.py

ver:  ## Exporta y sirve el dashboard en http://localhost:8081
	SPLUNK_PASSWORD=$(CLAVE) python3 exportar.py --servir --cada 60

json:  ## Exporta y vuelca salida/datos.json por consola
	@SPLUNK_PASSWORD=$(CLAVE) python3 exportar.py >/dev/null
	@cat salida/datos.json

ficheros:  ## Levanta la VIA B: el servicio escribe ficheros y los lee un forwarder
	$(COMPOSE) -f docker-compose.yml -f docker-compose.ficheros.yml up -d

shell:  ## Abre una shell dentro del contenedor de Splunk
	$(COMPOSE) exec splunk /bin/bash

reset:  ## BORRA todos los datos indexados y vuelve a empezar
	$(COMPOSE) down -v
	$(COMPOSE) up -d
