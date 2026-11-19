// Engine.cs - Motor de medición de Eureka_CloudSpeed.
// Mide la latencia (RTT) con el tiempo de conexión TCP al puerto 443 del endpoint regional de cada
// nube y, opcionalmente, el tiempo del saludo TLS. Las mediciones se hacen en paralelo en el grupo de
// subprocesos y llegan a la interfaz por una cola concurrente, así la ventana nunca se congela.
// C# 5 (lo compila Add-Type de Windows PowerShell 5.1 sin descargar nada).
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Threading;
using System.Threading.Tasks;

namespace CloudSpeed
{
    public class RegionInfo
    {
        public string Cloud { get; set; }
        public string Code { get; set; }
        public string Name { get; set; }
        public string Geo { get; set; }
        public string Country { get; set; }
        public string City { get; set; }
        public double Lat { get; set; }
        public double Lon { get; set; }
        public string Host { get; set; }
        public int Port { get; set; }
        public string Note { get; set; }
        public string Key { get { return Cloud + "|" + Code; } }
        public string Label { get { return Cloud + " · " + Name; } }
        public bool HasEndpoint { get { return !string.IsNullOrWhiteSpace(Host); } }
    }

    public class Sample
    {
        public string SessionId { get; set; }
        public DateTime Time { get; set; }
        public int Round { get; set; }
        public RegionInfo Region { get; set; }
        public string Ip { get; set; }
        public double TcpMs { get; set; }
        public double TlsMs { get; set; }
        public bool Ok { get; set; }
        public string Error { get; set; }
        public Sample() { TcpMs = double.NaN; TlsMs = double.NaN; }
    }

    public static class Stats
    {
        public static double Percentile(List<double> sorted, double p)
        {
            if (sorted == null || sorted.Count == 0) return double.NaN;
            double pos = (sorted.Count - 1) * p;
            int lo = (int)Math.Floor(pos), hi = (int)Math.Ceiling(pos);
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
        }
        public static double? N(double v) { return double.IsNaN(v) || double.IsInfinity(v) ? (double?)null : Math.Round(v, 1); }
        public static string Level(double ms)
        {
            if (double.IsNaN(ms)) return "#9CA3AF";
            if (ms < 50) return "#22C55E";
            if (ms < 100) return "#84CC16";
            if (ms < 175) return "#F59E0B";
            return "#EF4444";
        }
    }

    /// <summary>Fila del ranking: una región con sus estadísticas en vivo.</summary>
    public class RegionRow : INotifyPropertyChanged
    {
        readonly List<Sample> samples = new List<Sample>();
        bool selected = true, visible = true, measuring;
        public RegionRow(RegionInfo info, string cloudColor) { Info = info; CloudColor = cloudColor; Recompute(); }
        public event PropertyChangedEventHandler PropertyChanged;
        void Notify(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }

        public RegionInfo Info { get; private set; }
        public string CloudColor { get; private set; }
        public string Cloud { get { return Info.Cloud; } }
        public string Code { get { return Info.Code; } }
        public string Name { get { return Info.Name; } }
        public string Geo { get { return Info.Geo; } }
        public string City { get { return Info.City + ", " + Info.Country; } }
        public string Label { get { return Info.Label; } }
        public bool HasEndpoint { get { return Info.HasEndpoint; } }
        public string Tip { get { return Info.HasEndpoint ? Info.Host : Info.Note; } }
        public List<Sample> Samples { get { return samples; } }

        public bool Selected { get { return selected; } set { if (selected != value) { selected = value; Notify("Selected"); } } }
        public bool Visible { get { return visible; } set { visible = value; } }
        public bool Measuring { get { return measuring; } set { if (measuring != value) { measuring = value; Notify("Status"); } } }

        public int Count { get; private set; }
        public int OkCount { get; private set; }
        public double? Last { get; private set; }
        public double? Min { get; private set; }
        public double? Avg { get; private set; }
        public double? P50 { get; private set; }
        public double? P95 { get; private set; }
        public double? Max { get; private set; }
        public double? Jitter { get; private set; }
        public double? Loss { get; private set; }
        public double? TlsP50 { get; private set; }
        public string Ip { get; private set; }
        public int? Rank { get; set; }
        public double BarWidth { get; private set; }
        public string LevelColor { get { return Stats.Level(P50.HasValue ? P50.Value : double.NaN); } }
        public double SortKey { get { return P50.HasValue ? P50.Value : (Count > 0 ? 1e9 : 1e10); } }
        public string Status
        {
            get
            {
                if (!Info.HasEndpoint) return "Sin endpoint";
                if (measuring) return "Midiendo…";
                if (Count == 0) return "—";
                if (OkCount == 0) return "Sin respuesta";
                return Loss > 0 ? "Pérdidas" : "OK";
            }
        }

        public void Add(Sample s) { samples.Add(s); }

        public void Clear() { samples.Clear(); Rank = null; Recompute(); }

