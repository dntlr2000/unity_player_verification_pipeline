using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace UnityPlayerVerification
{
    [Serializable]
    internal sealed class StandaloneBuildContract
    {
        public string schemaVersion;
        public string sessionToken;
        public string originalFingerprint;
        public string overlayTreeSha256;
        public string scenarioBundleTreeSha256;
        public string windowsModuleTreeSha256;
        public string toolchainProfileId;
        public string buildToolchainIdentityAlgorithm;
        public string buildToolchainIdentitySha256;
        public string hostEnvironmentIdentityAlgorithm;
        public string hostEnvironmentIdentitySha256;
        public string requestedBackend;
        public string scenarioId;
        public string displayName;
        public int timeoutSeconds;
        public string[] buildScenes;
        public string[] expectedScenes;
        public string[] expectedAssertionIds;
        public string[] expectedCaptureIds;
        public bool graphicsRequired;
    }

    [Serializable]
    internal sealed class StandaloneBuildReportReceipt
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
        public string[] errors;
        public string[] warnings;
        public string startedAtUtc;
        public double durationSeconds;
    }

    [Serializable]
    internal sealed class StandaloneScenarioIdentity
    {
        public string scenarioId;
        public string displayName;
        public int timeoutSeconds;
        public string[] buildScenes;
        public string[] expectedScenes;
        public string[] expectedAssertionIds;
        public string[] expectedCaptureIds;
        public bool graphicsRequired;
    }

    [Serializable]
    internal sealed class StandaloneBuildReceipt
    {
        public string schemaVersion = "1.1.0";
        public string sessionToken;
        public string originalFingerprint;
        public string overlayTreeSha256;
        public string scenarioBundleTreeSha256;
        public string unityVersion;
        public string windowsModuleTreeSha256;
        public string toolchainProfileId;
        public string buildToolchainIdentityAlgorithm;
        public string buildToolchainIdentitySha256;
        public string hostEnvironmentIdentityAlgorithm;
        public string hostEnvironmentIdentitySha256;
        public string scriptingBackend;
        public string[] scenes;
        public string buildOptions;
        public bool developmentBuild;
        public string buildGuid;
        public string executablePath;
        public string executableSha256;
        public string buildRoot;
        public string treeCanonicalization;
        public string buildTreeSha256;
        public int fileCount;
        public int directoryCount;
        public long totalBytes;
        public StandaloneScenarioIdentity scenario;
    }

    internal sealed class StandaloneTreeIdentity
    {
        public string sha256;
        public int fileCount;
        public int directoryCount;
        public long totalBytes;
    }

    /// <summary>Builds one non-development instrumented Windows Standalone from the isolated project.</summary>
    public static class StandaloneBuildEntry
    {
        private const string TreeCanonicalization = "upvr-tree-relative-path-length-sha256-lf-v1";

        /// <summary>Executes the fixed BuildPipeline contract and writes independent report and identity receipts.</summary>
        public static void Build()
        {
            var sessionRoot = ReadRequiredEnvironmentPath("UPVR_SESSION_ROOT");
            var contractPath = ReadRequiredChildPath("UPVR_STANDALONE_BUILD_CONTRACT_PATH", sessionRoot);
            var executablePath = ReadRequiredChildPath("UPVR_BUILD_EXE_PATH", sessionRoot);
            var reportPath = ReadRequiredChildPath("UPVR_BUILD_REPORT_PATH", sessionRoot);
            var receiptPath = ReadRequiredChildPath("UPVR_BUILD_RECEIPT_PATH", sessionRoot);
            var contract = JsonUtility.FromJson<StandaloneBuildContract>(File.ReadAllText(contractPath));
            ValidateContract(contract, ReadRequiredEnvironmentValue("UPVR_SESSION_TOKEN"));
            var scenes = ResolveScenes(contract.buildScenes);
            var backend = ResolveBackend(contract.requestedBackend);
            Directory.CreateDirectory(Path.GetDirectoryName(executablePath));
            var options = new BuildPlayerOptions
            {
                scenes = scenes,
                locationPathName = executablePath,
                target = BuildTarget.StandaloneWindows64,
                targetGroup = BuildTargetGroup.Standalone,
                options = BuildOptions.None
            };
            var report = BuildPipeline.BuildPlayer(options);
            if (report == null)
            {
                throw new BuildFailedException("Unity supplied a null Standalone BuildReport.");
            }
            var summary = report.summary;
            var buildErrors = CollectMessages(report, LogType.Error, LogType.Exception, LogType.Assert);
            var buildWarnings = CollectMessages(report, LogType.Warning);
            var reportReceipt = new StandaloneBuildReportReceipt
            {
                sessionToken = contract.sessionToken,
                result = summary.result.ToString(),
                outputPath = Path.GetFullPath(summary.outputPath),
                platform = summary.platform.ToString(),
                scriptingBackend = backend,
                buildGuid = summary.guid.ToString(),
                totalSize = summary.totalSize,
                totalErrors = summary.totalErrors,
                totalWarnings = summary.totalWarnings,
                errors = buildErrors,
                warnings = buildWarnings,
                startedAtUtc = summary.buildStartedAt.ToUniversalTime().ToString("O"),
                durationSeconds = summary.totalTime.TotalSeconds
            };
            WriteAtomicText(reportPath, JsonUtility.ToJson(reportReceipt, true));
            if (summary.result != BuildResult.Succeeded || buildErrors.Length != 0)
            {
                throw new BuildFailedException("Instrumented Standalone build failed with result " + summary.result + ".");
            }

            var buildRoot = Path.GetFullPath(Path.GetDirectoryName(executablePath)).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var tree = GetTreeIdentity(buildRoot);
            var receipt = new StandaloneBuildReceipt
            {
                sessionToken = contract.sessionToken,
                originalFingerprint = contract.originalFingerprint,
                overlayTreeSha256 = contract.overlayTreeSha256,
                scenarioBundleTreeSha256 = contract.scenarioBundleTreeSha256,
                unityVersion = Application.unityVersion,
                windowsModuleTreeSha256 = contract.windowsModuleTreeSha256,
                toolchainProfileId = contract.toolchainProfileId,
                buildToolchainIdentityAlgorithm = contract.buildToolchainIdentityAlgorithm,
                buildToolchainIdentitySha256 = contract.buildToolchainIdentitySha256,
                hostEnvironmentIdentityAlgorithm = contract.hostEnvironmentIdentityAlgorithm,
                hostEnvironmentIdentitySha256 = contract.hostEnvironmentIdentitySha256,
                scriptingBackend = backend,
                scenes = scenes,
                buildOptions = BuildOptions.None.ToString(),
                developmentBuild = false,
                buildGuid = summary.guid.ToString(),
                executablePath = Path.GetFullPath(executablePath),
                executableSha256 = GetFileSha256(executablePath),
                buildRoot = buildRoot,
                treeCanonicalization = TreeCanonicalization,
                buildTreeSha256 = tree.sha256,
                fileCount = tree.fileCount,
                directoryCount = tree.directoryCount,
                totalBytes = tree.totalBytes,
                scenario = new StandaloneScenarioIdentity
                {
                    scenarioId = contract.scenarioId,
                    displayName = contract.displayName,
                    timeoutSeconds = contract.timeoutSeconds,
                    buildScenes = scenes,
                    expectedScenes = contract.expectedScenes,
                    expectedAssertionIds = contract.expectedAssertionIds,
                    expectedCaptureIds = contract.expectedCaptureIds,
                    graphicsRequired = contract.graphicsRequired
                }
            };
            WriteAtomicText(receiptPath, JsonUtility.ToJson(receipt, true));
        }

        /// <summary>Collects distinct BuildReport step messages for the requested Unity log types.</summary>
        private static string[] CollectMessages(BuildReport report, params LogType[] types)
        {
            var acceptedTypes = new HashSet<LogType>(types);
            return report.steps.SelectMany(step => step.messages)
                .Where(message => acceptedTypes.Contains(message.type))
                .Select(message => message.content ?? string.Empty)
                .Distinct(StringComparer.Ordinal)
                .OrderBy(message => message, StringComparer.Ordinal)
                .ToArray();
        }

        /// <summary>Validates the fixed build contract before changing isolated Player settings.</summary>
        private static void ValidateContract(StandaloneBuildContract contract, string expectedSessionToken)
        {
            if (contract == null || contract.schemaVersion != "1.0.0" || contract.sessionToken != expectedSessionToken ||
                string.IsNullOrWhiteSpace(contract.originalFingerprint) || string.IsNullOrWhiteSpace(contract.overlayTreeSha256) ||
                string.IsNullOrWhiteSpace(contract.scenarioBundleTreeSha256) || string.IsNullOrWhiteSpace(contract.windowsModuleTreeSha256) ||
                string.IsNullOrWhiteSpace(contract.scenarioId) || contract.timeoutSeconds <= 0 ||
                contract.buildScenes == null || contract.expectedScenes == null || contract.expectedAssertionIds == null || contract.expectedCaptureIds == null)
            {
                throw new BuildFailedException("Instrumented Standalone build contract is invalid.");
            }
            if (string.Equals(contract.requestedBackend, "IL2CPP", StringComparison.Ordinal) &&
                (string.IsNullOrWhiteSpace(contract.toolchainProfileId) ||
                 !string.Equals(contract.buildToolchainIdentityAlgorithm, "upvr-il2cpp-build-toolchain-v2", StringComparison.Ordinal) ||
                 string.IsNullOrWhiteSpace(contract.buildToolchainIdentitySha256) ||
                 !string.Equals(contract.hostEnvironmentIdentityAlgorithm, "upvr-il2cpp-host-environment-v1", StringComparison.Ordinal) ||
                 string.IsNullOrWhiteSpace(contract.hostEnvironmentIdentitySha256)))
            {
                throw new BuildFailedException("IL2CPP Standalone build contract lacks split toolchain identities.");
            }
        }

        /// <summary>Uses explicit manifest Scenes or falls back to enabled EditorBuildSettings Scenes.</summary>
        private static string[] ResolveScenes(string[] requestedScenes)
        {
            var scenes = requestedScenes != null && requestedScenes.Length > 0
                ? requestedScenes
                : EditorBuildSettings.scenes.Where(scene => scene.enabled).Select(scene => scene.path).ToArray();
            if (scenes.Length == 0)
            {
                throw new BuildFailedException("Instrumented Standalone requires at least one build Scene.");
            }
            foreach (var scene in scenes)
            {
                var normalized = (scene ?? string.Empty).Replace('\\', '/');
                if (!normalized.StartsWith("Assets/", StringComparison.Ordinal) || !normalized.EndsWith(".unity", StringComparison.OrdinalIgnoreCase) || normalized.Contains("../") || !File.Exists(normalized))
                {
                    throw new BuildFailedException("Build Scene is invalid or missing: " + scene);
                }
            }
            return scenes;
        }

        /// <summary>Applies an explicit backend or retains and records the isolated project's backend.</summary>
        private static string ResolveBackend(string requestedBackend)
        {
            if (string.Equals(requestedBackend, "Mono", StringComparison.Ordinal))
            {
                PlayerSettings.SetScriptingBackend(BuildTargetGroup.Standalone, ScriptingImplementation.Mono2x);
            }
            else if (string.Equals(requestedBackend, "IL2CPP", StringComparison.Ordinal))
            {
                PlayerSettings.SetScriptingBackend(BuildTargetGroup.Standalone, ScriptingImplementation.IL2CPP);
            }
            else if (!string.Equals(requestedBackend, "Project", StringComparison.Ordinal))
            {
                throw new BuildFailedException("Unsupported Standalone scripting backend " + requestedBackend + ".");
            }
            return PlayerSettings.GetScriptingBackend(BuildTargetGroup.Standalone) == ScriptingImplementation.IL2CPP ? "IL2CPP" : "Mono";
        }

        /// <summary>Computes a deterministic full-tree identity matching the PowerShell verifier.</summary>
        private static StandaloneTreeIdentity GetTreeIdentity(string root)
        {
            var directories = Directory.GetDirectories(root, "*", SearchOption.AllDirectories)
                .Select(path => GetRelativePath(root, path)).OrderBy(path => path, StringComparer.Ordinal).ToArray();
            var files = Directory.GetFiles(root, "*", SearchOption.AllDirectories)
                .Select(path => new FileInfo(path)).OrderBy(file => GetRelativePath(root, file.FullName), StringComparer.Ordinal).ToArray();
            var canonical = new List<string>();
            foreach (var directory in directories)
            {
                canonical.Add("D|" + Encoding.UTF8.GetByteCount(directory) + "|" + directory);
            }
            long totalBytes = 0;
            foreach (var file in files)
            {
                var relative = GetRelativePath(root, file.FullName);
                totalBytes += file.Length;
                canonical.Add("F|" + Encoding.UTF8.GetByteCount(relative) + "|" + relative + "|" + file.Length + "|" + GetFileSha256(file.FullName));
            }
            return new StandaloneTreeIdentity
            {
                sha256 = GetTextSha256(string.Join("\n", canonical)),
                fileCount = files.Length,
                directoryCount = directories.Length,
                totalBytes = totalBytes
            };
        }

        /// <summary>Converts one descendant path to a forward-slash relative build-tree path.</summary>
        private static string GetRelativePath(string root, string path)
        {
            return Path.GetFullPath(path).Substring(root.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace('\\', '/');
        }

        /// <summary>Computes a lowercase SHA-256 digest for one build file.</summary>
        private static string GetFileSha256(string path)
        {
            using (var stream = File.OpenRead(GetExtendedPath(path)))
            using (var algorithm = SHA256.Create())
            {
                return string.Concat(algorithm.ComputeHash(stream).Select(value => value.ToString("x2")));
            }
        }

        /// <summary>Converts one absolute Windows path to an extended-length System.IO path.</summary>
        private static string GetExtendedPath(string path)
        {
            var fullPath = Path.GetFullPath(path);
            if (fullPath.StartsWith(@"\\?\", StringComparison.Ordinal))
            {
                return fullPath;
            }
            if (fullPath.StartsWith(@"\\", StringComparison.Ordinal))
            {
                return @"\\?\UNC\" + fullPath.Substring(2);
            }
            return @"\\?\" + fullPath;
        }

        /// <summary>Computes a lowercase SHA-256 digest for canonical UTF-8 text.</summary>
        private static string GetTextSha256(string text)
        {
            using (var algorithm = SHA256.Create())
            {
                return string.Concat(algorithm.ComputeHash(Encoding.UTF8.GetBytes(text)).Select(value => value.ToString("x2")));
            }
        }

        /// <summary>Writes one UTF-8 build artifact through a same-directory atomic replacement.</summary>
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

        /// <summary>Accepts an inherited artifact path only when it is strictly below the session root.</summary>
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
