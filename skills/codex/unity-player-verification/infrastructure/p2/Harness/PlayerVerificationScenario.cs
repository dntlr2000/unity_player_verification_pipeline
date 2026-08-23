using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Runtime.CompilerServices;
using UnityEngine;
using UnityEngine.SceneManagement;

[assembly: InternalsVisibleTo("UnityPlayerVerification.ScenarioTests")]
[assembly: InternalsVisibleTo("UnityPlayerVerification.Standalone")]

namespace UnityPlayerVerification
{
    [Serializable]
    internal sealed class PlayerScenarioContract
    {
        public string schemaVersion;
        public string sessionToken;
        public string scenarioId;
        public string displayName;
        public int timeoutSeconds;
        public string[] expectedScenes;
        public string[] expectedAssertionIds;
        public string[] expectedCaptureIds;
        public bool graphicsRequired;
    }

    [Serializable]
    public sealed class PlayerScenarioAssertion
    {
        public string id;
        public bool passed;
        public string detail;
    }

    [Serializable]
    public sealed class PlayerScenarioCapture
    {
        public string id;
        public string path;
        public long byteLength;
        public string sha256;
    }

    [Serializable]
    internal sealed class PlayerScenarioReceipt
    {
        public string schemaVersion = "1.0.0";
        public string sessionToken;
        public string scenarioId;
        public bool runStarted;
        public bool runFinished;
        public string result;
        public string activeScene;
        public double elapsedSeconds;
        public string exception;
        public PlayerScenarioAssertion[] assertions;
        public PlayerScenarioCapture[] captures;
    }

    /// <summary>Defines one reviewed source-only behavior scenario executed inside a Test Player.</summary>
    public interface IPlayerVerificationScenario
    {
        /// <summary>Runs the scenario across frames using only the verifier context and project-owned public seams.</summary>
        IEnumerator Execute(PlayerVerificationContext context);
    }

    /// <summary>Provides bounded scene, frame, assertion, and PNG evidence helpers to Player scenarios.</summary>
    public sealed class PlayerVerificationContext
    {
        private readonly PlayerScenarioContract contract;
        private readonly string screenshotRoot;
        private readonly List<PlayerScenarioAssertion> assertions = new List<PlayerScenarioAssertion>();
        private readonly List<PlayerScenarioCapture> captures = new List<PlayerScenarioCapture>();
        private readonly HashSet<string> assertionIds = new HashSet<string>(StringComparer.Ordinal);
        private readonly HashSet<string> captureIds = new HashSet<string>(StringComparer.Ordinal);

        /// <summary>Creates a context bound to one validated manifest and verifier-owned screenshot directory.</summary>
        internal PlayerVerificationContext(PlayerScenarioContract scenarioContract, string captureRoot)
        {
            contract = scenarioContract ?? throw new ArgumentNullException(nameof(scenarioContract));
            screenshotRoot = Path.GetFullPath(captureRoot ?? throw new ArgumentNullException(nameof(captureRoot)));
            Directory.CreateDirectory(screenshotRoot);
        }

        /// <summary>Returns the manifest scenario identifier visible to reviewed scenario source.</summary>
        public string ScenarioId
        {
            get { return contract.scenarioId; }
        }

        /// <summary>Loads one scene asynchronously and waits until Unity completes activation.</summary>
        public IEnumerator LoadScene(string sceneNameOrPath)
        {
            if (string.IsNullOrWhiteSpace(sceneNameOrPath))
            {
                throw new ArgumentException("Scene name or path is required.", nameof(sceneNameOrPath));
            }
            var operation = SceneManager.LoadSceneAsync(sceneNameOrPath, LoadSceneMode.Single);
            if (operation == null)
            {
                throw new InvalidOperationException("Unity did not create a scene load operation for " + sceneNameOrPath + ".");
            }
            while (!operation.isDone)
            {
                yield return null;
            }
        }

        /// <summary>Waits an exact non-negative number of rendered Player frames.</summary>
        public IEnumerator WaitFrames(int frameCount)
        {
            if (frameCount < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(frameCount));
            }
            for (var index = 0; index < frameCount; index++)
            {
                yield return null;
            }
        }

        /// <summary>Waits for one condition and throws when its bounded real-time deadline expires.</summary>
        public IEnumerator WaitUntil(Func<bool> condition, float timeoutSeconds)
        {
            if (condition == null)
            {
                throw new ArgumentNullException(nameof(condition));
            }
            if (timeoutSeconds <= 0f)
            {
                throw new ArgumentOutOfRangeException(nameof(timeoutSeconds));
            }
            var started = Time.realtimeSinceStartup;
            while (!condition())
            {
                if (Time.realtimeSinceStartup - started > timeoutSeconds)
                {
                    throw new TimeoutException("Scenario condition did not become true within " + timeoutSeconds + " seconds.");
                }
                yield return null;
            }
        }