        public void Recompute()
        {
            List<double> ok = new List<double>();
            List<double> tls = new List<double>();
            double jit = 0; int jn = 0; double prev = double.NaN; string ip = null; double last = double.NaN;
            foreach (Sample s in samples)
            {
                if (s.Ip != null) ip = s.Ip;
                if (!s.Ok) continue;
                ok.Add(s.TcpMs); last = s.TcpMs;
                if (!double.IsNaN(s.TlsMs)) tls.Add(s.TlsMs);
                if (!double.IsNaN(prev)) { jit += Math.Abs(s.TcpMs - prev); jn++; }
                prev = s.TcpMs;
            }
            Count = samples.Count; OkCount = ok.Count; Ip = ip;
            ok.Sort(); tls.Sort();
            Last = Stats.N(last);
            Min = ok.Count > 0 ? Stats.N(ok[0]) : null;
            Max = ok.Count > 0 ? Stats.N(ok[ok.Count - 1]) : null;
            Avg = ok.Count > 0 ? Stats.N(ok.Average()) : null;
            P50 = Stats.N(Stats.Percentile(ok, 0.5));
            P95 = Stats.N(Stats.Percentile(ok, 0.95));
            TlsP50 = Stats.N(Stats.Percentile(tls, 0.5));
            Jitter = jn > 0 ? Stats.N(jit / jn) : null;
            Loss = Count > 0 ? (double?)Math.Round((Count - OkCount) / (double)Count, 4) : null;
            Notify(string.Empty);
        }

        public void SetScale(double maxMs, double maxWidth)
        {
            double w = (P50.HasValue && maxMs > 0) ? Math.Max(2, P50.Value / maxMs * maxWidth) : 0;
            if (Math.Abs(w - BarWidth) > 0.4) { BarWidth = w; Notify("BarWidth"); }
        }

        /// <summary>Serie temporal: mediana de cada ronda (clave = número de ronda).</summary>
        public List<KeyValuePair<int, double>> Series()
        {
            List<KeyValuePair<int, double>> r = new List<KeyValuePair<int, double>>();
            foreach (IGrouping<int, Sample> g in samples.GroupBy(x => x.Round).OrderBy(x => x.Key))
            {
                List<double> v = g.Where(x => x.Ok).Select(x => x.TcpMs).OrderBy(x => x).ToList();
                if (v.Count > 0) r.Add(new KeyValuePair<int, double>(g.Key, Stats.Percentile(v, 0.5)));
            }
            return r;
        }

        public double RoundMedian(int round)
        {
            List<double> v = samples.Where(x => x.Round == round && x.Ok).Select(x => x.TcpMs).OrderBy(x => x).ToList();
            return Stats.Percentile(v, 0.5);
        }
    }

    public static class RowTools
    {
        public static readonly Predicate<object> VisibleFilter = delegate (object o) { return ((RegionRow)o).Visible; };

        /// <summary>Reordena la colección por latencia moviendo solo lo necesario (sin parpadeos).</summary>
        public static void SortInPlace(ObservableCollection<RegionRow> rows)
        {
            List<RegionRow> desired = rows.OrderBy(r => r.SortKey).ThenBy(r => r.Cloud).ThenBy(r => r.Name).ToList();
            int rank = 0;
            foreach (RegionRow r in desired) r.Rank = r.P50.HasValue ? (int?)(++rank) : null;
            for (int i = 0; i < desired.Count; i++)
            {
                if (!object.ReferenceEquals(rows[i], desired[i])) rows.Move(rows.IndexOf(desired[i]), i);
            }
        }
    }

    /// <summary>Lanza una ronda de mediciones en paralelo sobre una lista de regiones.</summary>
    public class ProbeEngine
    {
        public readonly ConcurrentQueue<Sample> Queue = new ConcurrentQueue<Sample>();
        public readonly ConcurrentQueue<string> Started = new ConcurrentQueue<string>();
        public int Samples = 5;
        public int TimeoutMs = 2000;
        public int GapMs = 120;
        public int Parallel = 12;
        public bool MeasureTls = false;
        public string SessionId = Guid.NewGuid().ToString("N").Substring(0, 12);
        int total, done;
        CancellationTokenSource cts;
        Task task;

        public int Total { get { return total; } }
        public int Done { get { return done; } }
        public bool IsRunning { get { return task != null && !task.IsCompleted; } }

        public void NewSession() { SessionId = Guid.NewGuid().ToString("N").Substring(0, 12); }

