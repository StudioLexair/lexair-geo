# Operación

## Servicios

| Unidad | Función | Registro |
|--------|---------|----------|
| `postgresql` | Base `lexair_geo` | `/var/log/postgresql/` |
| `lexair-geo-api` | API (127.0.0.1:3000) | `journalctl -u lexair-geo-api` |
| `lexair-geo-tiles` | Mosaicos (127.0.0.1:8081) | `journalctl -u lexair-geo-tiles` |
| `nginx` | HTTPS :443, web, caché de mosaicos | `/var/log/nginx/` |
| `lexair-geo-backup.timer` | Copia diaria 02:30 | `journalctl -u lexair-geo-backup` |

```bash
sudo systemctl status lexair-geo-api lexair-geo-tiles nginx postgresql
sudo systemctl restart lexair-geo-api
```

## Salud

```bash
sudo /opt/lexair-geo/current/scripts/healthcheck_lexair_geo.sh --local          # todo
/opt/lexair-geo/current/scripts/healthcheck_lexair_geo.sh --json                # HTTPS local, salida JSON
healthcheck_lexair_geo.sh --url https://geo.internal --cacert lexair-geo-ca.crt  # desde otro equipo
```

Sin `--url` comprueba `https://127.0.0.1`. La CA se toma de `--cacert` o, si existe, de
`/etc/lexair-geo/pki/ca.crt` o su copia pública `/opt/lexair-geo/ca/lexair-geo-ca.crt`.
`--json` devuelve `{"ok":…,"checks":[{"name","status","detail"}]}`; si por error no se
ejecutara ninguna comprobación, el resultado es `ok:false` (nunca un «verde» vacío).

Comprueba servicios, API, mosaicos (incluido un PNG real de Santa Clara z10), cliente
web, disco (< 85 %), memoria disponible, antigüedad de la última copia (≤ 26 h) y
caducidad del certificado (> 30 días). Código de salida 0 = correcto; apto para cron
o para un monitor externo de la LAN. La pantalla «Estado del servidor» del panel de
administración muestra la misma información.

## Copias de seguridad

```bash
sudo /opt/lexair-geo/current/scripts/backup_lexair_geo.sh [--keep 14] [--dir /srv/lexair-geo/backups]
```

- `lexair_geo_<fecha>.dump` (`pg_dump -Fc`, verificado con `pg_restore -l`). Incluye
  los permisos (GRANT) del rol de aplicación `lexair_api`; la restauración rechaza
  volcados sin ellos.
- `lexair_geo_<fecha>.meta.json`: SHA-256, versión, recuentos (personas, ubicaciones,
  membresías, usuarios, auditoría, última migración), duración.
- `lexair_geo_<fecha>_config.tar.gz`: `/etc/lexair-geo` **sin** secretos: excluye
  `api.env`, `db-secrets.env`, `pki/private/` (clave de la CA) y `pki/server.key`.
  Tras una reinstalación, el instalador genera secretos y certificado nuevos (o
  reutilice los suyos desde un soporte cifrado aparte).
- Rotación: conserva las 14 más recientes.

**Copia externa**: las copias contienen datos personales. Cópielas regularmente a un
soporte cifrado fuera del servidor, por ejemplo:

```bash
gpg --symmetric --cipher-algo AES256 lexair_geo_<fecha>.dump    # o un disco con LUKS
```

## Restauración

```bash
sudo /opt/lexair-geo/current/scripts/restore_lexair_geo.sh /srv/lexair-geo/backups/lexair_geo_<fecha>.dump
```

1. Verifica el SHA-256 contra el `.meta.json` y que el volcado es legible.
2. Pide **confirmación explícita** escribiendo `lexair_geo` (o `--confirm lexair_geo`
   en procedimientos automatizados documentados).
