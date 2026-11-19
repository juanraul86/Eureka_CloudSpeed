// Reports.cs - Histórico en CSV, informe de Excel de la sesión y libro de datos para Power BI.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace CloudSpeed
{
    public static class Store
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public static readonly string[] SampleHeader = { "SesionId", "FechaHora", "Ronda", "Clave", "Nube", "Código", "IP", "TCP_ms", "TLS_ms", "Correcto", "Error", "Equipo", "Etiqueta" };
        public static readonly string[] RegionHeader = { "Clave", "Nube", "Código", "Región", "Geografía", "País", "Ciudad", "Latitud", "Longitud", "Host" };
        public static readonly string[] SessionHeader = { "SesionId", "Inicio", "Equipo", "Etiqueta", "Muestras", "TLS", "Versión" };

        static string Q(string s)
        {
            if (s == null) return "";
            // Evita la inyección de fórmulas al abrir el CSV en Excel (=, +, -, @, tabulador, retorno)
            if (s.Length > 0 && "=+-@\t\r".IndexOf(s[0]) >= 0) s = "'" + s;
            if (s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) >= 0) return "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }
        static string D(double v) { return double.IsNaN(v) ? "" : Math.Round(v, 3).ToString("0.###", Inv); }

        static void AppendLines(string path, string[] header, IEnumerable<string> lines)
        {
            string dir = Path.GetDirectoryName(Path.GetFullPath(path));
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            bool exists = File.Exists(path) && new FileInfo(path).Length > 0;
            using (StreamWriter w = new StreamWriter(path, true, new UTF8Encoding(!exists)))
            {
                if (!exists) w.WriteLine(string.Join(",", header.Select(Q)));
                foreach (string l in lines) w.WriteLine(l);
            }
        }

        public static string SampleLine(Sample s, string machine, string label)
        {
            return string.Join(",", new[] {
                Q(s.SessionId), s.Time.ToString("yyyy-MM-ddTHH:mm:ss.fff", Inv), s.Round.ToString(Inv), Q(s.Region.Key), Q(s.Region.Cloud), Q(s.Region.Code),
                Q(s.Ip), D(s.TcpMs), D(s.TlsMs), s.Ok ? "true" : "false", Q(s.Error), Q(machine), Q(label) });
        }

        public static void AppendSamples(string path, IEnumerable<Sample> samples, string machine, string label)
        {
            AppendLines(path, SampleHeader, samples.Select(s => SampleLine(s, machine, label)));
        }

        public static void AppendSession(string path, string sid, DateTime start, string machine, string label, int samples, bool tls, string version)
        {
            AppendLines(path, SessionHeader, new[] { string.Join(",", new[] { Q(sid), start.ToString("yyyy-MM-ddTHH:mm:ss", Inv), Q(machine), Q(label), samples.ToString(Inv), tls ? "true" : "false", Q(version) }) });
        }

        public static void WriteRegions(string path, IEnumerable<RegionInfo> regions)
        {
            if (File.Exists(path)) File.Delete(path);
            AppendLines(path, RegionHeader, regions.Select(r => string.Join(",", new[] {
                Q(r.Key), Q(r.Cloud), Q(r.Code), Q(r.Name), Q(r.Geo), Q(r.Country), Q(r.City), r.Lat.ToString("0.####", Inv), r.Lon.ToString("0.####", Inv), Q(r.Host) })));
        }

        public static void WriteSamples(string path, IEnumerable<Sample> samples, string machine, string label)
        {
            if (File.Exists(path)) File.Delete(path);
            AppendSamples(path, samples, machine, label);
        }

        /// <summary>Lee un CSV propio (RFC 4180). Devuelve encabezado + filas.</summary>
        public static List<string[]> Read(string path)
        {
            List<string[]> rows = new List<string[]>();
            if (!File.Exists(path)) return rows;
            string text;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (StreamReader r = new StreamReader(fs, Encoding.UTF8, true)) text = r.ReadToEnd();
            List<string> cur = new List<string>(); StringBuilder f = new StringBuilder(); bool q = false;
            for (int i = 0; i < text.Length; i++)
            {
                char ch = text[i];
                if (q)
                {
                    if (ch == '"') { if (i + 1 < text.Length && text[i + 1] == '"') { f.Append('"'); i++; } else q = false; }
                    else f.Append(ch);
                }
                else if (ch == '"') q = true;
                else if (ch == ',') { cur.Add(f.ToString()); f.Clear(); }
                else if (ch == '\r') { }
                else if (ch == '\n') { cur.Add(f.ToString()); f.Clear(); rows.Add(cur.ToArray()); cur.Clear(); }
                else f.Append(ch);
            }
            if (f.Length > 0 || cur.Count > 0) { cur.Add(f.ToString()); rows.Add(cur.ToArray()); }
            return rows;
        }
    }

    public static class ExcelReport
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static object N(double? v) { return v.HasValue ? (object)new XCell(v.Value, XS.Dec1) : null; }
        static object H(string s) { return new XCell(s, XS.Bold); }

        /// <summary>Informe de la sesión: resumen, gráficos, comparativa, evolución, mediciones y regiones.</summary>
        public static void Build(string path, IList<RegionRow> allRows, IList<string> geos, IList<string> clouds, IDictionary<string, string> cloudColors,
                                 IList<KeyValuePair<string, string>> meta, string machine, string label)
        {
            List<RegionRow> rows = allRows.Where(r => r.Count > 0).OrderBy(r => r.SortKey).ThenBy(r => r.Label).ToList();
            if (rows.Count == 0) throw new InvalidOperationException("No hay mediciones que exportar.");
            XWorkbook wb = new XWorkbook();

            // ---------------- Resumen
            XSheet res = wb.AddSheet("Resumen");
            res.Add(new XCell("Latencia a regiones de Azure y AWS", XS.Title));
            res.Add(new XCell("Generado con Eureka_CloudSpeed. Latencia = tiempo de conexión TCP al puerto 443 del endpoint regional (≈ 1 viaje de ida y vuelta).", XS.Note));
            foreach (KeyValuePair<string, string> kv in meta) res.Add(H(kv.Key), kv.Value);
            res.Add();
            string[] hdr = { "Puesto", "Región", "Nube", "Código", "Nombre", "Geografía", "País", "Ciudad", "P50 (ms)", "Media (ms)", "P95 (ms)", "Mín (ms)", "Máx (ms)", "Jitter (ms)", "Pérdida", "Muestras", "TLS P50 (ms)" };
            int h0 = res.Add(hdr.Cast<object>().ToArray());
            int rank = 0;
            foreach (RegionRow r in rows)
            {
                res.Add(r.P50.HasValue ? (object)(++rank) : null, r.Label, r.Cloud, r.Code, r.Name, r.Geo, r.Info.Country, r.Info.City,
                    N(r.P50), N(r.Avg), N(r.P95), N(r.Min), N(r.Max), N(r.Jitter), r.Loss.HasValue ? new XCell(r.Loss.Value, XS.Pct) : null, r.Count, N(r.TlsP50));
            }
            int h1 = res.Rows.Count - 1;
            res.Tables.Add(new XTable { Name = "TablaResumen", Row0 = h0, Col0 = 0, Row1 = h1, Col1 = hdr.Length - 1 });
            res.ColorScales.Add("I" + (h0 + 2) + ":I" + (h1 + 1));
            res.ColorScales.Add("K" + (h0 + 2) + ":K" + (h1 + 1));
            res.FreezeRows = h0 + 1;
            double[] widths = { 8, 34, 8, 20, 26, 15, 22, 20, 10, 11, 10, 10, 10, 11, 9, 10, 13 };
            for (int i = 0; i < widths.Length; i++) res.Widths[i] = widths[i];

            // ---------------- Azure vs AWS por geografía
            XSheet cmp = wb.AddSheet("Azure vs AWS");
            List<object> ch = new List<object> { "Geografía" };
            foreach (string c in clouds) { ch.Add(c + " mejor P50 (ms)"); ch.Add(c + " mejor región"); }
            int c0 = cmp.Add(ch.ToArray());
            foreach (string g in geos)
            {
                if (!rows.Any(r => r.Geo == g && r.P50.HasValue)) continue;
                List<object> line = new List<object> { g };
                foreach (string c in clouds)
                {
                    RegionRow best = rows.Where(r => r.Geo == g && r.Cloud == c && r.P50.HasValue).OrderBy(r => r.P50.Value).FirstOrDefault();
                    line.Add(best == null ? null : N(best.P50)); line.Add(best == null ? null : best.Name + " (" + best.Code + ")");
                }
                cmp.Add(line.ToArray());
            }
            int c1 = cmp.Rows.Count - 1;
            bool hasCmp = c1 > c0;
            if (hasCmp) cmp.Tables.Add(new XTable { Name = "TablaComparativa", Row0 = c0, Col0 = 0, Row1 = c1, Col1 = ch.Count - 1 });
            cmp.Widths[0] = 16; for (int i = 1; i < ch.Count; i++) cmp.Widths[i] = i % 2 == 1 ? 20 : 34;

            // ---------------- Gráficos (primera hoja visual)
            XSheet gr = wb.AddSheet("Gráficos");
            gr.Add(new XCell("Gráficos", XS.Title));
            gr.Add(new XCell("Los gráficos leen los datos de las hojas Resumen y Azure vs AWS: puedes editarlos, copiarlos o cambiar su estilo en Excel.", XS.Note));
            List<RegionRow> measured = rows.Where(r => r.P50.HasValue).ToList();
            int top = Math.Min(25, measured.Count);
            if (top > 0)
            {
                XSeries s = new XSeries { Name = "P50 (ms)", ValCol = 8, Color = cloudColors.Values.First(), PointColors = new List<string>() };
                foreach (RegionRow r in measured.Take(top)) s.PointColors.Add(cloudColors.ContainsKey(r.Cloud) ? cloudColors[r.Cloud] : s.Color);
                XChart bar = new XChart { Kind = "bar", Title = "Las " + top + " regiones más rápidas (P50, ms)", AxisTitle = "ms", DataSheet = res, CatCol = 1, Row0 = h0 + 1, Row1 = h0 + top, Labels = true, Reverse = true, FromCol = 0, FromRow = 3, ToCol = 12, ToRow = 3 + Math.Max(18, top + 6) };
                bar.Series.Add(s);
                gr.Charts.Add(bar);
            }
            if (hasCmp)
            {
                XChart col = new XChart { Kind = "column", Title = "Mejor región por geografía", AxisTitle = "ms (P50)", DataSheet = cmp, CatCol = 0, Row0 = c0 + 1, Row1 = c1, Labels = true, Legend = true, FromCol = 13, FromRow = 3, ToCol = 24, ToRow = 24 };
                for (int i = 0; i < clouds.Count; i++) col.Series.Add(new XSeries { Name = clouds[i], ValCol = 1 + i * 2, Color = cloudColors.ContainsKey(clouds[i]) ? cloudColors[clouds[i]] : "#64748B" });
                gr.Charts.Add(col);
            }

            // ---------------- Evolución por ronda (las 6 mejores)
            List<RegionRow> best6 = measured.Take(6).ToList();
            List<Sample> samples = rows.SelectMany(r => r.Samples).OrderBy(x => x.Time).ToList();
            List<int> rounds = samples.Select(x => x.Round).Distinct().OrderBy(x => x).ToList();
            XSheet evo = wb.AddSheet("Evolución");
            List<object> eh = new List<object> { "Ronda", "Hora" };
            foreach (RegionRow r in best6) eh.Add(r.Label);
            int e0 = evo.Add(eh.ToArray());
            foreach (int rd in rounds)
            {
                DateTime t = samples.Where(x => x.Round == rd).Min(x => x.Time);
                List<object> line = new List<object> { rd, t.ToString("HH:mm:ss", Inv) };
                foreach (RegionRow r in best6) { double m = r.RoundMedian(rd); line.Add(double.IsNaN(m) ? null : new XCell(Math.Round(m, 1), XS.Dec1)); }
                evo.Add(line.ToArray());
            }
            int e1 = evo.Rows.Count - 1;
            evo.Tables.Add(new XTable { Name = "TablaEvolucion", Row0 = e0, Col0 = 0, Row1 = e1, Col1 = eh.Count - 1 });
            evo.Widths[0] = 8; evo.Widths[1] = 10; for (int i = 2; i < eh.Count; i++) evo.Widths[i] = 26;
            if (best6.Count > 0)
            {
                string[] pal = { "#2F80ED", "#F59E0B", "#10B981", "#EF4444", "#8B5CF6", "#EC4899" };
                XChart ln = new XChart { Kind = "line", Title = rounds.Count > 1 ? "Evolución de la latencia (mediana por ronda)" : "Evolución (solo una ronda: usa el modo continuo)", AxisTitle = "ms", DataSheet = evo, CatCol = 1, Row0 = e0 + 1, Row1 = e1, Legend = true, FromCol = eh.Count + 1, FromRow = 0, ToCol = eh.Count + 13, ToRow = 22 };
                for (int i = 0; i < best6.Count; i++) ln.Series.Add(new XSeries { Name = best6[i].Label, ValCol = 2 + i, Color = pal[i] });
                evo.Charts.Add(ln);
            }

            // ---------------- Mediciones (datos en bruto)
            XSheet med = wb.AddSheet("Mediciones");
            string[] mh = { "FechaHora", "Ronda", "Nube", "Código", "Región", "Geografía", "Ciudad", "IP", "TCP (ms)", "TLS (ms)", "Correcto", "Error", "Equipo", "Etiqueta", "Sesión" };
            int m0 = med.Add(mh.Cast<object>().ToArray());
            foreach (Sample x in samples)
                med.Add(x.Time, x.Round, x.Region.Cloud, x.Region.Code, x.Region.Name, x.Region.Geo, x.Region.City, x.Ip,
                    double.IsNaN(x.TcpMs) ? null : new XCell(Math.Round(x.TcpMs, 2), XS.Dec1), double.IsNaN(x.TlsMs) ? null : new XCell(Math.Round(x.TlsMs, 2), XS.Dec1),
                    x.Ok, x.Error, machine, label, x.SessionId);
            med.Tables.Add(new XTable { Name = "TablaMediciones", Row0 = m0, Col0 = 0, Row1 = med.Rows.Count - 1, Col1 = mh.Length - 1 });
            med.FreezeRows = 1;
            double[] mw = { 19, 7, 7, 20, 24, 14, 16, 15, 9, 9, 9, 24, 16, 16, 14 };
            for (int i = 0; i < mw.Length; i++) med.Widths[i] = mw[i];

            // ---------------- Regiones
            XSheet reg = wb.AddSheet("Regiones");
            AddRegions(reg, allRows.Select(r => r.Info), "TablaRegiones");

            wb.Sheets.Remove(gr); wb.Sheets.Insert(1, gr);   // Resumen, Gráficos, Azure vs AWS, ...
            wb.Save(path);
        }

        internal static void AddRegions(XSheet reg, IEnumerable<RegionInfo> regions, string table)
        {
            int r0 = reg.Add(Store.RegionHeader.Cast<object>().ToArray());
            foreach (RegionInfo r in regions)
                reg.Add(r.Key, r.Cloud, r.Code, r.Name, r.Geo, r.Country, r.City, r.Lat, r.Lon, r.HasEndpoint ? r.Host : "(sin endpoint)");
            reg.Tables.Add(new XTable { Name = table, Row0 = r0, Col0 = 0, Row1 = reg.Rows.Count - 1, Col1 = Store.RegionHeader.Length - 1, Style = "TableStyleMedium9" });
            reg.FreezeRows = 1;
            double[] w = { 26, 7, 20, 24, 14, 22, 20, 9, 9, 40 };
            for (int i = 0; i < w.Length; i++) reg.Widths[i] = w[i];
        }
    }

    /// <summary>Libro de datos para Power BI construido con TODO el histórico (modelo en estrella).</summary>
    public static class PowerBiBook
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        public static int Build(string dataDir, string path, IEnumerable<RegionInfo> regions)
        {
            XWorkbook wb = new XWorkbook();
            XSheet med = wb.AddSheet("Mediciones");
            List<string[]> rows = Store.Read(Path.Combine(dataDir, "Mediciones.csv"));
            if (rows.Count < 2) throw new InvalidOperationException("Todavía no hay histórico de mediciones (Datos\\Mediciones.csv).");
            string[] h = { "SesionId", "FechaHora", "Fecha", "Hora", "Ronda", "Clave", "Nube", "Código", "IP", "TCP_ms", "TLS_ms", "Correcto", "Error", "Equipo", "Etiqueta" };
            med.Add(h.Cast<object>().ToArray());
            int n = 0;
            for (int i = 1; i < rows.Count; i++)
            {
                string[] r = rows[i];
                if (r.Length < 13) continue;
                DateTime t;
                if (!DateTime.TryParse(r[1], Inv, DateTimeStyles.AssumeLocal, out t)) continue;
                med.Add(r[0], t, new XCell(t.Date, XS.Date), t.ToString("HH:mm", Inv), Int(r[2]), r[3], r[4], r[5], r[6], Dbl(r[7]), Dbl(r[8]), r[9] == "true", r[10], r[11], r[12]);
                n++;
            }
            med.Tables.Add(new XTable { Name = "Mediciones", Row0 = 0, Col0 = 0, Row1 = med.Rows.Count - 1, Col1 = h.Length - 1 });
            med.FreezeRows = 1;
            double[] mw = { 14, 19, 11, 7, 7, 26, 7, 20, 15, 9, 9, 9, 24, 16, 16 };
            for (int i = 0; i < mw.Length; i++) med.Widths[i] = mw[i];

            XSheet reg = wb.AddSheet("Regiones");
            ExcelReport.AddRegions(reg, regions, "Regiones");

            XSheet ses = wb.AddSheet("Sesiones");
            List<string[]> srows = Store.Read(Path.Combine(dataDir, "Sesiones.csv"));
            ses.Add(Store.SessionHeader.Cast<object>().ToArray());
            HashSet<string> seen = new HashSet<string>();
            for (int i = 1; i < srows.Count; i++)
            {
                string[] r = srows[i];
                if (r.Length < 7 || !seen.Add(r[0])) continue;
                DateTime t; DateTime.TryParse(r[1], Inv, DateTimeStyles.AssumeLocal, out t);
                ses.Add(r[0], t, r[2], r[3], Int(r[4]), r[5] == "true", r[6]);
            }
            if (ses.Rows.Count == 1) ses.Add("-", DateTime.Now, "", "", 0, false, "");
            ses.Tables.Add(new XTable { Name = "Sesiones", Row0 = 0, Col0 = 0, Row1 = ses.Rows.Count - 1, Col1 = Store.SessionHeader.Length - 1, Style = "TableStyleMedium7" });
            ses.FreezeRows = 1;
            double[] sw = { 14, 19, 18, 20, 9, 7, 9 };
            for (int i = 0; i < sw.Length; i++) ses.Widths[i] = sw[i];

            wb.Save(path);
            return n;
        }

        static object Dbl(string s) { double d; return double.TryParse(s, NumberStyles.Float, Inv, out d) ? (object)d : null; }
        static object Int(string s) { int d; return int.TryParse(s, NumberStyles.Integer, Inv, out d) ? (object)d : null; }
    }
}
