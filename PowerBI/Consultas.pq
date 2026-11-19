// Eureka_CloudSpeed · Consultas de Power Query (alternativa a abrir el libro de Excel).
// Leen directamente el histórico en CSV de la carpeta Datos, así no hace falta volver a exportar:
// basta con pulsar Actualizar en Power BI Desktop después de medir.
//
// Cómo usarlas en Power BI Desktop:
//   Inicio > Transformar datos > Nuevo origen > Consulta en blanco > Editor avanzado,
//   pega UN bloque, pulsa Listo y cambia el nombre de la consulta al que se indica en el bloque.
//   Empieza por el parámetro CarpetaDatos.

// ===== Consulta: CarpetaDatos (parámetro con la ruta de la carpeta Datos)
"__CARPETA_DATOS__" meta [IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true]

// ===== Consulta: Mediciones
let
    Origen = Csv.Document(File.Contents(CarpetaDatos & "\Mediciones.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Encabezados = Table.PromoteHeaders(Origen, [PromoteAllScalars = true]),
    Tipos = Table.TransformColumnTypes(Encabezados, {
        {"SesionId", type text}, {"FechaHora", type datetime}, {"Ronda", Int64.Type}, {"Clave", type text},
        {"Nube", type text}, {"Código", type text}, {"IP", type text}, {"TCP_ms", type number}, {"TLS_ms", type number},
        {"Correcto", type logical}, {"Error", type text}, {"Equipo", type text}, {"Etiqueta", type text}}, "en-US"),
    Fecha = Table.AddColumn(Tipos, "Fecha", each DateTime.Date([FechaHora]), type date),
    Hora = Table.AddColumn(Fecha, "Hora", each Time.ToText(DateTime.Time([FechaHora]), "HH:mm"), type text)
in
    Hora

// ===== Consulta: Regiones
let
    Origen = Csv.Document(File.Contents(CarpetaDatos & "\Regiones.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Encabezados = Table.PromoteHeaders(Origen, [PromoteAllScalars = true]),
    Tipos = Table.TransformColumnTypes(Encabezados, {{"Latitud", type number}, {"Longitud", type number}}, "en-US")
in
    Tipos

// ===== Consulta: Sesiones
let
    Origen = Csv.Document(File.Contents(CarpetaDatos & "\Sesiones.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Encabezados = Table.PromoteHeaders(Origen, [PromoteAllScalars = true]),
    Tipos = Table.TransformColumnTypes(Encabezados, {{"Inicio", type datetime}, {"Muestras", Int64.Type}, {"TLS", type logical}}, "en-US"),
    SinDuplicados = Table.Distinct(Tipos, {"SesionId"})
in
    SinDuplicados