        public void Start(IEnumerable<RegionInfo> regions, int round)
        {
            if (IsRunning) throw new InvalidOperationException("Ya hay una medición en curso.");
            List<RegionInfo> list = regions.Where(r => r.HasEndpoint).ToList();
            Random rnd = new Random();
            list = list.OrderBy(x => rnd.Next()).ToList();   // orden aleatorio: ninguna región sale siempre la primera
            total = list.Count * Math.Max(1, Samples); done = 0;
            int workers, io; ThreadPool.GetMinThreads(out workers, out io);
            if (workers < Parallel + 4) ThreadPool.SetMinThreads(Parallel + 4, Math.Max(io, Parallel + 4));
            cts = new CancellationTokenSource();
            CancellationToken token = cts.Token;
            int samples = Math.Max(1, Samples), timeout = TimeoutMs, gap = GapMs; bool tls = MeasureTls; string sid = SessionId;
            ParallelOptions po = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Parallel), CancellationToken = token };
            task = Task.Factory.StartNew(delegate
            {
                try { System.Threading.Tasks.Parallel.ForEach(list, po, delegate (RegionInfo r) { ProbeRegion(r, round, samples, timeout, gap, tls, sid, token); }); }
                catch (OperationCanceledException) { }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        public void Cancel() { if (cts != null) cts.Cancel(); }

        public bool Wait(int ms) { return task == null || task.Wait(ms); }

        void ProbeRegion(RegionInfo r, int round, int samples, int timeout, int gap, bool tls, string sid, CancellationToken token)
        {
            Started.Enqueue(r.Key);
            IPAddress ip = null; string dnsError = null;
            try
            {
                IPAddress[] all = Dns.GetHostAddresses(r.Host);
                ip = all.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork) ?? all.FirstOrDefault();
                if (ip == null) dnsError = "DNS sin direcciones";
            }
            catch (Exception ex) { dnsError = "DNS: " + ex.Message; }

            if (ip != null) { double w; string e; Connect(ip, r.Port, r.Host, timeout, false, out w, out e); }   // calentamiento (no cuenta)

            for (int i = 0; i < samples; i++)
            {
                if (token.IsCancellationRequested) break;
                Sample s = new Sample { SessionId = sid, Round = round, Region = r, Time = DateTime.Now, Ip = ip == null ? null : ip.ToString() };
                if (ip == null) s.Error = dnsError;
                else
                {
                    double tlsMs; string err;
                    double tcp = Connect(ip, r.Port, r.Host, timeout, tls, out tlsMs, out err);
                    s.TcpMs = tcp; s.TlsMs = tlsMs; s.Ok = !double.IsNaN(tcp); s.Error = err;
                }
                Queue.Enqueue(s);
                Interlocked.Increment(ref done);
                if (i < samples - 1) { try { Task.Delay(gap, token).Wait(); } catch { break; } }
            }
        }

        /// <summary>Devuelve el tiempo de conexión TCP en ms (NaN si falla) y el del saludo TLS.</summary>
        public static double Connect(IPAddress ip, int port, string host, int timeout, bool tls, out double tlsMs, out string error)
        {
            tlsMs = double.NaN; error = null;
            TcpClient c = new TcpClient(ip.AddressFamily);
            try
            {
                c.NoDelay = true;
                Stopwatch sw = Stopwatch.StartNew();
                Task t = c.ConnectAsync(ip, port);
                bool finished;
                try { finished = t.Wait(timeout); }
                catch (AggregateException ae) { error = Short(ae.InnerException ?? ae); return double.NaN; }
                sw.Stop();
                if (!finished) { error = "Tiempo de espera agotado"; return double.NaN; }
                double ms = sw.Elapsed.TotalMilliseconds;
                if (tls)
                {
                    try
                    {
                        SslStream ssl = new SslStream(c.GetStream(), false);
                        Stopwatch s2 = Stopwatch.StartNew();
                        Task a = ssl.AuthenticateAsClientAsync(host, null, SslProtocols.Tls12, false);
                        if (a.Wait(timeout)) tlsMs = s2.Elapsed.TotalMilliseconds; else error = "TLS: tiempo agotado";
                        ssl.Dispose();
                    }
                    catch (Exception ex) { error = "TLS: " + Short(ex); }
                }
                return ms;
            }
            finally { try { c.Close(); } catch { } }
        }

        static string Short(Exception ex)
        {
            while (ex is AggregateException && ex.InnerException != null) ex = ex.InnerException;
            if (ex.InnerException != null && ex is AuthenticationException) ex = ex.InnerException;
            SocketException se = ex as SocketException;
            if (se != null) return "Socket " + se.SocketErrorCode;
            return ex.Message;
        }
    }

    public static class Native
    {
        [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        /// <summary>Barra de título oscura en Windows 10/11.</summary>
        public static void DarkTitleBar(IntPtr hwnd, bool dark)
        {
            int v = dark ? 1 : 0;
            try { DwmSetWindowAttribute(hwnd, 20, ref v, 4); } catch { }
        }
    }

    /// <summary>Ejecución sin interfaz (línea de comandos y tareas programadas).</summary>
    public static class Runner
    {
        public static List<Sample> RunBlocking(ProbeEngine e, IEnumerable<RegionInfo> regions, int round, Action<int, int> progress)
        {
            List<Sample> all = new List<Sample>();
            e.Start(regions, round);
            while (!e.Wait(250))
            {
                Sample s; while (e.Queue.TryDequeue(out s)) all.Add(s);
                if (progress != null) progress(e.Done, e.Total);
            }
            Sample x; while (e.Queue.TryDequeue(out x)) all.Add(x);
            if (progress != null) progress(e.Done, e.Total);
            return all;
        }
    }
}
