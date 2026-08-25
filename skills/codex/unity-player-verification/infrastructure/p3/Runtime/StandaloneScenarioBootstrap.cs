using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace UnityPlayerVerification
{
    /// <summary>Starts the verifier scenario before project gameplay scripts enter their first frame.</summary>
    public static class StandaloneScenarioBootstrap
    {
        /// <summary>Creates one persistent runner before the first configured Scene is loaded.</summary>
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        private static void Initialize()
        {
            Application.runInBackground = true;
            var gameObject = new GameObject("__UnityPlayerVerificationStandalone");
            gameObject.hideFlags = HideFlags.HideAndDontSave;
            UnityEngine.Object.DontDestroyOnLoad(gameObject);
            gameObject.AddComponent<StandaloneScenarioRunner>();
        }
    }

    /// <summary>Executes one source-only scenario and terminates the instrumented Standalone deterministically.</summary>
    internal sealed class StandaloneScenarioRunner : MonoBehaviour
    {
        /// <summary>Runs the manifest-bound scenario across frames and emits an atomic external receipt.</summary>
        private IEnumerator Start()
        {
            yield return null;
            var sessionRoot = ReadRequiredEnvironmentPath("UPVR_SESSION_ROOT");
            var contractPath = ReadRequiredChildPath("UPVR_SCENARIO_CONTRACT_PATH", sessionRoot);
            var receiptPath = ReadRequiredChildPath("UPVR_SCENARIO_RECEIPT_PATH", sessionRoot);
            var screenshotRoot = ReadRequiredChildPath("UPVR_SCREENSHOT_ROOT", sessionRoot);
            var contract = JsonUtility.FromJson<PlayerScenarioContract>(File.ReadAllText(contractPath));
            ValidateContract(contract, ReadRequiredEnvironmentValue("UPVR_SESSION_TOKEN"));
            var context = new PlayerVerificationContext(contract, screenshotRoot);
            var started = Time.realtimeSinceStartup;
            Exception executionException = null;
            IEnumerator execution = null;
            Debug.Log("UPVR_STANDALONE_SCENARIO_STARTED " + contract.scenarioId);
            try
            {
                var scenario = CreateScenario();
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

            var executionStack = new Stack<IEnumerator>();
            if (execution != null)
            {
                executionStack.Push(execution);
            }

            while (executionException == null && executionStack.Count > 0)
            {
                object current = null;
                var shouldYield = false;
                try
                {
                    if (Time.realtimeSinceStartup - started > contract.timeoutSeconds)
                    {
                        throw new TimeoutException("Scenario exceeded its manifest timeout of " + contract.timeoutSeconds + " seconds.");
                    }

                    var activeExecution = executionStack.Peek();
                    if (!activeExecution.MoveNext())
                    {
                        executionStack.Pop();
                        DisposeExecution(activeExecution);
                        continue;
                    }

                    current = activeExecution.Current;
                    var nestedExecution = current as IEnumerator;
                    if (nestedExecution != null)
                    {
                        if (ContainsExecutionReference(executionStack, nestedExecution))
                        {
                            throw new InvalidOperationException("Scenario yielded an IEnumerator that is already active.");
                        }
                        executionStack.Push(nestedExecution);
                        continue;
                    }
                    shouldYield = true;
                }
                catch (Exception exception)
                {
                    executionException = exception;
                    break;
                }

                if (shouldYield)
                {
                    yield return current;
                }
            }

            if (executionException != null)
            {
                DisposeRemainingExecutions(executionStack);
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
            try
            {
                WriteAtomicText(receiptPath, JsonUtility.ToJson(receipt, true));
                Debug.Log("UPVR_STANDALONE_SCENARIO_FINISHED " + receipt.result);
            }
            catch (Exception exception)
            {
                Debug.LogError("UPVR_STANDALONE_RECEIPT_ERROR " + exception);
                Application.Quit(2);
                yield break;
            }
            Application.Quit(passed ? 0 : 1);
            yield break;
        }

        /// <summary>Checks active coroutine frames by reference so a self-yield cannot spin forever in one Player frame.</summary>
        private static bool ContainsExecutionReference(IEnumerable<IEnumerator> executions, IEnumerator candidate)
        {
            return executions.Any(execution => ReferenceEquals(execution, candidate));
        }

        /// <summary>Disposes a completed coroutine frame so compiler-generated finally blocks run deterministically.</summary>
        private static void DisposeExecution(IEnumerator execution)
        {
            var disposable = execution as IDisposable;
            if (disposable != null)
            {
                disposable.Dispose();
            }
        }

        /// <summary>Disposes every active coroutine frame after a scenario failure without replacing its original exception.</summary>
        private static void DisposeRemainingExecutions(Stack<IEnumerator> executions)
        {
            while (executions.Count > 0)
            {
                var execution = executions.Pop();
                try
                {
                    DisposeExecution(execution);
                }
                catch (Exception exception)
                {
                    Debug.LogWarning("UPVR_STANDALONE_SCENARIO_DISPOSE_WARNING " + exception);
                }
            }
        }

        /// <summary>Finds exactly one concrete scenario implementation in the built Player.</summary>
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

        /// <summary>Returns loadable types while retaining any types exposed by a partial reflection failure.</summary>
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

        /// <summary>Checks the runtime scenario contract before project-owned code is instantiated.</summary>
        private static void ValidateContract(PlayerScenarioContract contract, string expectedSessionToken)
        {
            if (contract == null || contract.schemaVersion != "1.0.0" || contract.sessionToken != expectedSessionToken ||
                string.IsNullOrWhiteSpace(contract.scenarioId) || contract.timeoutSeconds <= 0 ||
                contract.expectedScenes == null || contract.expectedAssertionIds == null || contract.expectedCaptureIds == null)
            {
                throw new InvalidOperationException("Standalone scenario runtime contract is invalid.");
            }
        }

        /// <summary>Writes one UTF-8 runtime receipt through a same-directory atomic replacement.</summary>
        private static void WriteAtomicText(string path, string content)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var temporaryPath = path + ".tmp";
            try
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
                File.WriteAllText(temporaryPath, content);
                if (File.Exists(path))
                {
                    File.Replace(temporaryPath, path, null);
                }
                else
                {
                    File.Move(temporaryPath, path);
                }
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
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

        /// <summary>Accepts an inherited artifact path only when it is strictly below the session root.</summary>
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
