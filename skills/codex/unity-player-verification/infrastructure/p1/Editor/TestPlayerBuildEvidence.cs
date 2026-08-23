using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.TestTools;
using UnityEngine;

[assembly: TestPlayerBuildModifier(typeof(UnityPlayerVerification.TestPlayerBuildEvidence))]

namespace UnityPlayerVerification
{
    [Serializable]
    internal sealed class PlayerBuildReportReceipt
    {
        public string schemaVersion = "1.0.0";
        public string sessionToken;
        public string result;
        public string outputPath;
        public string platform;
        public string scriptingBackend;
        public string buildGuid;
        public ulong totalSize;
        public int totalErrors;
        public int totalWarnings;
        public string startedAtUtc;
        public double durationSeconds;
    }

    /// <summary>Fixes the Test Player output and records the completed Unity BuildReport.</summary>
    public sealed class TestPlayerBuildEvidence : ITestPlayerBuildModifier, IPostprocessBuildWithReport
    {
        /// <summary>Runs after other build callbacks so the final report is retained.</summary>
        public int callbackOrder
        {
            get { return int.MaxValue; }
        }

        /// <summary>Forces the verifier-owned Windows x64 Mono Test Player output path.</summary>
        public BuildPlayerOptions ModifyOptions(BuildPlayerOptions playerOptions)
        {
            var sessionRoot = ReadRequiredEnvironmentPath("UPVR_SESSION_ROOT");
            var buildExecutable = ReadRequiredChildPath("UPVR_BUILD_EXE_PATH", sessionRoot);
            if (playerOptions.target != BuildTarget.StandaloneWindows64)
            {
                throw new BuildFailedException("Unity Player Verification requires StandaloneWindows64.");
            }
            if (!string.Equals(Path.GetExtension(buildExecutable), ".exe", StringComparison.OrdinalIgnoreCase))
            {
                throw new BuildFailedException("The Test Player output must be an .exe file.");
            }
            PlayerSettings.SetScriptingBackend(BuildTargetGroup.Standalone, ScriptingImplementation.Mono2x);
            Directory.CreateDirectory(Path.GetDirectoryName(buildExecutable));
            playerOptions.locationPathName = buildExecutable;
            return playerOptions;
        }

        /// <summary>Writes a normalized build-report receipt after Unity finishes the Test Player build.</summary>
        public void OnPostprocessBuild(BuildReport report)
        {
            if (report == null)
            {
                throw new BuildFailedException("Unity supplied a null BuildReport.");
            }
            var sessionRoot = ReadRequiredEnvironmentPath("UPVR_SESSION_ROOT");
            var reportPath = ReadRequiredChildPath("UPVR_BUILD_REPORT_PATH", sessionRoot);
            var summary = report.summary;
            var receipt = new PlayerBuildReportReceipt
            {
                sessionToken = ReadRequiredEnvironmentValue("UPVR_SESSION_TOKEN"),
                result = summary.result.ToString(),
                outputPath = Path.GetFullPath(summary.outputPath),
                platform = summary.platform.ToString(),
                scriptingBackend = PlayerSettings.GetScriptingBackend(BuildTargetGroup.Standalone).ToString(),
                buildGuid = summary.guid.ToString(),
                totalSize = summary.totalSize,
                totalErrors = summary.totalErrors,
                totalWarnings = summary.totalWarnings,
                startedAtUtc = summary.buildStartedAt.ToUniversalTime().ToString("O"),
                durationSeconds = summary.totalTime.TotalSeconds
            };
            WriteAtomicText(reportPath, JsonUtility.ToJson(receipt, true));
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
                throw new BuildFailedException("Required verifier environment variable is missing: " + name);
            }
            return value;
        }

        /// <summary>Reads one required absolute verifier environment path.</summary>
        private static string ReadRequiredEnvironmentPath(string name)
        {
            var path = Path.GetFullPath(ReadRequiredEnvironmentValue(name));
            if (!Path.IsPathRooted(path))
            {
                throw new BuildFailedException("Verifier path is not absolute: " + name);
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
                throw new BuildFailedException("Verifier artifact escapes the session root: " + name);
            }
            return path;
        }
    }
}
