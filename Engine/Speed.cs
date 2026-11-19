// Speed.cs - Test de velocidad a una región: latencia y jitter, descarga y subida con una o varias
// conexiones en paralelo, y latencia "con carga" mientras se transfiere (indica si la conexión se satura).
// Necesita endpoints propios (cuenta de almacenamiento de Azure con SAS o URL prefirmadas de S3),
// configurados en Config\velocidad.json.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace CloudSpeed
{
    public class SpeedEndpoint
    {
        public string Cloud { get; set; }
        public string Code { get; set; }
        public string Name { get; set; }
        public string DownloadUrl { get; set; }
        public string UploadUrl { get; set; }
        /// <summary>"azure-container": SAS de contenedor (se crea un blob por envío); "url": URL de PUT fija (S3 prefirmada).</summary>
        public string UploadKind { get; set; }
        public string Label { get { return Cloud + " · " + Name; } }
        public override string ToString() { return Label; }
        public string Host
        {
            get
            {
                string u = !string.IsNullOrEmpty(DownloadUrl) ? DownloadUrl : UploadUrl;
                Uri x; return Uri.TryCreate(u, UriKind.Absolute, out x) ? x.Host : null;
            }
        }
    }

    public class SpeedPoint
    {
        public string Stage { get; set; }
        public double Seconds { get; set; }
        public double Mbps { get; set; }
    }

    public class SpeedResult
    {
        public DateTime Time { get; set; }
        public string Region { get; set; }
        public string Mode { get; set; }
        public double? LatencyMs { get; set; }
        public double? JitterMs { get; set; }
        public double? DownMbps { get; set; }
        public double? UpMbps { get; set; }
        public double? DownLatencyMs { get; set; }
        public double? UpLatencyMs { get; set; }
        public double DownMiB { get; set; }
        public double UpMiB { get; set; }
        public string Error { get; set; }
    }

    public class SpeedTest
    {
        public readonly ConcurrentQueue<SpeedPoint> Points = new ConcurrentQueue<SpeedPoint>();
        public readonly ConcurrentQueue<string> Log = new ConcurrentQueue<string>();
        public int Streams = 4;
        public int Seconds = 12;
        public long MaxBytesPerStage = 200L * 1024 * 1024;
        public int ChunkBytes = 4 * 1024 * 1024;
        public SpeedResult Result { get; private set; }
        public string Stage { get; private set; }
        public double StageProgress { get; private set; }
        public double CurrentMbps { get; private set; }
        public bool IsRunning { get { return task != null && !task.IsCompleted; } }
        CancellationTokenSource cts;
        Task task;
        long bytes;
        readonly List<string> createdBlobs = new List<string>();

        public void Start(SpeedEndpoint ep, bool latency, bool download, bool upload)
        {
            if (IsRunning) throw new InvalidOperationException("Ya hay un test en curso.");
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            if (ServicePointManager.DefaultConnectionLimit < 16) ServicePointManager.DefaultConnectionLimit = 16;
            ServicePointManager.Expect100Continue = false;
            int w, io; ThreadPool.GetMinThreads(out w, out io);
            if (w < 24) ThreadPool.SetMinThreads(24, Math.Max(io, 24));
            Result = new SpeedResult { Time = DateTime.Now, Region = ep.Label, Mode = Streams > 1 ? "Varias conexiones (" + Streams + ")" : "Una conexión" };
            cts = new CancellationTokenSource();
            CancellationToken tk = cts.Token;
            task = Task.Factory.StartNew(delegate
            {
                try
                {
                    if (latency) RunLatency(ep, tk);
                    if (download && !tk.IsCancellationRequested)
                    {
                        if (string.IsNullOrEmpty(ep.DownloadUrl)) Log.Enqueue("Descarga omitida: la región no tiene downloadUrl.");
                        else RunTransfer(ep, true, tk);
                    }
                    if (upload && !tk.IsCancellationRequested)
                    {
                        if (string.IsNullOrEmpty(ep.UploadUrl)) Log.Enqueue("Subida omitida: la región no tiene uploadUrl.");
                        else RunTransfer(ep, false, tk);
                    }
                    Cleanup(ep);
                }
                catch (Exception ex) { Result.Error = ex.Message; Log.Enqueue("Error: " + ex.Message); }
                Stage = tk.IsCancellationRequested ? "Cancelado" : "Terminado";
                StageProgress = 1;
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        public void Cancel() { if (cts != null) cts.Cancel(); }

        static List<double> Pings(string host, int n, int gapMs, CancellationToken tk)
        {
            List<double> v = new List<double>();
            IPAddress ip = Dns.GetHostAddresses(host).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
            if (ip == null) return v;
            double t; string e;
            ProbeEngine.Connect(ip, 443, host, 2000, false, out t, out e);   // calentamiento
            for (int i = 0; i < n && !tk.IsCancellationRequested; i++)
            {
                double ms = ProbeEngine.Connect(ip, 443, host, 2000, false, out t, out e);
                if (!double.IsNaN(ms)) v.Add(ms);
                if (gapMs > 0) Thread.Sleep(gapMs);
            }
            return v;
        }

        void RunLatency(SpeedEndpoint ep, CancellationToken tk)
        {
            Stage = "Latencia"; StageProgress = 0;
            string host = ep.Host;
            if (host == null) { Log.Enqueue("Latencia omitida: no hay URL."); return; }
            List<double> v = new List<double>();
            IPAddress ip = Dns.GetHostAddresses(host).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
            double t; string e;
            ProbeEngine.Connect(ip, 443, host, 2000, false, out t, out e);
            for (int i = 0; i < 20 && !tk.IsCancellationRequested; i++)
            {
                double ms = ProbeEngine.Connect(ip, 443, host, 2000, false, out t, out e);
                if (!double.IsNaN(ms)) v.Add(ms);
                StageProgress = (i + 1) / 20.0;
                Thread.Sleep(80);
            }
            if (v.Count == 0) { Log.Enqueue("La región no responde en el puerto 443."); return; }
            double jit = 0; for (int i = 1; i < v.Count; i++) jit += Math.Abs(v[i] - v[i - 1]);
            List<double> s = v.OrderBy(x => x).ToList();
            Result.LatencyMs = Math.Round(Stats.Percentile(s, 0.5), 1);
            Result.JitterMs = v.Count > 1 ? Math.Round(jit / (v.Count - 1), 1) : (double?)null;
        }

        void RunTransfer(SpeedEndpoint ep, bool down, CancellationToken outer)
        {
            string name = down ? "Descarga" : "Subida";
            Stage = name; StageProgress = 0; CurrentMbps = 0;
            Interlocked.Exchange(ref bytes, 0);
            CancellationTokenSource stage = CancellationTokenSource.CreateLinkedTokenSource(outer);
            CancellationToken tk = stage.Token;
            Stopwatch sw = Stopwatch.StartNew();
            byte[] payload = null;
            if (!down) { payload = new byte[ChunkBytes]; new Random().NextBytes(payload); }
            List<Task> workers = new List<Task>();
            for (int i = 0; i < Math.Max(1, Streams); i++)
            {
                int n = i;
                workers.Add(Task.Factory.StartNew(delegate
                {
                    int k = 0;
                    while (!tk.IsCancellationRequested)
                    {
                        try { if (down) DownloadOnce(ep.DownloadUrl, tk); else UploadOnce(ep, payload, n, k++, tk); }
                        catch (Exception ex)
                        {
                            if (tk.IsCancellationRequested) break;
                            Log.Enqueue(name + ": " + Short(ex));
                            Thread.Sleep(300);
                            if (sw.Elapsed.TotalSeconds > 3 && Interlocked.Read(ref bytes) == 0) { stage.Cancel(); break; }
                        }
                    }
                }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default));
            }
            // Latencia con carga en paralelo
            List<double> loaded = new List<double>();
            Task lat = Task.Factory.StartNew(delegate
            {
                try { Thread.Sleep(1000); while (!tk.IsCancellationRequested) { List<double> p = Pings(ep.Host, 1, 0, tk); lock (loaded) loaded.AddRange(p); Thread.Sleep(450); } } catch { }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);

            // Muestreo cada 250 ms; los primeros 1,5 s (arranque de TCP) no cuentan para el resultado
            long lastBytes = 0, warmBytes = -1; double lastT = 0, warmT = 0;
            while (!tk.IsCancellationRequested)
            {
                Thread.Sleep(250);
                double t = sw.Elapsed.TotalSeconds;
                long b = Interlocked.Read(ref bytes);
                double mbps = (b - lastBytes) * 8 / 1e6 / Math.Max(0.001, t - lastT);
                CurrentMbps = mbps;
                Points.Enqueue(new SpeedPoint { Stage = name, Seconds = Math.Round(t, 2), Mbps = Math.Round(mbps, 2) });
                lastBytes = b; lastT = t;
                if (warmBytes < 0 && t >= 1.5) { warmBytes = b; warmT = t; }
                StageProgress = Math.Min(1, t / Seconds);
                if (t >= Seconds || b >= MaxBytesPerStage) stage.Cancel();
            }
            try { Task.WaitAll(workers.ToArray(), 5000); } catch { }
            try { lat.Wait(2000); } catch { }
            double total = sw.Elapsed.TotalSeconds;
            long tb = Interlocked.Read(ref bytes);
            double res = (warmBytes >= 0 && total - warmT > 0.5) ? (tb - warmBytes) * 8 / 1e6 / (total - warmT) : tb * 8 / 1e6 / Math.Max(0.001, total);
            double? lm = null;
            lock (loaded) { if (loaded.Count > 0) lm = Math.Round(Stats.Percentile(loaded.OrderBy(x => x).ToList(), 0.5), 1); }
            if (down) { Result.DownMbps = tb > 0 ? Math.Round(res, 1) : (double?)null; Result.DownMiB = Math.Round(tb / 1048576.0, 1); Result.DownLatencyMs = lm; }
            else { Result.UpMbps = tb > 0 ? Math.Round(res, 1) : (double?)null; Result.UpMiB = Math.Round(tb / 1048576.0, 1); Result.UpLatencyMs = lm; }
        }

        void DownloadOnce(string url, CancellationToken tk)
        {
            // La URL no se modifica: añadir parámetros invalidaría las firmas prefirmadas de S3
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.Method = "GET"; rq.Timeout = 15000; rq.ReadWriteTimeout = 15000;
            rq.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
            rq.Headers["Cache-Control"] = "no-cache";
            rq.AutomaticDecompression = DecompressionMethods.None;
            using (tk.Register(delegate { try { rq.Abort(); } catch { } }))
            using (WebResponse rs = rq.GetResponse())
            using (Stream s = rs.GetResponseStream())
            {
                byte[] buf = new byte[128 * 1024];
                int n;
                while (!tk.IsCancellationRequested && (n = s.Read(buf, 0, buf.Length)) > 0) Interlocked.Add(ref bytes, n);
            }
        }

        void UploadOnce(SpeedEndpoint ep, byte[] payload, int stream, int k, CancellationToken tk)
        {
            // uploadUrl puede llevar varias URL (una por línea): cada conexión usa la suya. En S3 escribir
            // sin parar sobre la misma clave provoca "503 Slow Down".
            string[] urls = ep.UploadUrl.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries);
            string url = urls[stream % urls.Length].Trim();
            bool azure = string.Equals(ep.UploadKind, "azure-container", StringComparison.OrdinalIgnoreCase);
            if (azure)
            {
                int q = url.IndexOf('?');
                string blob = "cloudspeed-" + Guid.NewGuid().ToString("N").Substring(0, 12) + "-" + stream + "-" + k + ".bin";
                url = (q < 0 ? url.TrimEnd('/') + "/" + blob : url.Substring(0, q).TrimEnd('/') + "/" + blob + url.Substring(q));
                lock (createdBlobs) createdBlobs.Add(url);
            }
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.Method = "PUT"; rq.Timeout = 30000; rq.ReadWriteTimeout = 30000;
            rq.AllowWriteStreamBuffering = false; rq.SendChunked = false;
            rq.ContentLength = payload.Length;
            rq.ContentType = "application/octet-stream";
            if (azure) rq.Headers["x-ms-blob-type"] = "BlockBlob";
            using (tk.Register(delegate { try { rq.Abort(); } catch { } }))
            {
                using (Stream s = rq.GetRequestStream())
                {
                    const int step = 64 * 1024;
                    for (int off = 0; off < payload.Length; off += step)
                    {
                        if (tk.IsCancellationRequested) return;
                        int len = Math.Min(step, payload.Length - off);
                        s.Write(payload, off, len);
                        Interlocked.Add(ref bytes, len);
                    }
                }
                using (WebResponse rs = rq.GetResponse()) { }
            }
        }

        /// <summary>Borra los blobs de prueba subidos (la SAS debe incluir permiso de borrado).</summary>
        void Cleanup(SpeedEndpoint ep)
        {
            List<string> list; lock (createdBlobs) { list = createdBlobs.ToList(); createdBlobs.Clear(); }
            int ok = 0;
            System.Threading.Tasks.Parallel.ForEach(list, new ParallelOptions { MaxDegreeOfParallelism = 8 }, delegate (string u)
            {
                try
                {
                    HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(u);
                    rq.Method = "DELETE"; rq.Timeout = 10000;
                    using (rq.GetResponse()) { }
                    Interlocked.Increment(ref ok);
                }
                catch { }
            });
            if (list.Count > 0 && ok < list.Count) Log.Enqueue(string.Format("Limpieza: {0} de {1} blobs de prueba borrados (el resto los borra la regla de ciclo de vida).", ok, list.Count));
        }

        static string Short(Exception ex)
        {
            WebException we = ex as WebException;
            if (we != null && we.Response is HttpWebResponse) return "HTTP " + (int)((HttpWebResponse)we.Response).StatusCode + " " + ((HttpWebResponse)we.Response).StatusDescription;
            return ex.Message;
        }

        /// <summary>Sube un archivo concreto (prueba de subida de archivo) y devuelve Mbps.</summary>
        public static double UploadFile(SpeedEndpoint ep, string path, Action<double> progress, CancellationToken tk)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            string url = ep.UploadUrl.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)[0].Trim();
            bool azure = string.Equals(ep.UploadKind, "azure-container", StringComparison.OrdinalIgnoreCase);
            if (azure)
            {
                int q = url.IndexOf('?');
                string blob = "cloudspeed-archivo-" + Guid.NewGuid().ToString("N").Substring(0, 12) + ".bin";
                url = (q < 0 ? url.TrimEnd('/') + "/" + blob : url.Substring(0, q).TrimEnd('/') + "/" + blob + url.Substring(q));
            }
            FileInfo fi = new FileInfo(path);
            if (fi.Length > 5000L * 1024 * 1024) throw new InvalidOperationException("El archivo supera 5000 MiB.");
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.Method = "PUT"; rq.Timeout = 600000; rq.ReadWriteTimeout = 600000;
            rq.AllowWriteStreamBuffering = false; rq.ContentLength = fi.Length;
            if (azure) rq.Headers["x-ms-blob-type"] = "BlockBlob";
            Stopwatch sw = Stopwatch.StartNew();
            using (tk.Register(delegate { try { rq.Abort(); } catch { } }))
            {
                using (Stream s = rq.GetRequestStream())
                using (FileStream f = File.OpenRead(path))
                {
                    byte[] buf = new byte[256 * 1024]; int n; long sent = 0;
                    while ((n = f.Read(buf, 0, buf.Length)) > 0)
                    {
                        tk.ThrowIfCancellationRequested();
                        s.Write(buf, 0, n); sent += n;
                        if (progress != null) progress(sent / (double)fi.Length);
                    }
                }
                using (rq.GetResponse()) { }
            }
            double secs = sw.Elapsed.TotalSeconds;
            if (azure) { try { HttpWebRequest d = (HttpWebRequest)WebRequest.Create(url); d.Method = "DELETE"; using (d.GetResponse()) { } } catch { } }
            return fi.Length * 8 / 1e6 / Math.Max(0.001, secs);
        }
    }
}
