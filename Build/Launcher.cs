// Lanzador de Eureka_CloudSpeed (no necesita permisos de administrador).
//  - Compilado sin SINGLEFILE  -> Eureka_CloudSpeed.exe: se coloca junto a Eureka_CloudSpeed.ps1 y
//    comprueba la huella SHA-256 de cada archivo de código antes de ejecutar nada.
//  - Compilado con SINGLEFILE  -> Eureka_CloudSpeed_Portable.exe: lleva todo dentro (payload.zip), lo
//    extrae en %LOCALAPPDATA%\Eureka_CloudSpeed\run-<guid>, lo ejecuta y lo borra al terminar.
//    El histórico y las exportaciones se guardan junto al .exe, en Eureka_CloudSpeed_Datos.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;
#if SINGLEFILE
using System.IO.Compression;
#endif

[assembly: AssemblyTitle("Eureka_CloudSpeed")]
[assembly: AssemblyDescription("Latencia desde este equipo a las regiones de Azure y AWS, con exportación a Excel y Power BI")]
[assembly: AssemblyProduct("Eureka_CloudSpeed")]
[assembly: AssemblyCopyright("Juan Raúl Ruiz · MIT")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]

static class Program
{
    const string Title = "Eureka_CloudSpeed";

    [STAThread]
    static int Main(string[] args)
    {
        string runDir = null;
        try
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string root = exeDir;
#if SINGLEFILE
            runDir = Extract();
            root = runDir;
            Environment.SetEnvironmentVariable("CFG_DATA", Path.Combine(exeDir, "Eureka_CloudSpeed_Datos"));
#endif
            string script = Path.Combine(root, "Eureka_CloudSpeed.ps1");
            if (!File.Exists(script))
            {
                MessageBox.Show("No se encuentra Eureka_CloudSpeed.ps1 junto al ejecutable.\n\nCopia la carpeta completa (Engine, Modules, UI, Catalog...) o usa Eureka_CloudSpeed_Portable.exe.",
                    Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }
#if !SINGLEFILE
            string problem = Integrity.Verify(root);
            if (problem != null)
            {
                MessageBox.Show("Por seguridad no se ha iniciado Eureka_CloudSpeed: los archivos de código no coinciden con los que se publicaron junto a este ejecutable.\n\n" + problem +
                    "\n\nVuelve a descargarlo completo. Si has modificado el código a propósito, usa Eureka_CloudSpeed.cmd o genera de nuevo el .exe con Build\\Build-Exe.ps1.",
                    Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 3;
            }
#endif
            bool console = false;
            foreach (string a in args) if (a.TrimStart('-', '/').Equals("SinInterfaz", StringComparison.OrdinalIgnoreCase)) console = true;

            StringBuilder sb = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -File " + Quote(script));
            foreach (string a in args) sb.Append(' ').Append(Quote(a));
            if (!console) sb.Append(" -OcultarConsola");

            string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo psi = new ProcessStartInfo(ps, sb.ToString());
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Environment.SystemDirectory;   // nunca la carpeta de la herramienta
            psi.CreateNoWindow = !console;
            if (!console) psi.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("No se pudo iniciar Eureka_CloudSpeed:\n\n" + ex.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            if (runDir != null) { try { Directory.Delete(runDir, true); } catch { } }
        }
    }

    static string Quote(string a)
    {
        if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return a;
        return "\"" + a.Replace("\\\"", "\\\\\"").Replace("\"", "\\\"") + "\"";
    }

#if SINGLEFILE
    static string Extract()
    {
        // Carpeta del perfil del usuario: solo él (y los administradores) pueden escribir en ella
        string baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Eureka_CloudSpeed");
        Directory.CreateDirectory(baseDir);
        foreach (string old in Directory.GetDirectories(baseDir, "run-*"))
        {
            try { if (Directory.GetCreationTimeUtc(old) < DateTime.UtcNow.AddHours(-12)) Directory.Delete(old, true); } catch { }
        }
        string dir = Path.Combine(baseDir, "run-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream s = asm.GetManifestResourceStream("payload.zip"))
        {
            if (s == null) throw new InvalidOperationException("El ejecutable no contiene Eureka_CloudSpeed (payload.zip).");
            using (ZipArchive zip = new ZipArchive(s, ZipArchiveMode.Read))
            {
                string full = Path.GetFullPath(dir) + Path.DirectorySeparatorChar;
                foreach (ZipArchiveEntry e in zip.Entries)
                {
                    string target = Path.GetFullPath(Path.Combine(dir, e.FullName.Replace('/', Path.DirectorySeparatorChar)));
                    if (!target.StartsWith(full, StringComparison.OrdinalIgnoreCase)) continue;   // evita rutas fuera de la carpeta
                    if (e.FullName.EndsWith("/")) { Directory.CreateDirectory(target); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    e.ExtractToFile(target, true);
                }
            }
        }
        return dir;
    }
#endif
}

#if !SINGLEFILE
// Verificación de integridad: compara el código con la lista de huellas incrustada al compilar
// (recurso "manifest.txt", líneas "<sha256> <ruta relativa>").
public static class Integrity
{
    static readonly string[] Patterns = { "*.ps1", "*.psm1", "*.xaml", "*.cs", "*.json" };
    static readonly string[] SkipDirs = { "Build", "Dist", "Datos", "Exportaciones", "Config", ".git", ".github", ".signpath", "Tests", "Eureka_CloudSpeed_Datos" };

    public static string Verify(string root)
    {
        System.Collections.Generic.Dictionary<string, string> expected = Load();
        if (expected == null) return null;
        StringBuilder problems = new StringBuilder();
        int n = 0;
        foreach (System.Collections.Generic.KeyValuePair<string, string> kv in expected)
        {
            string file = Path.Combine(root, kv.Key.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(file)) { Add(problems, ref n, "Falta: " + kv.Key); continue; }
            if (!string.Equals(Hash(file), kv.Value, StringComparison.OrdinalIgnoreCase)) Add(problems, ref n, "Modificado: " + kv.Key);
        }
        string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (string pattern in Patterns)
        {
            foreach (string f in Directory.GetFiles(full, pattern, SearchOption.AllDirectories))
            {
                string rel = f.Substring(full.Length).Replace(Path.DirectorySeparatorChar, '/');
                string top = rel.Contains("/") ? rel.Substring(0, rel.IndexOf('/')) : "";
                if (Array.IndexOf(SkipDirs, top) >= 0) continue;
                if (!expected.ContainsKey(rel)) Add(problems, ref n, "Añadido: " + rel);
            }
        }
        return n == 0 ? null : problems.ToString();
    }

    static void Add(StringBuilder sb, ref int n, string line)
    {
        n++;
        if (n <= 8) sb.AppendLine("• " + line);
        else if (n == 9) sb.AppendLine("• ...");
    }

    static System.Collections.Generic.Dictionary<string, string> Load()
    {
        Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("manifest.txt");
        if (s == null) return null;
        System.Collections.Generic.Dictionary<string, string> d = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using (StreamReader r = new StreamReader(s, Encoding.UTF8))
        {
            string line;
            while ((line = r.ReadLine()) != null)
            {
                int sp = line.IndexOf(' ');
                if (sp == 64) d[line.Substring(65).Trim()] = line.Substring(0, 64);
            }
        }
        return d;
    }

    public static string Hash(string file)
    {
        using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
        using (FileStream fs = File.OpenRead(file))
            return BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "");
    }
}
#endif
