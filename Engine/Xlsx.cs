// Xlsx.cs - Escritor mínimo de libros de Excel (.xlsx, Office Open XML) sin dependencias:
// hojas, tablas de Excel (aptas para tablas dinámicas y Power BI), escalas de color y gráficos nativos
// (barras, columnas y líneas) que Excel puede editar después.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security;
using System.Text;

namespace CloudSpeed
{
    /// <summary>Estilos predefinidos (índices de cellXfs).</summary>
    public static class XS
    {
        public const int Normal = 0, Header = 1, Dec1 = 2, Pct = 3, Date = 4, Title = 5, Bold = 6, Int = 7, Note = 8;
    }

    public class XCell
    {
        public object V; public int S;
        public XCell(object v, int s) { V = v; S = s; }
    }

    public class XTable
    {
        public string Name; public int Row0, Col0, Row1, Col1;   // 0-based, Row0 = fila de encabezados
        public string Style = "TableStyleMedium2";
    }

    public class XSeries
    {
        public string Name; public int ValCol; public string Color;
        public List<string> PointColors;   // color por punto (opcional)
    }

    public class XChart
    {
        public string Kind = "bar";   // bar (horizontal), column, line
        public string Title, AxisTitle;
        public XSheet DataSheet; public int CatCol, Row0, Row1;   // filas de datos 0-based inclusive
        public List<XSeries> Series = new List<XSeries>();
        public int FromCol, FromRow, ToCol, ToRow;
        public bool Legend, Labels, Reverse;
    }

    public class XSheet
    {
        public string Name;
        public List<object[]> Rows = new List<object[]>();
        public Dictionary<int, double> Widths = new Dictionary<int, double>();
        public int FreezeRows;
        public List<XTable> Tables = new List<XTable>();
        public List<XChart> Charts = new List<XChart>();
        public List<string> ColorScales = new List<string>();     // rangos A1 (verde = bajo, rojo = alto)
        public XSheet(string name) { Name = name; }
        public int Add(params object[] cells) { Rows.Add(cells); return Rows.Count - 1; }
        public object Get(int r, int c)
        {
            if (r < 0 || r >= Rows.Count || Rows[r] == null || c >= Rows[r].Length) return null;
            object v = Rows[r][c]; XCell x = v as XCell; return x != null ? x.V : v;
        }
    }

    public class XWorkbook
    {
        public List<XSheet> Sheets = new List<XSheet>();
        public string Creator = "Eureka_CloudSpeed";
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        const string NsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
        const string NsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        const string NsPkgRel = "http://schemas.openxmlformats.org/package/2006/relationships";
        const string NsC = "http://schemas.openxmlformats.org/drawingml/2006/chart";
        const string NsA = "http://schemas.openxmlformats.org/drawingml/2006/main";

        public XSheet AddSheet(string name) { XSheet s = new XSheet(name); Sheets.Add(s); return s; }

        public static string Col(int c) { string s = ""; c++; while (c > 0) { int m = (c - 1) % 26; s = (char)('A' + m) + s; c = (c - 1) / 26; } return s; }
        public static string Ref(int r, int c) { return Col(c) + (r + 1).ToString(Inv); }
        static string AbsRef(XSheet s, int r0, int c0, int r1, int c1)
        {
            string a = "'" + s.Name.Replace("'", "''") + "'!$" + Col(c0) + "$" + (r0 + 1);
            if (r1 != r0 || c1 != c0) a += ":$" + Col(c1) + "$" + (r1 + 1);
            return a;
        }
        static string Esc(string s)
        {
            if (s == null) return "";
            StringBuilder b = new StringBuilder(s.Length);
            foreach (char ch in s)
            {
                if (ch < 0x20 && ch != '\t' && ch != '\n' && ch != '\r') continue;   // caracteres no válidos en XML
                b.Append(ch);
            }
            return SecurityElement.Escape(b.ToString());
        }
        static string Num(double d) { return d.ToString("R", Inv); }
        static bool IsNum(object v) { return v is double || v is float || v is int || v is long || v is decimal || v is short; }

