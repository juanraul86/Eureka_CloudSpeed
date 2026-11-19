# Bitácora de cambios · Eureka_CloudSpeed

La bitácora completa (con lo que se publica en cada versión y el registro de operaciones en la nube) está en [`Docs/Bitacora-de-versiones.html`](Docs/Bitacora-de-versiones.html). Cada compilación deja en `Dist/MANIFIESTO-v<versión>.txt` las huellas SHA-256 y la lista de archivos publicados.

## Sin publicar (irá en 1.3.1, la primera versión firmada)
- Corrección: los avisos que Azure CLI y AWS CLI escriben por la salida de errores ya no detienen los scripts de `Herramientas/`.
- Corrección: `Probar-Velocidad.ps1` no intenta borrar ni pide otro inicio de sesión si no llegó a haber sesión; siempre pregunta por la sesión al final.
- Mensaje claro cuando la cuenta de Azure no tiene ninguna suscripción.
- `Crear-CuentasVelocidad.ps1` registra el proveedor `Microsoft.Storage` en suscripciones nuevas (antes fallaba con «SubscriptionNotFound»).
- Mensaje claro cuando una región de Azure no admite clientes nuevos (se propone otra región).
- Nuevo: modo demostración (`CS_DEMO=1`) que oculta la ruta de datos (con el nombre de usuario) para grabar vídeos.
- Nuevo: web del proyecto en GitHub Pages (https://juanraul86.github.io/Eureka_CloudSpeed/).
- Privacidad: la bitácora ya no muestra datos de la cuenta de AWS de pruebas; el historial público se ha rehecho sin ellos.

## 1.3.0 · 19/11/2026
- Nuevo: sección **Estado de servicios** (estado oficial de Microsoft, AWS, Google, GitHub y Cloudflare + comprobación propia desde la red + diagnóstico de caídas globales + histórico para SLA).
- Nuevo: `Herramientas/Probar-Velocidad.ps1` (crea, mide y borra siempre; verifica que no queda nada).
- Nuevo: mantener o cerrar la sesión de la CLI al terminar; `-Tenant` para Azure; `-Eliminar -Confirmar`.
- Nuevo: conservación del histórico (12 meses por defecto) y borrado completo; manifiesto de publicación.
- Cambio: S3 con una URL de subida por conexión; recarga automática de endpoints; guardado de configuración atómico con copia de seguridad.
- Corrección: `-Renovar` de AWS; listas JSON en PowerShell 5.1; RSS de Azure vacío; compilación con la app abierta.

## 1.2.0 · 19/11/2026
- Seguridad: URL cifradas con DPAPI, SAS revocables de 90 días, S3 endurecido con SigV4 propia, seudónimo del equipo, CSV sin inyección de fórmulas, integridad de los JSON, solo URL https.

## 1.1.0 · 19/11/2026
- Paridad con AzureSpeed: velocidad, latencia entre regiones, comandos, precios de VM/EC2/IA, regiones, mapa, nubes soberanas, búsqueda y rangos de IP, ayuda.

## 1.0.0 · 19/11/2026
- Primera versión: latencia a 75 regiones de Azure y AWS, gráficos en directo, Excel con gráficos, Power BI, CSV, HTML, modo consola y lanzadores.
