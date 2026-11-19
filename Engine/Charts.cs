// Charts.cs - Gráficos en vivo de Eureka_CloudSpeed dibujados directamente sobre un Canvas de WPF
// (sin bibliotecas externas). Se redibujan en milisegundos, así que pueden actualizarse mientras se mide.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CloudSpeed
{
    public class ChartTheme
    {
        public Brush Text = Brushes.Black;
        public Brush Muted = Brushes.Gray;
        public Brush Grid = Brushes.LightGray;
        public Brush Surface = Brushes.White;
        public Dictionary<string, Brush> CloudBrushes = new Dictionary<string, Brush>();
        public Brush CloudBrush(string cloud)
        {
            Brush b; return CloudBrushes.TryGetValue(cloud, out b) ? b : Brushes.SteelBlue;
        }
    }

    public static partial class Charts
    {
        static readonly string[] Palette = { "#2F80ED", "#F59E0B", "#10B981", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6", "#64748B" };
        static readonly CultureInfo Es = new CultureInfo("es-ES");

        public static Brush B(string hex) { Brush b = (Brush)new BrushConverter().ConvertFromString(hex); b.Freeze(); return b; }

        static TextBlock Text(Canvas c, string s, double x, double y, Brush fg, double size, bool bold, TextAlignment align, double width)
        {
            TextBlock t = new TextBlock { Text = s, Foreground = fg, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis };
            if (width > 0) { t.Width = width; t.TextAlignment = align; }
            Canvas.SetLeft(t, x); Canvas.SetTop(t, y);
            c.Children.Add(t);
            return t;
        }

        static void DrawLine(Canvas c, double x1, double y1, double x2, double y2, Brush b, double th, bool dash)
        {
            Line l = new Line { X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, Stroke = b, StrokeThickness = th, SnapsToDevicePixels = true };
            if (dash) l.StrokeDashArray = new DoubleCollection(new double[] { 3, 3 });
            c.Children.Add(l);
        }

        static double NiceMax(double v)
        {
            if (v <= 0 || double.IsNaN(v)) return 100;
            double exp = Math.Pow(10, Math.Floor(Math.Log10(v)));
            foreach (double m in new double[] { 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) if (m * exp >= v) return m * exp;
            return 10 * exp;
        }

        static int Divs(double max) { return (max % 5 == 0 && max / 5 >= 1) ? 5 : 4; }

        static void Empty(Canvas c, ChartTheme th, double w, double h, string msg)
        {
            c.Children.Clear(); c.Width = w; c.Height = h;
            Text(c, msg, 0, h / 2 - 10, th.Muted, 14, false, TextAlignment.Center, w);
        }

        /// <summary>Ranking horizontal: barra = P50, bigote = P95.</summary>
        public static void Bars(Canvas c, IEnumerable<RegionRow> source, ChartTheme th, double width, double minHeight, int maxItems)
        {
            List<RegionRow> rows = source.Where(r => r.P50.HasValue).OrderBy(r => r.P50.Value).Take(maxItems).ToList();
            if (width < 200) width = 200;
            if (rows.Count == 0) { Empty(c, th, width, minHeight, "Pulsa Iniciar para medir la latencia a las regiones seleccionadas."); return; }
            c.Children.Clear();
            const double rowH = 24, top = 34, labelW = 230, valueW = 92;
            double plotX = labelW + 12, plotW = Math.Max(80, width - plotX - valueW - 8);
            double height = Math.Max(minHeight, top + rows.Count * rowH + 12);
            c.Width = width; c.Height = height;
            double max = NiceMax(rows.Max(r => r.P95.HasValue ? r.P95.Value : r.P50.Value));
            int nd = Divs(max);
            for (int i = 0; i <= nd; i++)
            {
                double v = max * i / nd, x = plotX + plotW * i / nd;
                DrawLine(c, x, top - 6, x, height - 8, th.Grid, 1, i > 0);
                Text(c, v.ToString("0", Es) + " ms", x - 30, 8, th.Muted, 11, false, TextAlignment.Center, 60);
            }
            for (int i = 0; i < rows.Count; i++)
            {
                RegionRow r = rows[i];
                double y = top + i * rowH;
                Ellipse dot = new Ellipse { Width = 8, Height = 8, Fill = th.CloudBrush(r.Cloud) };
                Canvas.SetLeft(dot, 0); Canvas.SetTop(dot, y + 6); c.Children.Add(dot);
                TextBlock lbl = Text(c, (r.Rank.HasValue ? r.Rank.Value + ". " : "") + r.Label, 14, y + 2, th.Text, 12, false, TextAlignment.Left, labelW - 14);
                lbl.ToolTip = r.Code + " · " + r.City;
                double w50 = Math.Max(2, r.P50.Value / max * plotW);
                Rectangle bar = new Rectangle { Width = w50, Height = rowH - 8, RadiusX = 3, RadiusY = 3, Fill = th.CloudBrush(r.Cloud) };
                bar.ToolTip = string.Format(Es, "{0}\nP50 {1:0.0} ms · P95 {2:0.0} ms · mín {3:0.0} ms\nJitter {4:0.0} ms · pérdida {5:0.#%} · {6} muestras",
                    r.Label, r.P50, r.P95, r.Min, r.Jitter, r.Loss, r.Count);
                Canvas.SetLeft(bar, plotX); Canvas.SetTop(bar, y + 4); c.Children.Add(bar);
                if (r.P95.HasValue && r.P95.Value > r.P50.Value)
                {
                    double x95 = plotX + Math.Min(plotW, r.P95.Value / max * plotW);
                    DrawLine(c, plotX + w50, y + rowH / 2, x95, y + rowH / 2, th.Muted, 1.2, false);
                    DrawLine(c, x95, y + 7, x95, y + rowH - 7, th.Muted, 1.2, false);
                }
                Text(c, r.P50.Value.ToString("0.0", Es) + " ms", plotX + plotW + 8, y + 3, th.Text, 12, true, TextAlignment.Left, valueW);
            }
        }

        /// <summary>Evolución: mediana de cada ronda para varias regiones.</summary>
        public static void Lines(Canvas c, IEnumerable<RegionRow> source, ChartTheme th, double width, double height)
        {
            List<RegionRow> rows = source.ToList();
            if (width < 200) width = 200; if (height < 160) height = 160;
            List<List<KeyValuePair<int, double>>> series = rows.Select(r => r.Series()).ToList();
            if (series.All(s => s.Count == 0)) { Empty(c, th, width, height, "Sin datos todavía. Activa el modo continuo para ver cómo cambia la latencia con el tiempo."); return; }
            // Todas las regiones de una ronda comparten la hora de inicio de esa ronda (puntos alineados)
            Dictionary<int, DateTime> start = new Dictionary<int, DateTime>();
            foreach (RegionRow r in rows)
                foreach (Sample s in r.Samples)
                {
                    DateTime t;
                    if (!start.TryGetValue(s.Round, out t) || s.Time < t) start[s.Round] = s.Time;
                }
            c.Children.Clear(); c.Width = width; c.Height = height;
            double left = 58, right = 16, bottom = 34;

            // leyenda (puede ocupar varias líneas)
            double lx = left, ly = 4;
            for (int k = 0; k < rows.Count; k++)
            {
                if (series[k].Count == 0) continue;
                Brush col = B(Palette[k % Palette.Length]);
                TextBlock lt = new TextBlock { Text = rows[k].Label, FontSize = 12 };
                lt.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                double w = 16 + lt.DesiredSize.Width + 18;
                if (lx + w > width && lx > left) { lx = left; ly += 20; }
                Rectangle sw = new Rectangle { Width = 12, Height = 4, Fill = col };
                Canvas.SetLeft(sw, lx); Canvas.SetTop(sw, ly + 8); c.Children.Add(sw);
                Text(c, rows[k].Label, lx + 16, ly, th.Text, 12, false, TextAlignment.Left, 0);
                lx += w;
            }
            double top = ly + 38;
            double pw = width - left - right, ph = Math.Max(60, height - top - bottom);

            List<double> vals = series.SelectMany(s => s).Select(p => p.Value).ToList();
            DateTime t0 = start.Values.Min(), t1 = start.Values.Max();
            double span = Math.Max(1, (t1 - t0).TotalSeconds);
            bool single = start.Count < 2;
            double max = NiceMax(vals.Max() * 1.05);
            int nd = Divs(max);
            for (int i = 0; i <= nd; i++)
            {
                double y = top + ph - ph * i / nd;
                DrawLine(c, left, y, left + pw, y, th.Grid, 1, i > 0);
                Text(c, (max * i / nd).ToString("0", Es) + " ms", 0, y - 8, th.Muted, 11, false, TextAlignment.Right, left - 8);
            }
            string fmt = span > 86400 ? "dd/MM HH:mm" : "HH:mm:ss";
            if (single) Text(c, t0.ToString(fmt, Es), left + pw / 2 - 40, top + ph + 8, th.Muted, 11, false, TextAlignment.Center, 80);
            else
            {
                int ticks = Math.Min(6, Math.Max(1, (int)(pw / 120)));
                for (int i = 0; i <= ticks; i++)
                {
                    DateTime t = t0.AddSeconds(span * i / ticks);
                    double x = left + pw * i / ticks;
                    Text(c, t.ToString(fmt, Es), x - 40, top + ph + 8, th.Muted, 11, false, TextAlignment.Center, 80);
                }
            }
            for (int k = 0; k < rows.Count; k++)
            {
                Brush col = B(Palette[k % Palette.Length]);
                List<KeyValuePair<int, double>> s = series[k];
                if (s.Count == 0) continue;
                Polyline pl = new Polyline { Stroke = col, StrokeThickness = 2.2, StrokeLineJoin = PenLineJoin.Round };
                foreach (KeyValuePair<int, double> p in s)
                {
                    DateTime when = start[p.Key];
                    double x = single ? left + pw / 2 : left + pw * ((when - t0).TotalSeconds / span);
                    double y = top + ph - ph * Math.Min(1, p.Value / max);
                    pl.Points.Add(new Point(x, y));
                    Ellipse e = new Ellipse { Width = 7, Height = 7, Fill = col, ToolTip = string.Format(Es, "{0}\nRonda {1} · {2:HH:mm:ss}\nMediana {3:0.0} ms", rows[k].Label, p.Key, when, p.Value) };
                    Canvas.SetLeft(e, x - 3.5); Canvas.SetTop(e, y - 3.5); c.Children.Add(e);
                }
                if (pl.Points.Count > 1) c.Children.Insert(0, pl);
            }
            if (single)
                Text(c, "Solo hay una ronda: activa el modo continuo para ver la evolución.", left, top + 6, th.Muted, 12, false, TextAlignment.Left, pw);
        }

        /// <summary>Mejor región de cada nube por geografía (columnas agrupadas).</summary>
        public static void GeoCompare(Canvas c, IEnumerable<RegionRow> source, IList<string> geos, IList<string> clouds, ChartTheme th, double width, double height)
        {
            List<RegionRow> rows = source.Where(r => r.P50.HasValue).ToList();
            if (width < 200) width = 200; if (height < 200) height = 200;
            if (rows.Count == 0) { Empty(c, th, width, height, "Sin datos todavía."); return; }
            List<string> gs = geos.Where(g => rows.Any(r => r.Geo == g)).ToList();
            c.Children.Clear(); c.Width = width; c.Height = height;
            double left = 58, right = 12, top = 40, bottom = 46;
            double pw = width - left - right, ph = height - top - bottom;
            double max = NiceMax(rows.GroupBy(r => r.Geo + r.Cloud).Max(g => g.Min(r => r.P50.Value)) * 1.1);
            int nd = Divs(max);
            for (int i = 0; i <= nd; i++)
            {
                double y = top + ph - ph * i / nd;
                DrawLine(c, left, y, left + pw, y, th.Grid, 1, i > 0);
                Text(c, (max * i / nd).ToString("0", Es) + " ms", 0, y - 8, th.Muted, 11, false, TextAlignment.Right, left - 8);
            }
            double lx = left;
            foreach (string cl in clouds)
            {
                Rectangle sw = new Rectangle { Width = 12, Height = 12, RadiusX = 2, RadiusY = 2, Fill = th.CloudBrush(cl) };
                Canvas.SetLeft(sw, lx); Canvas.SetTop(sw, 10); c.Children.Add(sw);
                Text(c, "Mejor región de " + cl, lx + 18, 7, th.Text, 12, false, TextAlignment.Left, 0);
                lx += 190;
            }
            double gw = pw / Math.Max(1, gs.Count);
            double bw = Math.Min(64, (gw - 24) / Math.Max(1, clouds.Count));
            for (int gi = 0; gi < gs.Count; gi++)
            {
                double gx = left + gi * gw + (gw - bw * clouds.Count) / 2;
                for (int ci = 0; ci < clouds.Count; ci++)
                {
                    RegionRow best = rows.Where(r => r.Geo == gs[gi] && r.Cloud == clouds[ci]).OrderBy(r => r.P50.Value).FirstOrDefault();
                    if (best == null) continue;
                    double h = ph * Math.Min(1, best.P50.Value / max);
                    double x = gx + ci * bw;
                    Rectangle bar = new Rectangle { Width = bw - 6, Height = Math.Max(2, h), RadiusX = 3, RadiusY = 3, Fill = th.CloudBrush(best.Cloud) };
                    bar.ToolTip = string.Format(Es, "{0}\n{1} ({2})\nP50 {3:0.0} ms", gs[gi], best.Label, best.Code, best.P50);
                    Canvas.SetLeft(bar, x + 3); Canvas.SetTop(bar, top + ph - Math.Max(2, h)); c.Children.Add(bar);
                    Text(c, best.P50.Value.ToString("0", Es), x, top + ph - h - 18, th.Text, 11, true, TextAlignment.Center, bw);
                }
                Text(c, gs[gi], left + gi * gw, top + ph + 8, th.Text, 12, false, TextAlignment.Center, gw);
            }
        }
    }
}
