// Net.cs - Rangos de IP de Azure (Service Tags de Microsoft: Public, China y US Government) y de AWS
// (ip-ranges.json), y búsqueda de a qué servicio y región pertenece una dirección IP.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Web.Script.Serialization;

namespace CloudSpeed
{
    public class IpPrefix
    {
        public byte[] Net;
        public int Bits;
        public string Text;
        public bool IsV6 { get { return Net.Length == 16; } }

        public static bool TryParse(string s, out IpPrefix p)
        {
            p = null;
            if (string.IsNullOrEmpty(s)) return false;
            string[] parts = s.Trim().Split('/');
            IPAddress a;
            if (!IPAddress.TryParse(parts[0], out a)) return false;
            byte[] b = a.GetAddressBytes();
            int bits = b.Length * 8;
            if (parts.Length > 1 && !int.TryParse(parts[1], out bits)) return false;
            p = new IpPrefix { Net = b, Bits = Math.Max(0, Math.Min(b.Length * 8, bits)), Text = s.Trim() };
            return true;
        }

        public bool Contains(byte[] addr)
        {
            if (addr.Length != Net.Length) return false;
            int full = Bits / 8, rem = Bits % 8;
            for (int i = 0; i < full; i++) if (addr[i] != Net[i]) return false;
            if (rem == 0) return true;
            int mask = 0xFF << (8 - rem) & 0xFF;
            return (addr[full] & mask) == (Net[full] & mask);
        }
    }

    public class IpRangeEntry
    {
        public string Cloud { get; set; }
        public string Name { get; set; }
        public string Service { get; set; }
        public string Region { get; set; }
        public List<IpPrefix> Prefixes = new List<IpPrefix>();
        public int V4 { get { return Prefixes.Count(p => !p.IsV6); } }
        public int V6 { get { return Prefixes.Count(p => p.IsV6); } }
        public string Text(bool v4, bool v6)
        {
            return string.Join(Environment.NewLine, Prefixes.Where(p => p.IsV6 ? v6 : v4).Select(p => p.Text));
        }
    }

    public class IpMatch
    {
        public string Ip { get; set; }
        public string Cloud { get; set; }
        public string Name { get; set; }
        public string Service { get; set; }
        public string Region { get; set; }
        public string Prefix { get; set; }
        public int Bits { get; set; }
    }

    public static class IpRanges
    {
        static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 }; }
        static string S(IDictionary d, string k) { object v = d != null && d.Contains(k) ? d[k] : null; return v == null ? "" : Convert.ToString(v); }

        /// <summary>Carga un ServiceTags_*.json de Microsoft.</summary>
        public static List<IpRangeEntry> LoadAzure(string json, string cloud)
        {
            List<IpRangeEntry> list = new List<IpRangeEntry>();
            IDictionary root = (IDictionary)Json().DeserializeObject(json);
            foreach (object o in (IEnumerable)root["values"])
            {
                IDictionary v = (IDictionary)o;
                IDictionary pr = (IDictionary)v["properties"];
                IpRangeEntry e = new IpRangeEntry { Cloud = cloud, Name = S(v, "name"), Service = S(pr, "systemService"), Region = S(pr, "region") };
                if (string.IsNullOrEmpty(e.Service)) e.Service = e.Name.Split('.')[0];
                object ap = pr.Contains("addressPrefixes") ? pr["addressPrefixes"] : null;
                if (ap is IEnumerable)
                    foreach (object x in (IEnumerable)ap) { IpPrefix p; if (IpPrefix.TryParse(Convert.ToString(x), out p)) e.Prefixes.Add(p); }
                list.Add(e);
            }
            return list;
        }

        /// <summary>Carga ip-ranges.json de AWS agrupando por servicio y región.</summary>
        public static List<IpRangeEntry> LoadAws(string json)
        {
            Dictionary<string, IpRangeEntry> map = new Dictionary<string, IpRangeEntry>();
            IDictionary root = (IDictionary)Json().DeserializeObject(json);
            foreach (string[] k in new[] { new[] { "prefixes", "ip_prefix" }, new[] { "ipv6_prefixes", "ipv6_prefix" } })
            {
                if (!root.Contains(k[0])) continue;
                foreach (object o in (IEnumerable)root[k[0]])
                {
                    IDictionary v = (IDictionary)o;
                    string svc = S(v, "service"), reg = S(v, "region");
                    string key = svc + "." + reg;
                    IpRangeEntry e;
                    if (!map.TryGetValue(key, out e)) { e = new IpRangeEntry { Cloud = "AWS", Name = key, Service = svc, Region = reg }; map[key] = e; }
                    IpPrefix p; if (IpPrefix.TryParse(S(v, k[1]), out p)) e.Prefixes.Add(p);
                }
            }
            return map.Values.OrderBy(x => x.Service).ThenBy(x => x.Region).ToList();
        }

        public static List<IpMatch> Lookup(IEnumerable<IpRangeEntry> entries, IPAddress ip)
        {
            byte[] b = ip.GetAddressBytes();
            List<IpMatch> r = new List<IpMatch>();
            foreach (IpRangeEntry e in entries)
                foreach (IpPrefix p in e.Prefixes)
                    if (p.Contains(b)) r.Add(new IpMatch { Ip = ip.ToString(), Cloud = e.Cloud, Name = e.Name, Service = e.Service, Region = e.Region, Prefix = p.Text, Bits = p.Bits });
            // La coincidencia más específica primero; las etiquetas regionales antes que las globales
            return r.OrderByDescending(x => x.Bits).ThenBy(x => string.IsNullOrEmpty(x.Region) ? 1 : 0).ThenBy(x => x.Name).ToList();
        }
    }
}
