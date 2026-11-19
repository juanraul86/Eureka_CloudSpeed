// Status.cs - Comprobaciones propias del estado de los servicios desde la red de este equipo.
// Sirven cuando la página de estado oficial no dice nada o también ha caído (caídas globales): se mide
// la resolución DNS, la conexión TCP y la respuesta HTTPS de cada servicio clave.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace CloudSpeed
{
    public class StatusRow
    {
        public string Source { get; set; }      // "Oficial" o "Desde tu red"
        public string Provider { get; set; }
        public string Service { get; set; }
        /// <summary>0 = operativo, 1 = aviso, 2 = degradado, 3 = interrupción, -1 = sin datos</summary>
        public int Level { get; set; }
        public string State { get; set; }
        public string Detail { get; set; }
        public string Updated { get; set; }
        public string Page { get; set; }
        public double? DnsMs { get; set; }
        public double? ConnectMs { get; set; }
        public double? HttpMs { get; set; }
        public int? Code { get; set; }
        public string Host { get; set; }
        public DateTime Time { get; set; }
        public string LevelColor
        {
            get
            {
                switch (Level)
                {
                    case 0: return "#22C55E";
                    case 1: return "#3B82F6";
                    case 2: return "#F59E0B";
                    case 3: return "#EF4444";
                    default: return "#9CA3AF";
                }
            }
        }
        public static string LevelName(int l)
        {
            switch (l)
            {
                case 0: return "Operativo";
                case 1: return "Aviso";
                case 2: return "Degradado";
                case 3: return "Interrupción";
                default: return "Sin datos";
            }
        }
    }

    public class ProbeTarget
    {
        public string Provider { get; set; }
        public string Service { get; set; }
        public string Url { get; set; }
    }

    public static class StatusProbe
    {
        public static List<StatusRow> Run(IEnumerable<ProbeTarget> targets, int timeoutMs)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            List<ProbeTarget> list = targets.ToList();
            StatusRow[] res = new StatusRow[list.Count];
            System.Threading.Tasks.Parallel.For(0, list.Count, new ParallelOptions { MaxDegreeOfParallelism = 12 }, delegate (int i) { res[i] = One(list[i], timeoutMs); });
            return res.ToList();
        }

        static StatusRow One(ProbeTarget t, int timeoutMs)
        {
            StatusRow r = new StatusRow { Source = "Desde tu red", Provider = t.Provider, Service = t.Service, Time = DateTime.Now, Updated = DateTime.Now.ToString("HH:mm:ss"), Page = t.Url };
            Uri u;
            if (!Uri.TryCreate(t.Url, UriKind.Absolute, out u) || u.Scheme != "https") { r.Level = -1; r.State = "Sin datos"; r.Detail = "URL no válida"; return r; }
            r.Host = u.Host;
            // 1. DNS
            IPAddress ip;
            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                Task<IPAddress[]> dt = Dns.GetHostAddressesAsync(u.Host);
                if (!dt.Wait(timeoutMs)) throw new TimeoutException("DNS sin respuesta");
                ip = dt.Result.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork) ?? dt.Result.FirstOrDefault();
                if (ip == null) throw new Exception("DNS sin direcciones");
                r.DnsMs = Math.Round(sw.Elapsed.TotalMilliseconds, 1);
            }
            catch (Exception ex) { r.Level = 3; r.State = "No responde"; r.Detail = "DNS: " + Inner(ex); return r; }
            // 2. TCP 443
            double tlsMs; string err;
            double tcp = ProbeEngine.Connect(ip, 443, u.Host, timeoutMs, false, out tlsMs, out err);
            if (double.IsNaN(tcp)) { r.Level = 3; r.State = "No responde"; r.Detail = "Conexión TCP: " + err; return r; }
            r.ConnectMs = Math.Round(tcp, 1);
            // 3. HTTPS: cualquier respuesta < 500 significa que el servicio contesta
            sw.Restart();
            try
            {
                HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(u);
                rq.Method = "GET"; rq.AllowAutoRedirect = false; rq.Timeout = timeoutMs * 2; rq.ReadWriteTimeout = timeoutMs * 2;
                rq.UserAgent = "Eureka_CloudSpeed/1.0 (comprobacion de estado)";
                using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse()) r.Code = (int)rs.StatusCode;
            }
            catch (WebException we)
            {
                HttpWebResponse rs = we.Response as HttpWebResponse;
                if (rs != null) { r.Code = (int)rs.StatusCode; rs.Close(); }
                else { r.HttpMs = Math.Round(sw.Elapsed.TotalMilliseconds, 1); r.Level = 3; r.State = "No responde"; r.Detail = "HTTPS: " + Inner(we); return r; }
            }
            catch (Exception ex) { r.Level = 3; r.State = "No responde"; r.Detail = "HTTPS: " + Inner(ex); return r; }
            r.HttpMs = Math.Round(sw.Elapsed.TotalMilliseconds, 1);
            if (r.Code >= 500) { r.Level = 2; r.State = "Error del servidor"; r.Detail = "HTTP " + r.Code; }
            else if (r.HttpMs > 5000) { r.Level = 2; r.State = "Muy lento"; r.Detail = "HTTP " + r.Code + " en " + Math.Round(r.HttpMs.Value / 1000, 1) + " s"; }
            else { r.Level = 0; r.State = "Responde"; r.Detail = "HTTP " + r.Code; }
            return r;
        }

        static string Inner(Exception ex)
        {
            while (ex.InnerException != null) ex = ex.InnerException;
            SocketException se = ex as SocketException;
            return se != null ? "Socket " + se.SocketErrorCode : ex.Message;
        }
    }
}