3. Hace una copia previa automática de la base actual.
4. Restaura en una base temporal (`pg_restore` con lista filtrada: se omiten las
   extensiones, ya creadas por el instalador, y los datos de `spatial_ref_sys`, que
   pertenecen a PostGIS). Cualquier error de `pg_restore` aborta la operación.
5. Comprueba que la base temporal contiene `directory.persons` y los permisos de
   `lexair_api`; solo entonces la sustituye, reasigna `CONNECT` y reinicia el API.
6. Si algo falla, elimina la base temporal, deja la base actual intacta y vuelve a
   arrancar el API.

La vista materializada de agrupación del mapa (`geo.map_cluster_cells`) se restaura con
sus datos; no hace falta recalcularla (comprobado: idéntica a un `refresh` forzado).

Pruebe la restauración al menos una vez por trimestre en un equipo de pruebas.

## Usuarios

- Alta, roles, desactivación y restablecimiento de contraseña desde el panel
  (sección «Usuarios»). El restablecimiento genera una contraseña temporal.
- Recuperar el acceso del superadministrador desde el servidor:

```bash
sudo bash -c '. /etc/lexair-geo/db-secrets.env && cd /opt/lexair-geo/current/api &&
  DATABASE_URL="postgres://lexair_owner:$OWNER_PASSWORD@127.0.0.1/lexair_geo" \
  /opt/lexair-geo/node/bin/node dist/cli/create-admin.js --username admin --reset'
```

Muestra una contraseña temporal (cambio obligatorio en el siguiente acceso), conserva
el rol del usuario, revoca sus sesiones abiertas (efectivo en ≤ 5 s por la caché de
sesiones del API) y registra `user.password_reset` en la auditoría. La salida JSON
indica `"reset": true`.

## Actualizaciones

- **Aplicación**: ejecute el instalador del paquete nuevo; conserva datos, secretos y
  certificados, aplica solo las migraciones nuevas y guarda las 3 últimas versiones.
- **Mapas**: genere un paquete nuevo en la máquina de preparación e instálelo
  ([MAP_DATA.md](MAP_DATA.md)). Tras cambiar los mapas, vacíe la caché de Nginx:
  `sudo rm -rf /var/cache/nginx/lexair_tiles/* && sudo systemctl reload nginx`.
- **Sistema**: `apt` desde un espejo local o `.deb` aprobados; no actualice versiones
  mayores de PostgreSQL sin `pg_upgradecluster` probado.

## Mantenimiento de PostgreSQL

Autovacuum está activo. Tras importaciones masivas:

```bash
sudo -u postgres psql -d lexair_geo -c 'VACUUM (ANALYZE) directory.persons, geo.person_locations, directory.person_memberships'
```

Consultas lentas (> 1 s) en el registro de PostgreSQL, sin valores de parámetros.

### Agregados del mapa

Las agrupaciones del mapa (zoom 6–16) salen de `geo.map_cluster_cells`. El API la
refresca sola cada `map.cluster_refresh_s` segundos (60 por defecto, ajustable en
Administración → Ajustes; `0` lo desactiva) y solo si hubo cambios. Con 500 000 personas
un refresco cuesta ≈ 11 s de un núcleo y no bloquea lecturas. Tras una importación grande
o una restauración se puede forzar:

```bash
sudo -u postgres psql -d lexair_geo -c 'SELECT geo.refresh_map_clusters(true)'
sudo -u postgres psql -d lexair_geo -c 'SELECT changed_at, refreshed_at, refresh_ms FROM geo.map_cluster_state'
```

Mientras haya cambios sin reflejar, `/maps/points` responde `pendingChanges: true`. Los
puntos individuales (zoom ≥ 15) y las búsquedas siempre consultan los datos en vivo.

## Certificados

El certificado del servidor dura 825 días y el instalador lo renueva automáticamente
cuando faltan menos de 30 días (o si cambia el nombre/IP). La CA dura 10 años.
`healthcheck` avisa con 30 días de antelación.
