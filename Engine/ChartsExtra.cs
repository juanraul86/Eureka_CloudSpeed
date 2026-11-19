// ChartsExtra.cs - Mapa mundial de regiones, curva de velocidad y barras horizontales genéricas.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CloudSpeed
{
    public class MapPoint
    {
        public double Lon { get; set; }
        public double Lat { get; set; }
        public string Label { get; set; }
        public string Tip { get; set; }
        public string Color { get; set; }
        public double Size { get; set; }
        public bool Hollow { get; set; }
        public object Tag { get; set; }
    }

    public static partial class Charts
    {
        /// <summary>Mapa equirectangular con las tierras (Natural Earth) y un punto por región.</summary>
        public static void Map(Canvas c, IList<double[]> land, IList<MapPoint> pts, ChartTheme th, double width, double height,
                               double lonMin, double lonMax, double latMin, double latMax, bool labels, Action<object> onClick)
        {
            if (width < 200) width = 200; if (height < 120) height = 120;
            c.Children.Clear(); c.Width = width; c.Height = height;
            c.ClipToBounds = true;
            // conserva la proporción (1 grado de longitud = 1 de latitud en pantalla)
            double sx = width / (lonMax - lonMin), sy = height / (latMax - latMin);
            double s = Math.Min(sx, sy);
            double ox = (width - (lonMax - lonMin) * s) / 2, oy = (height - (latMax - latMin) * s) / 2;
            Func<double, double> X = lon => ox + (lon - lonMin) * s;
            Func<double, double> Y = lat => oy + (latMax - lat) * s;

            Rectangle sea = new Rectangle { Width = width, Height = height, Fill = th.Surface };
            c.Children.Add(sea);
            StreamGeometry g = new StreamGeometry();
            using (StreamGeometryContext ctx = g.Open())
            {
                foreach (double[] p in land)
                {
                    if (p.Length < 6) continue;
                    ctx.BeginFigure(new Point(X(p[0]), Y(p[1])), true, true);
                    List<Point> seg = new List<Point>(p.Length / 2);
                    for (int i = 2; i + 1 < p.Length; i += 2) seg.Add(new Point(X(p[i]), Y(p[i + 1])));
                    ctx.PolyLineTo(seg, true, false);
                }
            }
            g.Freeze();
            c.Children.Add(new Path { Data = g, Fill = th.Grid, Stroke = th.Grid, StrokeThickness = 0.5 });

            foreach (MapPoint p in pts.OrderBy(q => q.Size))
            {
                double x = X(p.Lon), y = Y(p.Lat);
                if (x < -10 || y < -10 || x > width + 10 || y > height + 10) continue;
                double d = p.Size > 0 ? p.Size : 9;
                Brush col = B(string.IsNullOrEmpty(p.Color) ? "#2F80ED" : p.Color);
                Ellipse e = new Ellipse
                {
                    Width = d, Height = d, Fill = p.Hollow ? th.Surface : col, Stroke = p.Hollow ? col : th.Surface,
                    StrokeThickness = p.Hollow ? 2 : 1.2, ToolTip = string.IsNullOrEmpty(p.Tip) ? p.Label : p.Tip, Cursor = Cursors.Hand, Tag = p.Tag
                };
                if (onClick != null)
                {
                    MapPoint cap = p;
                    e.MouseLeftButtonUp += delegate { onClick(cap.Tag); };
                }
                Canvas.SetLeft(e, x - d / 2); Canvas.SetTop(e, y - d / 2);
                c.Children.Add(e);
                if (labels && !string.IsNullOrEmpty(p.Label))
                {
                    TextBlock t = Text(c, p.Label, x + d / 2 + 2, y - 8, th.Text, 10.5, false, TextAlignment.Left, 0);
                    t.IsHitTestVisible = false;
                }
            }
        }

        /// <summary>Curva de velocidad (Mbps) de las etapas de descarga y subida.</summary>
        public static void SpeedCurve(Canvas c, IList<SpeedPoint> pts, ChartTheme th, double width, double height, double seconds)
        {
            if (width < 200) width = 200; if (height < 120) height = 120;
            c.Children.Clear(); c.Width = width; c.Height = height;
            if (pts.Count == 0) { Text(c, "Inicia un test para ver la curva de velocidad.", 0, height / 2 - 10, th.Muted, 13, false, TextAlignment.Center, width); return; }
            double left = 62, right = 12, top = 30, bottom = 28;
            double pw = width - left - right, ph = height - top - bottom;
            double max = NiceMax(Math.Max(1, pts.Max(p => p.Mbps)) * 1.08);
            double span = Math.Max(seconds, pts.Max(p => p.Seconds));
            int nd = Divs(max);
            for (int i = 0; i <= nd; i++)
            {
                double y = top + ph - ph * i / nd;
                DrawLine(c, left, y, left + pw, y, th.Grid, 1, i > 0);
                Text(c, (max * i / nd).ToString("0", Es) + " Mbps", 0, y - 8, th.Muted, 11, false, TextAlignment.Right, left - 8);
            }
            for (int i = 0; i <= 4; i++)
            {
                double x = left + pw * i / 4;
                Text(c, (span * i / 4).ToString("0", Es) + " s", x - 20, top + ph + 6, th.Muted, 11, false, TextAlignment.Center, 40);
            }
            string[] stages = { "Descarga", "Subida" };
            string[] cols = { "#2F80ED", "#10B981" };
            double lx = left;
            for (int k = 0; k < stages.Length; k++)
            {
                List<SpeedPoint> s = pts.Where(p => p.Stage == stages[k]).ToList();
                if (s.Count == 0) continue;
                Brush col = B(cols[k]);
                Polyline pl = new Polyline { Stroke = col, StrokeThickness = 2.2, StrokeLineJoin = PenLineJoin.Round };
                PointCollection area = new PointCollection();
                area.Add(new Point(left + pw * s[0].Seconds / span, top + ph));
                foreach (SpeedPoint p in s)
                {
                    Point q = new Point(left + pw * Math.Min(1, p.Seconds / span), top + ph - ph * Math.Min(1, p.Mbps / max));
                    pl.Points.Add(q); area.Add(q);
                }
                area.Add(new Point(left + pw * Math.Min(1, s[s.Count - 1].Seconds / span), top + ph));
                Polygon fill = new Polygon { Points = area, Fill = col, Opacity = 0.12 };
                c.Children.Add(fill); c.Children.Add(pl);
                Rectangle sw = new Rectangle { Width = 12, Height = 4, Fill = col };
                Canvas.SetLeft(sw, lx); Canvas.SetTop(sw, 10); c.Children.Add(sw);
                Text(c, stages[k], lx + 16, 2, th.Text, 12, false, TextAlignment.Left, 0);
                lx += 110;
            }
        }

        /// <summary>Barras horizontales sencillas (etiqueta, valor, color).</summary>
        public static void HBars(Canvas c, IList<string> labels, IList<double> values, IList<string> colors, ChartTheme th, double width, string unit)
        {
            if (width < 240) width = 240;
            c.Children.Clear();
            const double rowH = 22, top = 26, labelW = 190, valueW = 70;
            double plotX = labelW + 10, plotW = Math.Max(60, width - plotX - valueW);
            c.Width = width; c.Height = top + labels.Count * rowH + 8;
            if (labels.Count == 0) return;
            double max = NiceMax(values.Max());
            int nd = Divs(max);
            for (int i = 0; i <= nd; i++)
            {
                double x = plotX + plotW * i / nd;
                DrawLine(c, x, top - 4, x, c.Height - 4, th.Grid, 1, i > 0);
                Text(c, (max * i / nd).ToString("0", Es) + " " + unit, x - 30, 4, th.Muted, 11, false, TextAlignment.Center, 60);
            }
            for (int i = 0; i < labels.Count; i++)
            {
                double y = top + i * rowH;
                Text(c, labels[i], 0, y + 2, th.Text, 12, false, TextAlignment.Left, labelW);
                Rectangle bar = new Rectangle { Width = Math.Max(2, values[i] / max * plotW), Height = rowH - 8, RadiusX = 3, RadiusY = 3, Fill = B(colors[i]) };
                Canvas.SetLeft(bar, plotX); Canvas.SetTop(bar, y + 4); c.Children.Add(bar);
                Text(c, values[i].ToString("0", Es) + " " + unit, plotX + plotW + 6, y + 2, th.Text, 12, true, TextAlignment.Left, valueW);
            }
        }
    }
}
