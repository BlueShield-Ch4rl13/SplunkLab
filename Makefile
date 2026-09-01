# =============================================================================
#  Atajos.  Ejecuta "make" a secas para ver la lista.
# =============================================================================
SHELL := /bin/bash
COMPOSE := docker compose
CLAVE = $(shell grep -E "^SPLUNK_PASSWORD=" .env 2>/dev/null | cut -d= -f2)
TOKEN = $(shell grep -E "^HEC_TOKEN=" .env 2>/dev/null | cut -d= -f2)

.DEFAULT_GOAL := ayuda
.PHONY: ayuda up down estado logs comprobar trafico buscar exportar ver ficheros shell reset

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

buscar:  ## Busca desde la CLI:  make buscar Q='index=mi_servicio | stats count'
	@test -n "$(Q)" || (echo "Uso: make buscar Q='<SPL>'"; exit 1)
	$(COMPOSE) exec -T splunk /opt/splunk/bin/splunk search "$(Q)" -auth admin:$(CLAVE) -earliest_time -24h

exportar:  ## Saca los datos a salida/datos.json y salida/dashboard.html
	SPLUNK_PASSWORD=$(CLAVE) python3 exportar.py

ver:  ## Exporta y sirve el dashboard en http://localhost:8081
	SPLUNK_PASSWORD=$(CLAVE) python3 exportar.py --servir --cada 60

ficheros:  ## Levanta la VIA B: el servicio escribe ficheros y los lee un forwarder
	$(COMPOSE) -f docker-compose.yml -f docker-compose.ficheros.yml up -d

shell:  ## Abre una shell dentro del contenedor de Splunk
	$(COMPOSE) exec splunk /bin/bash

reset:  ## BORRA todos los datos indexados y vuelve a empezar
	$(COMPOSE) down -v
	$(COMPOSE) up -d
