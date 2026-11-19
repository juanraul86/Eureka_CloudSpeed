# Firma de código gratuita con SignPath Foundation

Guía para que los ejecutables de Eureka_CloudSpeed se publiquen **firmados digitalmente sin coste**, de forma que Windows (Smart App Control y SmartScreen) confíe en ellos.

SignPath Foundation firma gratis proyectos de **código abierto**. El certificado está a nombre de *SignPath Foundation* e indica el proyecto. La firma no se hace en tu PC: se hace en GitHub Actions, para garantizar que el ejecutable sale exactamente del código público.

## Lo que ya está preparado en el repositorio

| Requisito de SignPath | Dónde está |
|---|---|
| Repositorio público con licencia de código abierto (OSI) | `LICENSE` (MIT) |
| Compilación automática y reproducible en CI, con pruebas | `.github/workflows/release.yml` y `Tests/Run-Tests.ps1` |
| Política de firma de código, funciones del equipo y privacidad publicadas | `README.md` (secciones *Política de firma de código* y *Privacidad*) |
| Configuración de qué se firma | `.signpath/artifact-configuration.xml` |
| Publicación sin firmar mientras no haya aprobación | El flujo solo firma si existe la variable `SIGNPATH_ORGANIZATION_ID` |

## Pasos que tienes que hacer tú

1. **Activa la autenticación multifactor en GitHub** (Settings > Password and authentication), si aún no la tienes. SignPath la exige al equipo del proyecto.
2. **Comprueba que el repositorio es público** y que tiene al menos una release publicada (la v1.3.0 se publica al subir la etiqueta).
3. **Revisa y envía la solicitud** en <https://signpath.org/apply> (el formulario se deja rellenado; el envío lo confirmas tú). Datos del proyecto:
   - Proyecto: **Eureka_CloudSpeed**. Repositorio: `https://github.com/juanraul86/Eureka_CloudSpeed`.
   - Descripción: *Herramienta portable de código abierto para Windows que mide desde el equipo del usuario la latencia y la velocidad hacia las regiones de Microsoft Azure y AWS, vigila el estado de sus servicios y exporta los resultados a Excel y Power BI.*
   - Licencia: MIT. Lenguaje: PowerShell y C#. CI: GitHub Actions.
   - Artefactos a firmar: `Eureka_CloudSpeed.exe` y `Eureka_CloudSpeed_Portable.exe` (Authenticode).
4. **Espera la aprobación.** SignPath revisa el proyecto a mano (suele tardar unos días o semanas) y crea para ti una organización en SignPath.io.
5. **Configura el proyecto en SignPath.io**, siguiendo sus indicaciones:
   - Crea el proyecto con *slug* `Eureka_CloudSpeed` y conecta el repositorio de GitHub (*Trusted Build System* de GitHub).
   - En *Artifact configurations*, crea una con el contenido de `.signpath/artifact-configuration.xml` (por ejemplo, con *slug* `initial`).
   - Usa la política de firma `release-signing` que te asignen (o la que indiquen) y añade tu usuario como aprobador.
   - Crea un **API token** para un usuario de CI con permiso de enviar solicitudes en ese proyecto.
6. **Añade los datos en GitHub** (repositorio > Settings > Secrets and variables > Actions):
   - *Secret* `SIGNPATH_API_TOKEN` = el token de SignPath.
   - *Variables*:
     - `SIGNPATH_ORGANIZATION_ID` = el id de tu organización en SignPath (un GUID).
     - `SIGNPATH_PROJECT_SLUG` = `Eureka_CloudSpeed`
     - `SIGNPATH_SIGNING_POLICY_SLUG` = `release-signing` (o el que te asignen)
     - `SIGNPATH_ARTIFACT_CONFIGURATION_SLUG` = `initial` (o el que hayas creado)
7. **Publica una versión firmada**: crea y sube una etiqueta nueva (por ejemplo `v1.3.1`). Cada intento de firma necesita un número nuevo:

   ```powershell
   git tag -a v1.3.1 -m "Eureka_CloudSpeed 1.3.1"
   git push origin v1.3.1
   ```

   GitHub Actions ejecuta las pruebas, compila, envía la solicitud a SignPath, espera a que la apruebes en SignPath.io (recibirás un aviso) y publica en la release los ejecutables **firmados**.

## Comprobar la firma

```powershell
Get-AuthenticodeSignature .\Eureka_CloudSpeed_Portable.exe | Format-List Status, SignerCertificate
```

`Status` debe ser `Valid` y el firmante, *SignPath Foundation*. Después vuelve a ejecutar `Herramientas\Verificar-Cumplimiento.ps1`: el control R1 pasará a OK.

## Mientras no haya firma

Las releases se publican sin firmar y el flujo lo indica en su registro. En equipos con Smart App Control, usa `Eureka_CloudSpeed.cmd` del código fuente.