        /// <summary>Records one uniquely named behavioral assertion without using reflection or private state.</summary>
        public void RecordAssertion(string id, bool passed, string detail)
        {
            ValidateIdentifier(id, nameof(id));
            if (!assertionIds.Add(id))
            {
                throw new InvalidOperationException("Scenario recorded duplicate assertion ID " + id + ".");
            }
            assertions.Add(new PlayerScenarioAssertion { id = id, passed = passed, detail = detail ?? string.Empty });
        }

        /// <summary>Captures the current rendered frame as a verifier-owned PNG and records its identity.</summary>
        public IEnumerator CapturePng(string id)
        {
            ValidateIdentifier(id, nameof(id));
            if (!captureIds.Add(id))
            {
                throw new InvalidOperationException("Scenario recorded duplicate capture ID " + id + ".");
            }
            yield return new WaitForEndOfFrame();
            var width = Math.Max(1, Screen.width);
            var height = Math.Max(1, Screen.height);
            var texture = new Texture2D(width, height, TextureFormat.RGB24, false);
            try
            {
                texture.ReadPixels(new Rect(0, 0, width, height), 0, 0, false);
                texture.Apply(false, false);
                var path = Path.Combine(screenshotRoot, id + ".png");
                var bytes = EncodeRgb24Png(texture);
                File.WriteAllBytes(path, bytes);
                captures.Add(new PlayerScenarioCapture
                {
                    id = id,
                    path = path,
                    byteLength = bytes.LongLength,
                    sha256 = ComputeSha256(bytes)
                });
            }
            finally
            {
                UnityEngine.Object.Destroy(texture);
            }
        }

        /// <summary>Returns a stable snapshot of every assertion recorded by the scenario.</summary>
        internal PlayerScenarioAssertion[] GetAssertions()
        {
            return assertions.OrderBy(item => item.id, StringComparer.Ordinal).ToArray();
        }

        /// <summary>Returns a stable snapshot of every capture recorded by the scenario.</summary>
        internal PlayerScenarioCapture[] GetCaptures()
        {
            return captures.OrderBy(item => item.id, StringComparer.Ordinal).ToArray();
        }

        /// <summary>Validates the manifest-owned scene, assertion, and capture sets after execution.</summary>
        internal string[] GetContractErrors()
        {
            var errors = new List<string>();
            var activeScene = SceneManager.GetActiveScene();
            var sceneAccepted = contract.expectedScenes.Any(expected =>
                string.Equals(expected, activeScene.name, StringComparison.Ordinal) ||
                string.Equals(NormalizeScenePath(expected), NormalizeScenePath(activeScene.path), StringComparison.Ordinal));
            if (!sceneAccepted)
            {
                errors.Add("Active scene does not match the manifest: " + activeScene.path + ".");
            }
            CompareExactIds("assertion", contract.expectedAssertionIds, assertionIds, errors);
            CompareExactIds("capture", contract.expectedCaptureIds, captureIds, errors);
            foreach (var assertion in assertions.Where(item => !item.passed))
            {
                errors.Add("Assertion failed: " + assertion.id + ".");
            }
            return errors.ToArray();
        }

        /// <summary>Compares one manifest ID set with the IDs actually emitted by the scenario.</summary>
        private static void CompareExactIds(string kind, IEnumerable<string> expected, HashSet<string> actual, ICollection<string> errors)
        {
            var expectedSet = new HashSet<string>(expected ?? Array.Empty<string>(), StringComparer.Ordinal);
            foreach (var missing in expectedSet.Where(id => !actual.Contains(id)).OrderBy(id => id, StringComparer.Ordinal))
            {
                errors.Add("Missing expected " + kind + " ID " + missing + ".");
            }
            foreach (var unexpected in actual.Where(id => !expectedSet.Contains(id)).OrderBy(id => id, StringComparer.Ordinal))
            {
                errors.Add("Unexpected " + kind + " ID " + unexpected + ".");
            }
        }

        /// <summary>Rejects IDs that cannot be represented safely as manifest keys or filenames.</summary>
        private static void ValidateIdentifier(string id, string parameterName)
        {
            if (string.IsNullOrWhiteSpace(id) || id.Length > 128 || !System.Text.RegularExpressions.Regex.IsMatch(id, "^[A-Za-z0-9][A-Za-z0-9._-]*$"))
            {
                throw new ArgumentException("Scenario evidence ID is invalid.", parameterName);
            }
        }

        /// <summary>Normalizes Unity scene paths for ordinal manifest comparison.</summary>
        private static string NormalizeScenePath(string path)
        {
            return (path ?? string.Empty).Replace('\\', '/');
        }

