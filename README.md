# Eureka_CloudSpeed · Latencia a Azure y AWS

Herramienta portable para Windows que mide la latencia **desde tu equipo** a las regiones de **Microsoft Azure** y **Amazon Web Services**. Muestra los resultados en directo, sin congelar la ventana, y los exporta a **Excel con gráficos nativos** y a **Power BI Desktop** (versión gratuita).

**Versión 1.3.0 · noviembre de 2026** · De la familia de [Eureka_Utils](https://github.com/juanraul86/Eureka_Utils).

## Secciones

| Sección | Qué hace |
|---------|----------|
| **Estado de servicios** | Estado oficial de Azure, Microsoft 365, Power Platform, Azure DevOps, AWS, Google Cloud, Google Workspace, GitHub y Cloudflare, comparado con una comprobación propia desde tu red (DNS, conexión y HTTPS de 20 servicios). Detecta caídas globales aunque la página de estado del proveedor también haya caído, caídas aún no publicadas y problemas de tu propia conexión. Comprobación automática e histórico para reclamar por el SLA. |
| **Latencia** | Ranking en directo de 75 regiones (41 de Azure y 34 de AWS), prueba rápida de 10 rondas, modo continuo, gráficos (ranking, evolución, mapa, Azure frente a AWS) y panel "Tu conexión" (IP pública y operador, solo al pulsar). |
| **Velocidad** | Latencia, jitter, descarga y subida a una región con una o cuatro conexiones, curva de Mbps en directo, latencia con carga (saturación de la línea) y subida de un archivo propio. Usa cuentas de almacenamiento tuyas: `Herramientas\Crear-CuentasVelocidad.ps1` las crea con Azure CLI. |
| **Latencia entre regiones** | Mediana de ida y vuelta publicada por Microsoft entre regiones de Azure, filtros, gráfico y matriz completa en Excel con escala de color. |
| **Comandos** | Comandos `psping`, `Test-NetConnection`, bucle de PowerShell y `curl` listos para copiar, y medición inmediata de la región elegida. |
| **Precios de máquinas virtuales** | Azure (pago por uso, Spot, planes de ahorro y reservas de 1 y 3 años) y EC2 de AWS, en vivo, con vCPU y memoria, filtros, precio por vCPU, comparación de un tamaño en todas las regiones y exportación a Excel. |
| **Precios de modelos de IA** | Azure OpenAI y Microsoft Foundry, normalizados a USD por millón de tokens, por tipo (entrada, salida, caché) y despliegue (Global, Data Zone, Regional, Batch). |
| **Regiones y zonas** | Regiones de Azure global, China, US Government, previstas y AWS: ubicación, región emparejada, zonas de disponibilidad, acceso, residencia de datos y latencia medida; vista por geografía. |
| **Mapa de regiones** | Mapa mundial con todas las regiones, coloreado por nube o por la latencia medida, zoom por continente, búsqueda y medición con un clic. |
| **Nubes soberanas y entornos** | Azure global, US Government y China, y la tabla de endpoints de cada entorno (los lee de `Get-AzEnvironment` si tienes Az.Accounts). |
| **Búsqueda de IP** | A qué servicio y región de Azure (Public, China, US Gov) o AWS pertenece una IP, un dominio o una URL. |
| **Rangos de IP** | Etiquetas de servicio de Azure y rangos de AWS por servicio y región, con los prefijos IPv4/IPv6 para copiar o guardar. |
| **Ayuda** | Preguntas frecuentes, método de medida y fuentes de datos. |

## Características

- **75 regiones medibles**: 41 de Azure y 34 de AWS, filtrables por nube, geografía o texto. Hay 17 regiones de Azure más en el catálogo sin endpoint público; para medirlas basta con poner su propio endpoint en `Catalog/regions.json`.
- **Mediciones en paralelo y en directo**: el ranking se reordena solo mientras llegan los datos, con barras de color (verde < 50 ms, lima < 100, ámbar < 175, rojo ≥ 175).
- **Estadísticas útiles**: mediana (P50), P95, mínimo, media, jitter y pérdida, no solo una media. Opcionalmente también el tiempo del saludo TLS (HTTPS).
- **Modo continuo**: rondas cada 10 s a 10 min para ver la evolución en el tiempo.
- **Gráficos**: ranking horizontal con bigote P95, evolución por ronda y comparativa Azure frente a AWS por geografía.
- **Exportaciones**:
  - **Excel (.xlsx)** sin necesitar Excel ni módulos externos: hojas Resumen (con escala de color), Gráficos (barras y columnas nativas y editables), Azure vs AWS, Evolución (gráfico de líneas), Mediciones y Regiones. Todo en tablas de Excel, listas para tablas dinámicas.
  - **Power BI**: libro con todo el **histórico** en modelo en estrella (Mediciones, Regiones con latitud y longitud, Sesiones), un archivo `.pbids` que lo abre en Power BI Desktop, las medidas DAX y una guía paso a paso. Alternativa: consultas de Power Query que leen el histórico en CSV directamente.
  - **CSV** e **informe HTML** autocontenido (modo claro y oscuro).
- **Etiquetas** ("Oficina · fibra", "Casa · VPN"…) para comparar redes en Excel o Power BI.
- **Modo claro u oscuro**, interfaz en español.
- **No necesita administrador** y no instala nada.

## Cómo mide

Para cada región abre conexiones TCP al puerto 443 de un endpoint **regional** y cronometra el establecimiento de la conexión. Ese tiempo equivale aproximadamente a un viaje de ida y vuelta (RTT) y no depende de la velocidad de descarga. La DNS se resuelve antes de medir y se hace una conexión de calentamiento que no cuenta.

| Nube | Endpoint |
|------|----------|
| Azure | `<región>.api.cognitive.microsoft.com` (Azure AI services) |
| AWS | `dynamodb.<región>.amazonaws.com` |

Es la misma idea que usan otros medidores web, pero desde la red real del equipo (VPN, proxy, Wi-Fi…) y sin las limitaciones del navegador. Si quieres la máxima precisión en Azure, puedes cambiar el `host` de una región por una cuenta de almacenamiento propia de esa región.

## Requisitos

- Windows 10 u 11 con Windows PowerShell 5.1 (incluido en Windows).
- Salida a Internet por el puerto 443.
- Para Power BI: Power BI Desktop (gratuito).

## Inicio rápido

1. Ejecuta `Eureka_CloudSpeed.cmd`, o `Eureka_CloudSpeed.exe` si has compilado el lanzador.
2. Elige las nubes y geografías y pulsa **Iniciar**.
3. Exporta con **Excel con gráficos** o **Power BI (histórico)**.

### Sin interfaz (tareas programadas)

```powershell
.\Eureka_CloudSpeed.cmd -SinInterfaz -Geografia Europa -Muestras 5 -Exportar Excel,Html
.\Eureka_CloudSpeed.cmd -SinInterfaz -Etiqueta "Oficina" -Rondas 12 -Intervalo 300 -Exportar PowerBI
```

| Parámetro | Descripción |
|-----------|-------------|
| `-SinInterfaz` | Mide desde la consola y muestra el ranking. |
| `-Nube`, `-Geografia`, `-Region` | Filtros (listas separadas por comas). |
| `-Muestras` | Muestras por región y ronda (1-50, por defecto 5). |
| `-Rondas`, `-Intervalo` | Número de rondas y segundos entre ellas. |
| `-Tls` | Mide también el saludo TLS. |
| `-Etiqueta` | Texto para distinguir redes o ubicaciones. |
| `-Exportar` | `Excel`, `Csv`, `Html`, `PowerBI`. |
| `-SinHistorico` | No añade las mediciones al histórico. |

## Carpetas de datos

| Carpeta | Contenido |
|---------|-----------|
| `Datos\` | Histórico acumulado (`Mediciones.csv`, `Regiones.csv`, `Sesiones.csv`), que es la fuente de Power BI. |
| `Exportaciones\` | Excel, CSV, HTML y la carpeta `PowerBI\`. |
| `Config\` | Preferencias de la interfaz. |

Con el ejecutable portable, estas carpetas se crean en `Eureka_CloudSpeed_Datos`, junto al .exe.

## Compilar los ejecutables

```powershell
powershell -ExecutionPolicy Bypass -File .\Build\Build-Exe.ps1
```

Genera `Eureka_CloudSpeed.exe` (lanzador con verificación de integridad), `Dist\Eureka_CloudSpeed_Portable.exe` (un único archivo) y `Dist\Eureka_CloudSpeed.zip`. Sin firma de código, Smart App Control puede bloquearlos; en ese caso usa `Eureka_CloudSpeed.cmd`.

## Estructura

```
Catalog\               Regiones medibles, referencia de regiones, latencia entre regiones, especificaciones de VM, mapa y entornos
Engine\*.cs            Medición, test de velocidad, rangos de IP, gráficos y escritor de Excel (C# compilado en memoria al arrancar)
Modules\               Core (rutas, catálogo, preferencias) y Export (Excel, CSV, HTML, Power BI)
UI\                    Ventana (MainWindow.xaml), tema (Theme.xaml), armazón (Shell.ps1) y latencia (Gui.ps1)
UI\Pages\              Una página XAML + script por sección
Herramientas\          Scripts de Azure y AWS para el test de velocidad, prueba automática (crea, mide y borra),
                       firma SigV4, política IAM mínima y verificación de cumplimiento
Docs\                  Manual de uso, documentación técnica, bitácora de versiones y revisión de seguridad
PowerBI\               Medidas DAX, consultas de Power Query y guía
Build\                 Lanzador y script de compilación
```

## Privacidad

No incluye telemetría y los resultados se quedan en tu equipo. Solo se conecta a:

- los endpoints regionales de Azure y AWS que mides (abre la conexión, opcionalmente hace el saludo TLS y la cierra);
- las fuentes públicas de precios (`prices.azure.com` y la lista de precios de EC2) y de rangos de IP (Microsoft Download Center e `ip-ranges.amazonaws.com`), cuando abres esas secciones;
- las páginas de estado públicas de Microsoft, AWS, Google, GitHub y Cloudflare y los servicios que se comprueban (más `wikipedia.org` como control), solo al abrir **Estado de servicios** o con la comprobación automática activada;
- tus propias cuentas de almacenamiento, en el test de velocidad;
- `ipinfo.io`, solo si pulsas **Ver mi conexión**.

El histórico se conserva 12 meses por defecto (configurable) y se puede borrar entero desde **Ayuda → Privacidad: tus datos**.

*This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.*

Las URL del test de velocidad (SAS de Azure y firmas de S3) se guardan **cifradas con DPAPI** en `Config\velocidad.json`: solo tu usuario de Windows en este equipo puede usarlas. Ese archivo está excluido de git y de los ejecutables. Para compartir informes sin identificar el equipo, activa **Ocultar el nombre del equipo** (o `-Anonimo` en consola).

La revisión completa de seguridad, confidencialidad y buenas prácticas de Azure y AWS está en [`Docs/Revision-seguridad-y-confidencialidad.html`](Docs/Revision-seguridad-y-confidencialidad.html).

### Endpoints del test de velocidad

| Nube | Script | Requisitos | Mantenimiento |
|------|--------|------------|---------------|
| Azure | `Herramientas\Crear-CuentasVelocidad.ps1 -Regiones westeurope,spaincentral` | Azure CLI y permiso de Colaborador en el grupo de recursos | `-Renovar` (amplía la caducidad), `-Revocar` (invalida al momento), `-RotarClaves`, `-Eliminar` |
| AWS | `Herramientas\Crear-BucketsVelocidad.ps1 -Regiones eu-south-2,eu-west-1` | AWS CLI v2 y la política `Herramientas\aws-iam-politica-minima.json` | `-Renovar` cada 7 días como máximo (límite de AWS), `-Eliminar` |

## Fuentes de datos y licencias

- Datos de regiones, zonas, latencia entre regiones y especificaciones de VM: [azure-speed-test](https://github.com/blrchen/azure-speed-test) de blrchen, licencia MIT (`Catalog\LICENSE-azure-speed-test.txt`), basados en datos publicados por Microsoft.
- Mapa: [Natural Earth](https://www.naturalearthdata.com/) (dominio público) a través de world-atlas (licencia ISC).
- Precios y rangos de IP: se consultan en vivo en las fuentes oficiales de Microsoft y AWS.

## Pruebas en la nube sin costes residuales

```powershell
.\Herramientas\Probar-Velocidad.ps1 -Nube AWS -Region eu-north-1
.\Herramientas\Probar-Velocidad.ps1 -Nube Azure -Region westeurope [-Tenant <directorio>]
```

Crea el almacenamiento, mide, **lo borra siempre** (aunque falle) y comprueba que no queda nada que genere cargos. Al final pregunta si quieres mantener la sesión de la CLI o cerrarla.

## Documentación

- [Manual de uso](Docs/Manual-de-usuario.html)
- [Documentación técnica](Docs/Documentacion-tecnica.html)
- [Bitácora de versiones](Docs/Bitacora-de-versiones.html) (y [CHANGELOG.md](CHANGELOG.md))
- [Revisión de seguridad y confidencialidad v2](Docs/Revision-seguridad-y-confidencialidad.html) · verificación automática: `Herramientas\Verificar-Cumplimiento.ps1`

## Autor

Juan Raúl Ruiz · [LinkedIn](https://www.linkedin.com/in/juanraulruizbartran)

## Política de firma de código (Code signing policy)

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org) *(solicitud en trámite: hasta su aprobación, las releases se publican sin firmar)*.

Firma de código gratuita proporcionada por SignPath.io, certificado de SignPath Foundation.

- Los ejecutables publicados en *Releases* se compilan, prueban (`Tests/Run-Tests.ps1`) y firman automáticamente en **GitHub Actions** (`.github/workflows/release.yml`) a partir del código de este repositorio; nunca se firman binarios compilados fuera de ese proceso.
- **Equipo y funciones**
  - Autores (*committers*) y revisores (*reviewers*): [juanraul86](https://github.com/juanraul86)
  - Aprobadores de la firma (*approvers*): [juanraul86](https://github.com/juanraul86)
- Cada solicitud de firma la aprueba manualmente un aprobador. Las cuentas del equipo usan autenticación multifactor.
- Las versiones publicadas antes de activar la firma se indican como "sin firmar" en sus notas.
- Detalles del proceso: [`FIRMA-DE-CODIGO.md`](FIRMA-DE-CODIGO.md).

## Licencia

[MIT](LICENSE). Los datos de terceros incluidos mantienen sus licencias (ver *Fuentes de datos y licencias*).
