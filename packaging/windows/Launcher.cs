using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

internal static class Launcher {
    [STAThread]
    private static int Main(string[] args) {
        try {
            byte[] payload;
            using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (var buffer = new MemoryStream()) {
                if (resource == null) throw new IOException("Missing application payload.");
                resource.CopyTo(buffer);
                payload = buffer.ToArray();
            }
            string version;
            using (var sha = SHA256.Create())
                version = BitConverter.ToString(sha.ComputeHash(payload)).Replace("-", "").Substring(0, 16);
            bool verify = args.Length == 2 && args[0] == "--verify";
            var root = verify ? Path.GetFullPath(args[1]) : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "WindowControl", "versions", version);
            var executable = Path.Combine(root, "window_control.exe");
            if (!File.Exists(Path.Combine(root, "complete.marker"))) {
                var staging = root + ".staging-" + Guid.NewGuid().ToString("N");
                Directory.CreateDirectory(staging);
                try {
                    using (var zip = new ZipArchive(new MemoryStream(payload), ZipArchiveMode.Read)) {
                        var prefix = Path.GetFullPath(staging) + Path.DirectorySeparatorChar;
                        foreach (var entry in zip.Entries) {
                            var path = Path.GetFullPath(Path.Combine(staging, entry.FullName));
                            if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                                throw new IOException("Invalid embedded archive path.");
                            if (String.IsNullOrEmpty(entry.Name)) { Directory.CreateDirectory(path); continue; }
                            Directory.CreateDirectory(Path.GetDirectoryName(path));
                            entry.ExtractToFile(path, false);
                        }
                    }
                    foreach (var required in new[] { "window_control.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat" })
                        if (!File.Exists(Path.Combine(staging, required))) throw new IOException("Incomplete application payload.");
                    File.WriteAllText(Path.Combine(staging, "complete.marker"), version, Encoding.ASCII);
                    Directory.CreateDirectory(Path.GetDirectoryName(root));
                    try { Directory.Move(staging, root); }
                    catch (IOException) {
                        if (!File.Exists(Path.Combine(root, "complete.marker"))) throw;
                    }
                } finally {
                    if (Directory.Exists(staging)) Directory.Delete(staging, true);
                }
            }
            if (verify) return 0;
            Environment.SetEnvironmentVariable("WINDOW_CONTROL_LAUNCHER_PATH", Assembly.GetExecutingAssembly().Location);
            Process.Start(new ProcessStartInfo(executable) {
                WorkingDirectory = root,
                UseShellExecute = true
            });
            return 0;
        } catch (Exception error) {
            MessageBox.Show("Unable to start Window Control.\n\n" + error.Message,
                "Window Control", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
