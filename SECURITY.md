# Política de seguridad

## Alcance

El laboratorio de Splunk (`docker-compose*.yml`, `splunk/`, `scripts/`) y `exportar.py`. Los puertos de Splunk y del dashboard escuchan en `SPLUNK_BIND` (127.0.0.1 por defecto) y la contraseña y el token de HEC se generan en `.env`, que nunca se sube.

## Cómo reportar una vulnerabilidad

Si encuentras una vulnerabilidad, **no abras un issue público**. Escríbeme a
**contact@carlosvillalbalagos.com** o, si está activado, usa *Security → Report a
vulnerability* en este repositorio.

Incluye, si puedes:

- qué has encontrado y qué impacto tiene;
- cómo reproducirlo (una prueba de concepto ayuda);
- la versión o el commit afectado.

## Qué puedes esperar

- Acuse de recibo en 72 horas y una primera evaluación en 7 días.
- La corrección, coordinando contigo cuándo se publica, y el crédito por el hallazgo si lo quieres.

Se da soporte a lo que hay en la rama `main` de SplunkLab.
