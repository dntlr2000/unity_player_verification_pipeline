using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.TestTools;

namespace UnityPlayerVerification
{
    /// <summary>Discovers and runs exactly one manifest-bound scenario inside the Windows Test Player.</summary>
    public sealed class PlayerScenarioTest
    {
        /// <summary>Executes the reviewed scenario and atomically writes its independent receipt.</summary>
        [UnityTest]
        public IEnumerator ExecuteScenario()
        {
            var sessionRoot = ReadRequiredEnvironmentPath("UPVR_SESSION_ROOT");
            var contractPath = ReadRequiredChildPath("UPVR_SCENARIO_CONTRACT_PATH", sessionRoot);
            var receiptPath = ReadRequiredChildPath("UPVR_SCENARIO_RECEIPT_PATH", sessionRoot);
            var screenshotRoot = ReadRequiredChildPath("UPVR_SCREENSHOT_ROOT", sessionRoot);
            var contract = JsonUtility.FromJson<PlayerScenarioContract>(File.ReadAllText(contractPath));
            ValidateContract(contract, ReadRequiredEnvironmentValue("UPVR_SESSION_TOKEN"));
            var context = new PlayerVerificationContext(contract, screenshotRoot);
            var started = Time.realtimeSinceStartup;
            Exception executionException = null;
            var scenario = CreateScenario();
            IEnumerator execution = null;
            try
            {
                execution = scenario.Execute(context);
                if (execution == null)
                {
                    throw new InvalidOperationException("Scenario returned a null IEnumerator.");
                }
            }
            catch (Exception exception)
            {
                executionException = exception;
            }

            while (executionException == null)
            {
                object current = null;
                bool moved;
                try
                {
                    if (Time.realtimeSinceStartup - started > contract.timeoutSeconds)
                    {
                        throw new TimeoutException("Scenario exceeded its manifest timeout of " + contract.timeoutSeconds + " seconds.");
                    }
                    moved = execution.MoveNext();
                    if (moved)
                    {
                        current = execution.Current;
                    }
                }
                catch (Exception exception)
                {
                    executionException = exception;
                    break;
                }
                if (!moved)
                {
                    break;
                }
                yield return current;
            }

            var contractErrors = context.GetContractErrors();
            var passed = executionException == null && contractErrors.Length == 0;
            var activeScene = SceneManager.GetActiveScene();
            var receipt = new PlayerScenarioReceipt
            {
                sessionToken = contract.sessionToken,
                scenarioId = contract.scenarioId,
                runStarted = true,
                runFinished = true,
                result = passed ? "PASSED" : "FAILED",
                activeScene = string.IsNullOrEmpty(activeScene.path) ? activeScene.name : activeScene.path,
                elapsedSeconds = Time.realtimeSinceStartup - started,
                exception = executionException == null ? null : executionException.ToString(),
                assertions = context.GetAssertions(),
                captures = context.GetCaptures()
            };
            WriteAtomicText(receiptPath, JsonUtility.ToJson(receipt, true));
            if (!passed)
            {
                var details = new List<string>(contractErrors);
                if (executionException != null)
                {
                    details.Add(executionException.Message);
                }
                Assert.Fail(string.Join(" ", details));
            }
        }

        /// <summary>Finds exactly one concrete scenario implementation across loaded Player assemblies.</summary>
        private static IPlayerVerificationScenario CreateScenario()
        {
            var scenarioTypes = AppDomain.CurrentDomain.GetAssemblies()
                .SelectMany(GetLoadableTypes)
                .Where(type => typeof(IPlayerVerificationScenario).IsAssignableFrom(type) && !type.IsAbstract && !type.IsInterface)
                .OrderBy(type => type.FullName, StringComparer.Ordinal)
                .ToArray();
            if (scenarioTypes.Length != 1)
            {
                throw new InvalidOperationException("Expected exactly one IPlayerVerificationScenario implementation, found " + scenarioTypes.Length + ".");
            }
            return (IPlayerVerificationScenario)Activator.CreateInstance(scenarioTypes[0]);
        }

        /// <summary>Returns loadable types while treating partial reflection failures as a rejected assembly.</summary>
        private static IEnumerable<Type> GetLoadableTypes(Assembly assembly)
        {
            try
            {
                return assembly.GetTypes();
            }
            catch (ReflectionTypeLoadException exception)
            {
                return exception.Types.Where(type => type != null);
            }
        }

        /// <summary>Checks the runtime contract before any scenario code is instantiated.</summary>
        private static void ValidateContract(PlayerScenarioContract contract, string expectedSessionToken)
        {
            if (contract == null || contract.schemaVersion != "1.0.0" || contract.sessionToken != expectedSessionToken ||
                string.IsNullOrWhiteSpace(contract.scenarioId) || contract.timeoutSeconds <= 0 ||
                contract.expectedScenes == null || contract.expectedAssertionIds == null || contract.expectedCaptureIds == null)
            {
                throw new InvalidOperationException("Player scenario runtime contract is invalid.");
            }
        }

        /// <summary>Writes one UTF-8 scenario receipt through a same-directory atomic replacement.</summary>
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