        /// <summary>Computes a lowercase SHA-256 digest for an in-memory PNG.</summary>
        private static string ComputeSha256(byte[] bytes)
        {
            using (var algorithm = SHA256.Create())
            {
                return string.Concat(algorithm.ComputeHash(bytes).Select(value => value.ToString("x2")));
            }
        }

        /// <summary>Encodes a readable RGB24 PNG without depending on optional Unity image-conversion modules.</summary>
        private static byte[] EncodeRgb24Png(Texture2D texture)
        {
            var width = texture.width;
            var height = texture.height;
            var pixels = texture.GetPixels32();
            var scanlines = new byte[height * (1 + width * 3)];
            var destination = 0;
            for (var row = height - 1; row >= 0; row--)
            {
                scanlines[destination++] = 0;
                var rowStart = row * width;
                for (var column = 0; column < width; column++)
                {
                    var color = pixels[rowStart + column];
                    scanlines[destination++] = color.r;
                    scanlines[destination++] = color.g;
                    scanlines[destination++] = color.b;
                }
            }

            using (var output = new MemoryStream())
            {
                output.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, 0, 8);
                var header = new byte[13];
                WriteUInt32BigEndian(header, 0, (uint)width);
                WriteUInt32BigEndian(header, 4, (uint)height);
                header[8] = 8;
                header[9] = 2;
                WritePngChunk(output, "IHDR", header);
                WritePngChunk(output, "IDAT", EncodeStoredZlib(scanlines));
                WritePngChunk(output, "IEND", Array.Empty<byte>());
                return output.ToArray();
            }
        }

        /// <summary>Creates a standards-compliant zlib stream containing bounded uncompressed DEFLATE blocks.</summary>
        private static byte[] EncodeStoredZlib(byte[] data)
        {
            using (var output = new MemoryStream())
            {
                output.WriteByte(0x78);
                output.WriteByte(0x01);
                var offset = 0;
                while (offset < data.Length)
                {
                    var length = Math.Min(65535, data.Length - offset);
                    var final = offset + length == data.Length;
                    output.WriteByte(final ? (byte)0x01 : (byte)0x00);
                    output.WriteByte((byte)(length & 0xff));
                    output.WriteByte((byte)((length >> 8) & 0xff));
                    var complement = (~length) & 0xffff;
                    output.WriteByte((byte)(complement & 0xff));
                    output.WriteByte((byte)((complement >> 8) & 0xff));
                    output.Write(data, offset, length);
                    offset += length;
                }
                var adler = ComputeAdler32(data);
                var trailer = new byte[4];
                WriteUInt32BigEndian(trailer, 0, adler);
                output.Write(trailer, 0, trailer.Length);
                return output.ToArray();
            }
        }

        /// <summary>Writes one PNG chunk with a big-endian length and CRC-32 guard.</summary>
        private static void WritePngChunk(Stream output, string type, byte[] data)
        {
            var typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
            var lengthBytes = new byte[4];
            WriteUInt32BigEndian(lengthBytes, 0, (uint)data.Length);
            output.Write(lengthBytes, 0, lengthBytes.Length);
            output.Write(typeBytes, 0, typeBytes.Length);
            output.Write(data, 0, data.Length);
            var crcInput = new byte[typeBytes.Length + data.Length];
            Buffer.BlockCopy(typeBytes, 0, crcInput, 0, typeBytes.Length);
            Buffer.BlockCopy(data, 0, crcInput, typeBytes.Length, data.Length);
            var crcBytes = new byte[4];
            WriteUInt32BigEndian(crcBytes, 0, ComputeCrc32(crcInput));
            output.Write(crcBytes, 0, crcBytes.Length);
        }

        /// <summary>Writes one unsigned 32-bit value using PNG network byte order.</summary>
        private static void WriteUInt32BigEndian(byte[] destination, int offset, uint value)
        {
            destination[offset] = (byte)(value >> 24);
            destination[offset + 1] = (byte)(value >> 16);
            destination[offset + 2] = (byte)(value >> 8);
            destination[offset + 3] = (byte)value;
        }

        /// <summary>Computes the IEEE CRC-32 value required by every PNG chunk.</summary>
        private static uint ComputeCrc32(byte[] bytes)
        {
            uint crc = 0xffffffff;
            foreach (var value in bytes)
            {
                crc ^= value;
                for (var bit = 0; bit < 8; bit++)
                {
                    crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
                }
            }
            return crc ^ 0xffffffff;
        }

        /// <summary>Computes the Adler-32 checksum appended to the PNG zlib payload.</summary>
        private static uint ComputeAdler32(byte[] bytes)
        {
            const uint modulus = 65521;
            uint first = 1;
            uint second = 0;
            foreach (var value in bytes)
            {
                first = (first + value) % modulus;
                second = (second + first) % modulus;
            }
            return (second << 16) | first;
        }
    }

}
