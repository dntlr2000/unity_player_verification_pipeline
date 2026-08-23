using System;
using System.IO;
using NUnit.Framework.Interfaces;
using UnityEngine;
using UnityEngine.TestRunner;

[assembly: TestRunCallback(typeof(UnityPlayerVerification.PlayerTestRunReceiptWriter))]

namespace UnityPlayerVerification
{
    [Serializable]
    internal sealed class PlayerTestRunReceipt
    {
        public string schemaVersion = "1.0.0";
        public string sessionToken;
        public bool runStarted;
        public bool runFinished;
        public string resultState;
        public string nunitPath;
        public string unityVersion;
        public string productName;
        public int processId;
        public string error;
    }

    /// <summary>Writes independent Player-side NUnit, receipt, and runtime-log evidence.</summary>
    public sealed class PlayerTestRunReceiptWriter : ITestRunCallback
    {
        private readonly string receiptPath;
        private readonly string nunitPath;
        private readonly string runtimeLogPath;
        private readonly string sessionToken;
        private bool started;

        /// <summary>Reads and validates verifier-owned artifact paths inherited by the Test Player.</summary>
        public PlayerTestRunReceiptWriter()
        {
            var sessionRoot = ReadRequiredEnvironmentPath("UPVR_SESSION_ROOT");
            receiptPath = ReadRequiredChildPath("UPVR_RUNTIME_RECEIPT_PATH", sessionRoot);
            nunitPath = ReadRequiredChildPath("UPVR_RUNTIME_NUNIT_PATH", sessionRoot);
            runtimeLogPath = ReadRequiredChildPath("UPVR_RUNTIME_LOG_PATH", sessionRoot);
            sessionToken = ReadRequiredEnvironmentValue("UPVR_SESSION_TOKEN");
            Directory.CreateDirectory(Path.GetDirectoryName(receiptPath));
            Application.logMessageReceivedThreaded += HandleLogMessage;
        }

        /// <summary>Records that NUnit began executing the Player-side test tree.</summary>
        public void RunStarted(ITest testsToRun)
        {
            started = true;
            AppendRuntimeLog("UPVR_RUNTIME_RUN_STARTED " + (testsToRun == null ? "<null>" : testsToRun.FullName));
        }

        /// <summary>Writes the completed NUnit tree and an atomic receipt before the Test Player exits.</summary>
        public void RunFinished(ITestResult testResults)
        {
            try
            {
                if (testResults == null)
                {
                    throw new InvalidOperationException("NUnit supplied a null completed result.");
                }
                WriteAtomicText(nunitPath, testResults.ToXml(true).OuterXml);
                var receipt = new PlayerTestRunReceipt
                {
                    sessionToken = sessionToken,
                    runStarted = started,
                    runFinished = true,
                    resultState = testResults.ResultState == null ? null : testResults.ResultState.ToString(),
                    nunitPath = nunitPath,
                    unityVersion = Application.unityVersion,
                    productName = Application.productName,
                    processId = System.Diagnostics.Process.GetCurrentProcess().Id
                };
                WriteAtomicText(receiptPath, JsonUtility.ToJson(receipt, true));
                AppendRuntimeLog("UPVR_RUNTIME_RUN_FINISHED " + receipt.resultState);
            }
            catch (Exception exception)
            {
                AppendRuntimeLog("UPVR_RUNTIME_RECEIPT_ERROR " + exception);
                throw;
            }
            finally
            {
                Application.logMessageReceivedThreaded -= HandleLogMessage;
            }
        }

        /// <summary>Records the beginning of one NUnit node without changing verdict evidence.</summary>
        public void TestStarted(ITest test)
        {
        }

        /// <summary>Records the completion of one NUnit node without duplicating the result tree.</summary>
        public void TestFinished(ITestResult result)
        {
        }

        /// <summary>Copies Unity runtime messages into the verifier-owned runtime log.</summary>
        private void HandleLogMessage(string condition, string stackTrace, LogType type)
        {
            AppendRuntimeLog(type + " " + condition + (string.IsNullOrEmpty(stackTrace) ? string.Empty : Environment.NewLine + stackTrace));
        }

        /// <summary>Appends one timestamped line while allowing concurrent Unity log callbacks.</summary>
        private void AppendRuntimeLog(string message)
        {
            try
            {
                var line = DateTime.UtcNow.ToString("O") + " " + message + Environment.NewLine;
                using (var stream = new FileStream(runtimeLogPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                using (var writer = new StreamWriter(stream))
                {
                    writer.Write(line);
                }
            }
            catch
            {
                // The required receipt remains authoritative when diagnostic log append fails.
            }
        }

        /// <summary>Writes one UTF-8 artifact through a same-directory atomic replacement.</summary>
        private static void WriteAtomicText(string path, string content)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var temporaryPath = path + ".tmp";
            File.WriteAllText(temporaryPath, content);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
            File.Move(temporaryPath, path);
        }

        /// <summary>Reads one required non-empty verifier environment value.</summary>
        private static string ReadRequiredEnvironmentValue(string name)
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException("Required verifier environment variable is missing: " + name);
            }
            return value;
        }

        /// <summary>Reads one required absolute verifier environment path.</summary>
        private static string ReadRequiredEnvironmentPath(string name)
        {
            var path = Path.GetFullPath(ReadRequiredEnvironmentValue(name));
            if (!Path.IsPathRooted(path))
            {
                throw new InvalidOperationException("Verifier path is not absolute: " + name);
            }
            return path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        /// <summary>Accepts an artifact path only when it is strictly below the session root.</summary>
        private static string ReadRequiredChildPath(string name, string sessionRoot)
        {
            var path = ReadRequiredEnvironmentPath(name);
            var prefix = sessionRoot + Path.DirectorySeparatorChar;
            if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Verifier artifact escapes the session root: " + name);
            }
            return path;
        }
    }
}
