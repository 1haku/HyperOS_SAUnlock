using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace HyperOSSAUnlock
{
    public sealed class CommandResult
    {
        public int Status;
        public string Stdout;
        public string Stderr;
        public bool Truncated;
    }

    public static class ProcessRunner
    {
        private sealed class Capture
        {
            public string Text;
            public bool Truncated;
        }

        // Windows PowerShell 5.1 lacks ProcessStartInfo.ArgumentList. Escape each
        // argument using Windows argv rules, without invoking cmd.exe.
        public static string QuoteArgument(string value)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"')
                {
                    result.Append('\\', slashes * 2 + 1).Append(c);
                }
                else
                {
                    result.Append('\\', slashes).Append(c);
                }
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        private static async Task<Capture> DrainAsync(StreamReader reader)
        {
            const int limit = 1048576;
            var text = new StringBuilder();
            var buffer = new char[8192];
            bool truncated = false;
            int count;
            while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0)
            {
                int kept = Math.Min(count, limit - text.Length);
                text.Append(buffer, 0, kept);
                truncated |= kept < count;
            }
            return new Capture { Text = text.ToString(), Truncated = truncated };
        }

        public static CommandResult Run(string executable, string[] arguments, int timeoutMilliseconds)
        {
            if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            var quoted = Array.ConvertAll(arguments, QuoteArgument);
            using (var process = new Process())
            {
                process.StartInfo = new ProcessStartInfo
                {
                    FileName = executable,
                    Arguments = String.Join(" ", quoted),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = new UTF8Encoding(false),
                    StandardErrorEncoding = new UTF8Encoding(false)
                };
                bool started = false;
                try
                {
                    started = process.Start();
                    process.StandardInput.Close();
                    var clock = Stopwatch.StartNew();
                    var stdout = DrainAsync(process.StandardOutput);
                    var stderr = DrainAsync(process.StandardError);
                    // Read both streams concurrently. Bound the EOF wait too, as an
                    // ADB server or another child can inherit the output handles.
                    if (!process.WaitForExit(timeoutMilliseconds))
                        throw new TimeoutException("ADB command timed out.");
                    int remaining = Math.Max(0, timeoutMilliseconds - (int)clock.ElapsedMilliseconds);
                    if (!Task.WaitAll(new Task[] { stdout, stderr }, remaining))
                        throw new TimeoutException("ADB output timed out.");
                    return new CommandResult
                    {
                        Status = process.ExitCode,
                        Stdout = stdout.Result.Text,
                        Stderr = stderr.Result.Text,
                        Truncated = stdout.Result.Truncated || stderr.Result.Truncated
                    };
                }
                finally
                {
                    if (started)
                    {
                        if (!process.HasExited)
                        {
                            try { process.Kill(); }
                            catch (InvalidOperationException) { /* Exited between the check and Kill. */ }
                            process.WaitForExit(1000);
                        }
                        process.StandardOutput.Close();
                        process.StandardError.Close();
                    }
                }
            }
        }
    }
}
