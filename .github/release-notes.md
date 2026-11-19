## Eureka_CloudSpeed 1.3.0

Herramienta portable y de código abierto para Windows que mide **desde tu equipo** la latencia y la velocidad hacia las regiones de **Microsoft Azure** y **AWS**, vigila el **estado de los servicios** (Azure, Microsoft 365, AWS, Google, GitHub, Cloudflare) y consulta precios, regiones y rangos de IP. Exporta a **Excel con gráficos** y a **Power BI Desktop** (versión gratuita).

### Novedades de esta versión
- **Estado de servicios**: estado oficial de cada proveedor comparado con una comprobación propia desde tu red (DNS, conexión y HTTPS). Detecta caídas globales aunque la página de estado del proveedor también haya caído, caídas aún no publicadas y problemas de tu conexión. Comprobación automática e histórico para reclamar por el SLA.
- **Pruebas en la nube sin costes residuales**: `Herramientas\Probar-Velocidad.ps1` crea el almacenamiento, mide, lo borra siempre y comprueba que no queda nada.
- **Privacidad**: conservación del histórico (12 meses por defecto), borrado completo, seudónimo del equipo y URL secretas cifradas con DPAPI.
- Revisión de seguridad v2 (15 de 16 controles OK; pendiente solo la firma de código) y documentación completa en `Docs\`.

### Descarga
- **`Eureka_CloudSpeed_Portable.exe`**: un solo archivo, sin instalación ni permisos de administrador.
- **Código fuente** (*Source code*): ejecuta `Eureka_CloudSpeed.cmd`.

Si Smart App Control bloquea el .exe porque todavía no está firmado, usa `Eureka_CloudSpeed.cmd` del código fuente.

### Firma de código
Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org) (solicitud en trámite). Los ejecutables se compilan, prueban y firman en GitHub Actions a partir de este repositorio; hasta que se apruebe la solicitud se publican sin firmar. Política completa: [README](https://github.com/juanraul86/Eureka_CloudSpeed#pol%C3%ADtica-de-firma-de-c%C3%B3digo-code-signing-policy).

Documentación: [manual de uso](Docs/Manual-de-usuario.html), [documentación técnica](Docs/Documentacion-tecnica.html), [bitácora](Docs/Bitacora-de-versiones.html) y [revisión de seguridad](Docs/Revision-seguridad-y-confidencialidad.html).