        public void Save(string path)
        {
            string dir = Path.GetDirectoryName(Path.GetFullPath(path));
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            string tmp = path + ".tmp";
            if (File.Exists(tmp)) File.Delete(tmp);
            using (FileStream fs = new FileStream(tmp, FileMode.Create))
            using (ZipArchive zip = new ZipArchive(fs, ZipArchiveMode.Create))
            {
                int tableId = 0, chartId = 0, drawingId = 0;
                StringBuilder ct = new StringBuilder();
                ct.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">");
                ct.Append("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>");
                ct.Append("<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>");
                ct.Append("<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>");
                ct.Append("<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>");

                StringBuilder wb = new StringBuilder();
                wb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"" + NsMain + "\" xmlns:r=\"" + NsRel + "\"><bookViews><workbookView activeTab=\"0\"/></bookViews><sheets>");
                StringBuilder wbr = new StringBuilder();
                wbr.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"" + NsPkgRel + "\">");

                for (int i = 0; i < Sheets.Count; i++)
                {
                    XSheet sh = Sheets[i];
                    int n = i + 1;
                    ct.Append("<Override PartName=\"/xl/worksheets/sheet" + n + ".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>");
                    wb.Append("<sheet name=\"" + Esc(sh.Name) + "\" sheetId=\"" + n + "\" r:id=\"rId" + n + "\"/>");
                    wbr.Append("<Relationship Id=\"rId" + n + "\" Type=\"" + NsRel + "/worksheet\" Target=\"worksheets/sheet" + n + ".xml\"/>");

                    StringBuilder rels = new StringBuilder();
                    int relN = 0;
                    string drawingRel = null;
                    List<string> tableRels = new List<string>();
                    if (sh.Charts.Count > 0)
                    {
                        drawingId++;
                        drawingRel = "rId" + (++relN);
                        rels.Append("<Relationship Id=\"" + drawingRel + "\" Type=\"" + NsRel + "/drawing\" Target=\"../drawings/drawing" + drawingId + ".xml\"/>");
                        ct.Append("<Override PartName=\"/xl/drawings/drawing" + drawingId + ".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>");
                        StringBuilder dr = new StringBuilder();
                        StringBuilder drr = new StringBuilder();
                        dr.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"" + NsA + "\">");
                        drr.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"" + NsPkgRel + "\">");
                        int k = 0;
                        foreach (XChart ch in sh.Charts)
                        {
                            chartId++; k++;
                            ct.Append("<Override PartName=\"/xl/charts/chart" + chartId + ".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>");
                            drr.Append("<Relationship Id=\"rId" + k + "\" Type=\"" + NsRel + "/chart\" Target=\"../charts/chart" + chartId + ".xml\"/>");
                            dr.Append("<xdr:twoCellAnchor editAs=\"oneCell\"><xdr:from><xdr:col>" + ch.FromCol + "</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>" + ch.FromRow + "</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>");
                            dr.Append("<xdr:to><xdr:col>" + ch.ToCol + "</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>" + ch.ToRow + "</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>");
                            dr.Append("<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"" + (k + 1) + "\" name=\"Gráfico " + k + "\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>");
                            dr.Append("<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic><a:graphicData uri=\"" + NsC + "\"><c:chart xmlns:c=\"" + NsC + "\" xmlns:r=\"" + NsRel + "\" r:id=\"rId" + k + "\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>");
                            Write(zip, "xl/charts/chart" + chartId + ".xml", ChartXml(ch));
                        }
                        dr.Append("</xdr:wsDr>"); drr.Append("</Relationships>");
                        Write(zip, "xl/drawings/drawing" + drawingId + ".xml", dr.ToString());
                        Write(zip, "xl/drawings/_rels/drawing" + drawingId + ".xml.rels", drr.ToString());
                    }
                    foreach (XTable t in sh.Tables)
                    {
                        tableId++;
                        string rid = "rId" + (++relN);
                        tableRels.Add(rid);
                        rels.Append("<Relationship Id=\"" + rid + "\" Type=\"" + NsRel + "/table\" Target=\"../tables/table" + tableId + ".xml\"/>");
                        ct.Append("<Override PartName=\"/xl/tables/table" + tableId + ".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml\"/>");
                        Write(zip, "xl/tables/table" + tableId + ".xml", TableXml(sh, t, tableId));
                    }
                    Write(zip, "xl/worksheets/sheet" + n + ".xml", SheetXml(sh, i == 0, drawingRel, tableRels));
                    if (relN > 0)
                        Write(zip, "xl/worksheets/_rels/sheet" + n + ".xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"" + NsPkgRel + "\">" + rels + "</Relationships>");
                }
                wb.Append("</sheets></workbook>");
                int sid = Sheets.Count + 1;
                wbr.Append("<Relationship Id=\"rId" + sid + "\" Type=\"" + NsRel + "/styles\" Target=\"styles.xml\"/></Relationships>");
                ct.Append("</Types>");

                Write(zip, "[Content_Types].xml", ct.ToString());
                Write(zip, "_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"" + NsPkgRel + "\"><Relationship Id=\"rId1\" Type=\"" + NsRel + "/officeDocument\" Target=\"xl/workbook.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>");
                Write(zip, "docProps/core.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>Latencia a regiones cloud</dc:title><dc:creator>" + Esc(Creator) + "</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">" + DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", Inv) + "</dcterms:created></cp:coreProperties>");
                Write(zip, "xl/workbook.xml", wb.ToString());
                Write(zip, "xl/_rels/workbook.xml.rels", wbr.ToString());
                Write(zip, "xl/styles.xml", StylesXml());
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);
        }

        static void Write(ZipArchive zip, string name, string content)
        {
            ZipArchiveEntry e = zip.CreateEntry(name, CompressionLevel.Optimal);
            using (StreamWriter w = new StreamWriter(e.Open(), new UTF8Encoding(false))) w.Write(content);
        }

        static string SheetXml(XSheet sh, bool selected, string drawingRel, List<string> tableRels)
        {
            StringBuilder b = new StringBuilder(64 * 1024);
            b.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"" + NsMain + "\" xmlns:r=\"" + NsRel + "\">");
            b.Append("<sheetViews><sheetView workbookViewId=\"0\"" + (selected ? " tabSelected=\"1\"" : "") + ">");
            if (sh.FreezeRows > 0) b.Append("<pane ySplit=\"" + sh.FreezeRows + "\" topLeftCell=\"A" + (sh.FreezeRows + 1) + "\" activePane=\"bottomLeft\" state=\"frozen\"/>");
            b.Append("</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/>");
            if (sh.Widths.Count > 0)
            {
                b.Append("<cols>");
                foreach (KeyValuePair<int, double> w in sh.Widths.OrderBy(x => x.Key))
                    b.Append("<col min=\"" + (w.Key + 1) + "\" max=\"" + (w.Key + 1) + "\" width=\"" + Num(w.Value) + "\" customWidth=\"1\"/>");
                b.Append("</cols>");
            }
            b.Append("<sheetData>");
            for (int r = 0; r < sh.Rows.Count; r++)
            {
                object[] row = sh.Rows[r];
                if (row == null || row.Length == 0) continue;
                b.Append("<row r=\"" + (r + 1) + "\">");
                for (int c = 0; c < row.Length; c++)
                {
                    object v = row[c]; int s = 0;
                    XCell xc = v as XCell; if (xc != null) { v = xc.V; s = xc.S; }
                    if (v == null) { if (s != 0) b.Append("<c r=\"" + Ref(r, c) + "\" s=\"" + s + "\"/>"); continue; }
                    string rf = Ref(r, c);
                    if (v is double? && !((double?)v).HasValue) continue;
                    if (IsNum(v))
                    {
                        double d = Convert.ToDouble(v, Inv);
                        if (double.IsNaN(d) || double.IsInfinity(d)) continue;
                        b.Append("<c r=\"" + rf + "\"" + (s != 0 ? " s=\"" + s + "\"" : "") + "><v>" + Num(d) + "</v></c>");
                    }
                    else if (v is DateTime)
                    {
                        double serial = ((DateTime)v - new DateTime(1899, 12, 30)).TotalDays;
                        b.Append("<c r=\"" + rf + "\" s=\"" + (s != 0 ? s : XS.Date) + "\"><v>" + Num(Math.Round(serial, 8)) + "</v></c>");
                    }
                    else if (v is bool)
                        b.Append("<c r=\"" + rf + "\" t=\"b\"" + (s != 0 ? " s=\"" + s + "\"" : "") + "><v>" + ((bool)v ? "1" : "0") + "</v></c>");
                    else
                        b.Append("<c r=\"" + rf + "\" t=\"inlineStr\"" + (s != 0 ? " s=\"" + s + "\"" : "") + "><is><t xml:space=\"preserve\">" + Esc(Convert.ToString(v, Inv)) + "</t></is></c>");
                }
                b.Append("</row>");
            }
            b.Append("</sheetData>");
            int prio = 1;
            foreach (string range in sh.ColorScales)
            {
                b.Append("<conditionalFormatting sqref=\"" + range + "\"><cfRule type=\"colorScale\" priority=\"" + (prio++) + "\"><colorScale><cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/>");
                b.Append("<color rgb=\"FF63BE7B\"/><color rgb=\"FFFFEB84\"/><color rgb=\"FFF8696B\"/></colorScale></cfRule></conditionalFormatting>");
            }
            b.Append("<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>");
            if (drawingRel != null) b.Append("<drawing r:id=\"" + drawingRel + "\"/>");
            if (tableRels.Count > 0)
            {
                b.Append("<tableParts count=\"" + tableRels.Count + "\">");
                foreach (string t in tableRels) b.Append("<tablePart r:id=\"" + t + "\"/>");
                b.Append("</tableParts>");
            }
            b.Append("</worksheet>");
            return b.ToString();
        }

        static string TableXml(XSheet sh, XTable t, int id)
        {
            string rf = Ref(t.Row0, t.Col0) + ":" + Ref(Math.Max(t.Row1, t.Row0 + 1), t.Col1);
            StringBuilder b = new StringBuilder();
            b.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><table xmlns=\"" + NsMain + "\" id=\"" + id + "\" name=\"" + Esc(t.Name) + "\" displayName=\"" + Esc(t.Name) + "\" ref=\"" + rf + "\" totalsRowShown=\"0\">");
            b.Append("<autoFilter ref=\"" + rf + "\"/><tableColumns count=\"" + (t.Col1 - t.Col0 + 1) + "\">");
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int c = t.Col0; c <= t.Col1; c++)
            {
                string name = Convert.ToString(sh.Get(t.Row0, c), Inv);
                if (string.IsNullOrEmpty(name) || !seen.Add(name)) throw new InvalidOperationException("Encabezado de tabla vacío o repetido: " + name);
                b.Append("<tableColumn id=\"" + (c - t.Col0 + 1) + "\" name=\"" + Esc(name) + "\"/>");
            }
            b.Append("</tableColumns><tableStyleInfo name=\"" + t.Style + "\" showFirstColumn=\"0\" showLastColumn=\"0\" showRowStripes=\"1\" showColumnStripes=\"0\"/></table>");
            return b.ToString();
        }

        static string Fill(string hex) { return "<a:solidFill><a:srgbClr val=\"" + hex.TrimStart('#') + "\"/></a:solidFill>"; }
        static string Rich(string text, int size, bool bold)
        {
            return "<c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"" + size + "\" b=\"" + (bold ? 1 : 0) + "\"/></a:pPr><a:r><a:rPr lang=\"es-ES\" sz=\"" + size + "\" b=\"" + (bold ? 1 : 0) + "\"/><a:t>" + Esc(text) + "</a:t></a:r></a:p></c:rich>";
        }
        const string TxSmall = "<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"900\"/></a:pPr><a:endParaRPr lang=\"es-ES\"/></a:p></c:txPr>";
        const string GridLn = "<c:majorGridlines><c:spPr><a:ln w=\"6350\"><a:solidFill><a:srgbClr val=\"E5E7EB\"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>";

        static string ChartXml(XChart ch)
        {
            XSheet ds = ch.DataSheet;
            int n = ch.Row1 - ch.Row0 + 1;
            StringBuilder b = new StringBuilder();
            b.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><c:chartSpace xmlns:c=\"" + NsC + "\" xmlns:a=\"" + NsA + "\" xmlns:r=\"" + NsRel + "\"><c:roundedCorners val=\"0\"/><c:chart>");
            if (!string.IsNullOrEmpty(ch.Title)) b.Append("<c:title><c:tx>" + Rich(ch.Title, 1300, true) + "</c:tx><c:overlay val=\"0\"/></c:title>");
            b.Append("<c:autoTitleDeleted val=\"" + (string.IsNullOrEmpty(ch.Title) ? 1 : 0) + "\"/><c:plotArea><c:layout/>");
            bool line = ch.Kind == "line";
            if (line) b.Append("<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>");
            else b.Append("<c:barChart><c:barDir val=\"" + (ch.Kind == "bar" ? "bar" : "col") + "\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>");
            for (int si = 0; si < ch.Series.Count; si++)
            {
                XSeries s = ch.Series[si];
                b.Append("<c:ser><c:idx val=\"" + si + "\"/><c:order val=\"" + si + "\"/><c:tx><c:v>" + Esc(s.Name) + "</c:v></c:tx>");
                if (line)
                {
                    b.Append("<c:spPr><a:ln w=\"28575\" cap=\"rnd\">" + Fill(s.Color) + "<a:round/></a:ln></c:spPr>");
                    b.Append("<c:marker><c:symbol val=\"circle\"/><c:size val=\"5\"/><c:spPr>" + Fill(s.Color) + "<a:ln>" + Fill(s.Color) + "</a:ln></c:spPr></c:marker>");
                }
                else
                {
                    b.Append("<c:spPr>" + Fill(s.Color) + "</c:spPr><c:invertIfNegative val=\"0\"/>");
                    if (s.PointColors != null)
                        for (int p = 0; p < s.PointColors.Count && p < n; p++)
                            if (!string.IsNullOrEmpty(s.PointColors[p]) && s.PointColors[p] != s.Color)
                                b.Append("<c:dPt><c:idx val=\"" + p + "\"/><c:invertIfNegative val=\"0\"/><c:bubble3D val=\"0\"/><c:spPr>" + Fill(s.PointColors[p]) + "</c:spPr></c:dPt>");
                }
                if (ch.Labels)
                    b.Append("<c:dLbls><c:numFmt formatCode=\"0\" sourceLinked=\"0\"/><c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr>" + TxSmall + (line ? "<c:dLblPos val=\"t\"/>" : "<c:dLblPos val=\"outEnd\"/>") + "<c:showLegendKey val=\"0\"/><c:showVal val=\"1\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/><c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls>");
                // categorías
                b.Append("<c:cat><c:strRef><c:f>" + Esc(AbsRef(ds, ch.Row0, ch.CatCol, ch.Row1, ch.CatCol)) + "</c:f><c:strCache><c:ptCount val=\"" + n + "\"/>");
                for (int r = 0; r < n; r++)
                {
                    object v = ds.Get(ch.Row0 + r, ch.CatCol);
                    if (v != null) b.Append("<c:pt idx=\"" + r + "\"><c:v>" + Esc(Convert.ToString(v, Inv)) + "</c:v></c:pt>");
                }
                b.Append("</c:strCache></c:strRef></c:cat>");
                // valores
                b.Append("<c:val><c:numRef><c:f>" + Esc(AbsRef(ds, ch.Row0, s.ValCol, ch.Row1, s.ValCol)) + "</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"" + n + "\"/>");
                for (int r = 0; r < n; r++)
                {
                    object v = ds.Get(ch.Row0 + r, s.ValCol);
                    if (v is double? && !((double?)v).HasValue) continue;
                    if (v != null && IsNum(v))
                    {
                        double d = Convert.ToDouble(v, Inv);
                        if (!double.IsNaN(d)) b.Append("<c:pt idx=\"" + r + "\"><c:v>" + Num(d) + "</c:v></c:pt>");
                    }
                }
                b.Append("</c:numCache></c:numRef></c:val>");
                if (line) b.Append("<c:smooth val=\"0\"/>");
                b.Append("</c:ser>");
            }
            if (line) b.Append("<c:marker val=\"1\"/>");
            else b.Append("<c:gapWidth val=\"" + (ch.Kind == "bar" ? 50 : 80) + "\"/>");
            b.Append("<c:axId val=\"5001\"/><c:axId val=\"5002\"/>");
            b.Append(line ? "</c:lineChart>" : "</c:barChart>");
            bool horiz = ch.Kind == "bar";
            b.Append("<c:catAx><c:axId val=\"5001\"/><c:scaling><c:orientation val=\"" + (ch.Reverse ? "maxMin" : "minMax") + "\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"" + (horiz ? "l" : "b") + "\"/>");
            b.Append("<c:numFmt formatCode=\"General\" sourceLinked=\"0\"/><c:majorTickMark val=\"none\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/>" + TxSmall + "<c:crossAx val=\"5002\"/><c:crosses val=\"autoZero\"/><c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>");
            b.Append("<c:valAx><c:axId val=\"5002\"/><c:scaling><c:orientation val=\"minMax\"/><c:min val=\"0\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"" + (horiz ? "b" : "l") + "\"/>" + GridLn);
            if (!string.IsNullOrEmpty(ch.AxisTitle)) b.Append("<c:title><c:tx>" + Rich(ch.AxisTitle, 900, false) + "</c:tx><c:overlay val=\"0\"/></c:title>");
            b.Append("<c:numFmt formatCode=\"0\" sourceLinked=\"0\"/><c:majorTickMark val=\"none\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:spPr><a:ln><a:noFill/></a:ln></c:spPr>" + TxSmall + "<c:crossAx val=\"5001\"/>");
            b.Append("<c:crosses val=\"" + (ch.Reverse ? "max" : "autoZero") + "\"/><c:crossBetween val=\"between\"/></c:valAx>");
            b.Append("</c:plotArea>");
            if (ch.Legend) b.Append("<c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/>" + TxSmall + "</c:legend>");
            b.Append("<c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart>");
            b.Append("<c:spPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:ln w=\"9525\"><a:solidFill><a:srgbClr val=\"E5E7EB\"/></a:solidFill></a:ln></c:spPr>");
            b.Append("<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr><a:latin typeface=\"Segoe UI\"/></a:defRPr></a:pPr><a:endParaRPr lang=\"es-ES\"/></a:p></c:txPr></c:chartSpace>");
            return b.ToString();
        }

        static string StylesXml()
        {
            return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"" + NsMain + "\">" +
                "<numFmts count=\"3\"><numFmt numFmtId=\"164\" formatCode=\"0.0\"/><numFmt numFmtId=\"165\" formatCode=\"0.0%\"/><numFmt numFmtId=\"166\" formatCode=\"yyyy-mm-dd hh:mm:ss\"/></numFmts>" +
                "<fonts count=\"5\">" +
                "<font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>" +
                "<font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/><family val=\"2\"/></font>" +
                "<font><b/><sz val=\"16\"/><color rgb=\"FF0F6CBD\"/><name val=\"Calibri\"/><family val=\"2\"/></font>" +
                "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>" +
                "<font><i/><sz val=\"10\"/><color rgb=\"FF6B7280\"/><name val=\"Calibri\"/><family val=\"2\"/></font></fonts>" +
                "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>" +
                "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF0F6CBD\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>" +
                "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" +
                "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
                "<cellXfs count=\"9\">" +
                "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" +
                "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/>" +
                "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
                "<xf numFmtId=\"165\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
                "<xf numFmtId=\"166\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
                "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>" +
                "<xf numFmtId=\"0\" fontId=\"3\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>" +
                "<xf numFmtId=\"1\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
                "<xf numFmtId=\"0\" fontId=\"4\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs>" +
                "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>" +
                "<dxfs count=\"0\"/><tableStyles count=\"0\" defaultTableStyle=\"TableStyleMedium2\" defaultPivotStyle=\"PivotStyleLight16\"/></styleSheet>";
        }
    }
}
