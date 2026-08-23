Set-StrictMode -Version Latest

if (-not ('UnityBaselineProcess.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace UnityBaselineProcess
{
    [StructLayout(LayoutKind.Sequential)]
    public struct IoCounters
    {
        public UInt64 ReadOperationCount;
        public UInt64 WriteOperationCount;
        public UInt64 OtherOperationCount;
        public UInt64 ReadTransferCount;
        public UInt64 WriteTransferCount;
        public UInt64 OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BasicLimitInformation
    {
        public Int64 PerProcessUserTimeLimit;
        public Int64 PerJobUserTimeLimit;
        public UInt32 LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public UInt32 ActiveProcessLimit;
        public UIntPtr Affinity;
        public UInt32 PriorityClass;
        public UInt32 SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BasicAccountingInformation
    {
        public Int64 TotalUserTime;
        public Int64 TotalKernelTime;
        public Int64 ThisPeriodTotalUserTime;
        public Int64 ThisPeriodTotalKernelTime;
        public UInt32 TotalPageFaultCount;
        public UInt32 TotalProcesses;
        public UInt32 ActiveProcesses;
        public UInt32 TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SecurityAttributes
    {
        public Int32 Length;
        public IntPtr SecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)]
        public Boolean InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct StartupInfo
    {
        public Int32 Size;
        public String Reserved;
        public String Desktop;
        public String Title;
        public UInt32 X;
        public UInt32 Y;
        public UInt32 XSize;
        public UInt32 YSize;
        public UInt32 XCountChars;
        public UInt32 YCountChars;
        public UInt32 FillAttribute;
        public UInt32 Flags;
        public UInt16 ShowWindow;
        public UInt16 Reserved2Size;
        public IntPtr Reserved2;
        public IntPtr StandardInput;
        public IntPtr StandardOutput;
        public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public UInt32 ProcessId;
        public UInt32 ThreadId;
    }

    public static class NativeMethods
    {
        public const UInt32 JobObjectLimitKillOnJobClose = 0x00002000;
        public const Int32 JobObjectBasicAccountingInformation = 1;
        public const Int32 JobObjectExtendedLimitInformation = 9;
        public const UInt32 GenericRead = 0x80000000;
        public const UInt32 GenericWrite = 0x40000000;
        public const UInt32 FileShareRead = 0x00000001;
        public const UInt32 FileShareWrite = 0x00000002;
        public const UInt32 CreateAlways = 2;
        public const UInt32 OpenExisting = 3;
        public const UInt32 FileAttributeNormal = 0x00000080;
        public const UInt32 CreateSuspended = 0x00000004;
        public const UInt32 CreateNoWindow = 0x08000000;
        public const UInt32 StartfUseStdHandles = 0x00000100;
        public const UInt32 WaitObject0 = 0x00000000;
        public const UInt32 WaitTimeout = 0x00000102;
        public const UInt32 Infinite = 0xFFFFFFFF;

        // Opens one inheritable file or NUL handle for direct child-process stream redirection.
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateFile(
            String fileName,
            UInt32 desiredAccess,
            UInt32 shareMode,
            ref SecurityAttributes securityAttributes,
            UInt32 creationDisposition,
            UInt32 flagsAndAttributes,
            IntPtr templateFile);

        // Creates the exact executable suspended so no child can escape before Job assignment.
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern Boolean CreateProcess(
            String applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] Boolean inheritHandles,
            UInt32 creationFlags,
            IntPtr environment,
            String currentDirectory,
            ref StartupInfo startupInfo,
            out ProcessInformation processInformation);

        // Resumes the root process only after successful Job Object assignment.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UInt32 ResumeThread(IntPtr thread);

        // Waits a bounded interval for the root process handle to signal exit.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UInt32 WaitForSingleObject(IntPtr handle, UInt32 milliseconds);

        // Reads the concrete root-process exit code after its handle signals.
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern Boolean GetExitCodeProcess(IntPtr process, out UInt32 exitCode);

        // Terminates a suspended root if it cannot be assigned safely to the Job Object.
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern Boolean TerminateProcess(IntPtr process, UInt32 exitCode);

        // Creates an unnamed Windows Job Object owned by the verifier process.
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        // Applies the kill-on-close limit before a Unity process is assigned.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(
            IntPtr job,
            Int32 informationClass,
            ref ExtendedLimitInformation information,
            UInt32 informationLength);

        // Assigns the Unity process so subsequently created descendants inherit the Job Object.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        // Returns accounting information used to prove no assigned process remains active.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool QueryInformationJobObject(
            IntPtr job,
            Int32 informationClass,
            out BasicAccountingInformation information,
            UInt32 informationLength,
            IntPtr returnLength);

        // Terminates every process assigned to the Job Object after timeout or unsafe residue.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr job, UInt32 exitCode);

        // Releases the Job Object handle; kill-on-close is the final fail-safe.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

# Quotes one Windows command-line argument without invoking a command shell.
function ConvertTo-UnityProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($Argument.IndexOf([char]0) -ge 0) {
        throw 'Process arguments cannot contain a null character.'
    }
    if ($Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# Returns the active process count currently assigned to one Job Object.
function Get-UnityJobActiveProcessCount {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$JobHandle
    )

    $accounting = New-Object UnityBaselineProcess.BasicAccountingInformation
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][UnityBaselineProcess.BasicAccountingInformation])
    $success = [UnityBaselineProcess.NativeMethods]::QueryInformationJobObject(
        $JobHandle,
        [UnityBaselineProcess.NativeMethods]::JobObjectBasicAccountingInformation,
        [ref]$accounting,
        [uint32]$size,
        [IntPtr]::Zero
    )
    if (-not $success) {
        $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw (New-Object System.ComponentModel.Win32Exception($errorCode))
    }
    return [int]$accounting.ActiveProcesses
}

# Waits a bounded interval for Job Object accounting to prove the process tree is empty.
function Wait-UnityJobProcessTreeExit {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$JobHandle,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutMilliseconds
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $activeProcessCount = $null
    try {
        do {
            $activeProcessCount = Get-UnityJobActiveProcessCount -JobHandle $JobHandle
            if ($activeProcessCount -eq 0) {
                return [pscustomobject][ordered]@{
                    verified = $true
                    activeProcessCount = 0
                    elapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
                    error = $null
                }
            }
            Start-Sleep -Milliseconds 50
        } while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds)

        return [pscustomobject][ordered]@{
            verified = $false
            activeProcessCount = $activeProcessCount
            elapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
            error = 'Assigned processes remained active past the bounded wait.'
        }
    } catch {
        return [pscustomobject][ordered]@{
            verified = $false
            activeProcessCount = $activeProcessCount
            elapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
            error = $_.Exception.Message
        }
    } finally {
        $stopwatch.Stop()
    }
}

# Writes redirected process output to an external artifact path.
function Write-UnityProcessOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    [void][System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

# Runs one executable in a kill-on-close Job Object with optional build/run phase deadlines and tree-exit evidence.
function Invoke-UnityProcessInJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StandardOutputPath,

        [Parameter(Mandatory = $true)]
        [string]$StandardErrorPath,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter()]
        [AllowNull()]
        [string]$BuildCompletionPath,

        [Parameter()]
        [int]$BuildTimeoutSeconds = 0,

        [Parameter()]
        [int]$RunTimeoutSeconds = 0,

        [Parameter()]
        [AllowNull()]
        [string]$FailureSignalPath,

        [Parameter()]
        [AllowNull()]
        [string]$FailureSignalPattern,

        [Parameter()]
        [int]$TreeExitGraceMilliseconds = 3000,

        [Parameter()]
        [int]$TerminationWaitMilliseconds = 5000
    )

    $result = [ordered]@{
        processStarted = $false
        rootProcessId = $null
        jobObjectCreated = $false
        killOnJobCloseConfigured = $false
        processAssignedToJob = $false
        timedOut = $false
        timeoutPhase = $null
        buildPhaseCompleted = $false
        buildElapsedMilliseconds = 0
        runElapsedMilliseconds = 0
        failureSignalObserved = $false
        exitCode = $null
        terminationRequested = $false
        terminationReason = $null
        terminationApiSucceeded = $null
        rootProcessExited = $false
        processTreeExitVerified = $false
        activeProcessCountAfterWait = $null
        treeExitWaitMilliseconds = 0
        standardOutputCaptured = $false
        standardErrorCaptured = $false
        controlError = $null
    }

    $jobHandle = [IntPtr]::Zero
    $standardInputHandle = [IntPtr]::Zero
    $standardOutputHandle = [IntPtr]::Zero
    $standardErrorHandle = [IntPtr]::Zero
    $processInformation = New-Object UnityBaselineProcess.ProcessInformation
    $invalidHandle = [IntPtr](-1)
    try {
        foreach ($outputPath in @($StandardOutputPath, $StandardErrorPath)) {
            $outputParent = Split-Path -Parent $outputPath
            if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
                [void][System.IO.Directory]::CreateDirectory($outputParent)
            }
        }

        $jobHandle = [UnityBaselineProcess.NativeMethods]::CreateJobObject([IntPtr]::Zero, $null)
        if ($jobHandle -eq [IntPtr]::Zero) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode))
        }
        $result.jobObjectCreated = $true

        $limits = New-Object UnityBaselineProcess.ExtendedLimitInformation
        $limits.BasicLimitInformation.LimitFlags = [UnityBaselineProcess.NativeMethods]::JobObjectLimitKillOnJobClose
        $limitSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][UnityBaselineProcess.ExtendedLimitInformation])
        if (-not [UnityBaselineProcess.NativeMethods]::SetInformationJobObject(
            $jobHandle,
            [UnityBaselineProcess.NativeMethods]::JobObjectExtendedLimitInformation,
            [ref]$limits,
            [uint32]$limitSize
        )) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode))
        }
        $result.killOnJobCloseConfigured = $true

        $securityAttributes = New-Object UnityBaselineProcess.SecurityAttributes
        $securityAttributes.Length = [System.Runtime.InteropServices.Marshal]::SizeOf([type][UnityBaselineProcess.SecurityAttributes])
        $securityAttributes.SecurityDescriptor = [IntPtr]::Zero
        $securityAttributes.InheritHandle = $true
        $streamShare = [UnityBaselineProcess.NativeMethods]::FileShareRead -bor [UnityBaselineProcess.NativeMethods]::FileShareWrite
        $standardInputHandle = [UnityBaselineProcess.NativeMethods]::CreateFile(
            'NUL',
            [UnityBaselineProcess.NativeMethods]::GenericRead,
            $streamShare,
            [ref]$securityAttributes,
            [UnityBaselineProcess.NativeMethods]::OpenExisting,
            [UnityBaselineProcess.NativeMethods]::FileAttributeNormal,
            [IntPtr]::Zero
        )
        $standardOutputHandle = [UnityBaselineProcess.NativeMethods]::CreateFile(
            $StandardOutputPath,
            [UnityBaselineProcess.NativeMethods]::GenericWrite,
            $streamShare,
            [ref]$securityAttributes,
            [UnityBaselineProcess.NativeMethods]::CreateAlways,
            [UnityBaselineProcess.NativeMethods]::FileAttributeNormal,
            [IntPtr]::Zero
        )
        $standardErrorHandle = [UnityBaselineProcess.NativeMethods]::CreateFile(
            $StandardErrorPath,
            [UnityBaselineProcess.NativeMethods]::GenericWrite,
            $streamShare,
            [ref]$securityAttributes,
            [UnityBaselineProcess.NativeMethods]::CreateAlways,
            [UnityBaselineProcess.NativeMethods]::FileAttributeNormal,
            [IntPtr]::Zero
        )
        if (
            $standardInputHandle -eq $invalidHandle -or
            $standardOutputHandle -eq $invalidHandle -or
            $standardErrorHandle -eq $invalidHandle
        ) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode))
        }

        $startupInfo = New-Object UnityBaselineProcess.StartupInfo
        $startupInfo.Size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][UnityBaselineProcess.StartupInfo])
        $startupInfo.Flags = [UnityBaselineProcess.NativeMethods]::StartfUseStdHandles
        $startupInfo.StandardInput = $standardInputHandle
        $startupInfo.StandardOutput = $standardOutputHandle
        $startupInfo.StandardError = $standardErrorHandle
        $commandParts = New-Object 'System.Collections.Generic.List[string]'
        $commandParts.Add((ConvertTo-UnityProcessArgument -Argument $ExecutablePath))
        foreach ($argument in $Arguments) {
            $commandParts.Add((ConvertTo-UnityProcessArgument -Argument $argument))
        }
        $commandLine = New-Object System.Text.StringBuilder
        [void]$commandLine.Append([string]::Join(' ', $commandParts.ToArray()))
        $creationFlags = [UnityBaselineProcess.NativeMethods]::CreateSuspended -bor [UnityBaselineProcess.NativeMethods]::CreateNoWindow
        $created = [UnityBaselineProcess.NativeMethods]::CreateProcess(
            $ExecutablePath,
            $commandLine,
            [IntPtr]::Zero,
            [IntPtr]::Zero,
            $true,
            $creationFlags,
            [IntPtr]::Zero,
            $WorkingDirectory,
            [ref]$startupInfo,
            [ref]$processInformation
        )
        if (-not $created) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode))
        }
        $result.processStarted = $true
        $result.rootProcessId = [int]$processInformation.ProcessId

        if (-not [UnityBaselineProcess.NativeMethods]::AssignProcessToJobObject($jobHandle, $processInformation.Process)) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode))
        }
        $result.processAssignedToJob = $true

        $resumeResult = [UnityBaselineProcess.NativeMethods]::ResumeThread($processInformation.Thread)
        if ($resumeResult -eq [uint32]::MaxValue) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode))
        }
        [void][UnityBaselineProcess.NativeMethods]::CloseHandle($processInformation.Thread)
        $processInformation.Thread = [IntPtr]::Zero

        $phaseAware = (
            -not [string]::IsNullOrWhiteSpace($BuildCompletionPath) -and
            $BuildTimeoutSeconds -gt 0 -and
            $RunTimeoutSeconds -gt 0
        )
        $waitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $runPhaseStartedMilliseconds = [long]0
        $rootWaitResult = [uint32][UnityBaselineProcess.NativeMethods]::WaitTimeout
        while ($true) {
            $rootWaitResult = [UnityBaselineProcess.NativeMethods]::WaitForSingleObject($processInformation.Process, [uint32]100)
            if ($rootWaitResult -eq [UnityBaselineProcess.NativeMethods]::WaitObject0) {
                break
            }
            if ($rootWaitResult -ne [UnityBaselineProcess.NativeMethods]::WaitTimeout) {
                break
            }

            if ($phaseAware) {
                if (-not $result.buildPhaseCompleted -and (Test-Path -LiteralPath $BuildCompletionPath -PathType Leaf)) {
                    $result.buildPhaseCompleted = $true
                    $result.buildElapsedMilliseconds = [long]$waitStopwatch.ElapsedMilliseconds
                    $runPhaseStartedMilliseconds = [long]$waitStopwatch.ElapsedMilliseconds
                }
                if (-not $result.buildPhaseCompleted -and $waitStopwatch.Elapsed.TotalSeconds -ge $BuildTimeoutSeconds) {
                    $result.timedOut = $true
                    $result.timeoutPhase = 'BUILD'
                    $result.terminationRequested = $true
                    $result.terminationReason = 'BUILD_TIMEOUT'
                    break
                }
                if ($result.buildPhaseCompleted) {
                    $result.runElapsedMilliseconds = [long]$waitStopwatch.ElapsedMilliseconds - $runPhaseStartedMilliseconds
                    if ($result.runElapsedMilliseconds -ge ([long]$RunTimeoutSeconds * 1000)) {
                        $result.timedOut = $true
                        $result.timeoutPhase = 'RUN'
                        $result.terminationRequested = $true
                        $result.terminationReason = 'RUN_TIMEOUT'
                        break
                    }
                }
            } elseif ($waitStopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $result.timedOut = $true
                $result.timeoutPhase = 'TOTAL'
                $result.terminationRequested = $true
                $result.terminationReason = 'TIMEOUT'
                break
            }
            if (
                -not [string]::IsNullOrWhiteSpace($FailureSignalPath) -and
                -not [string]::IsNullOrWhiteSpace($FailureSignalPattern) -and
                (Test-Path -LiteralPath $FailureSignalPath -PathType Leaf)
            ) {
                try {
                    $failureSignalText = [System.IO.File]::ReadAllText($FailureSignalPath, [System.Text.Encoding]::UTF8)
                    if ([regex]::IsMatch($failureSignalText, $FailureSignalPattern)) {
                        $result.failureSignalObserved = $true
                        $result.terminationRequested = $true
                        $result.terminationReason = 'FAILURE_SIGNAL'
                        break
                    }
                } catch [System.IO.IOException] {
                }
            }
        }
        $waitStopwatch.Stop()
        if ($phaseAware -and -not $result.buildPhaseCompleted) {
            $result.buildElapsedMilliseconds = [long]$waitStopwatch.ElapsedMilliseconds
        } elseif ($phaseAware) {
            $result.runElapsedMilliseconds = [long]$waitStopwatch.ElapsedMilliseconds - $runPhaseStartedMilliseconds
        }
        if ($rootWaitResult -eq [UnityBaselineProcess.NativeMethods]::WaitTimeout) {
            if (-not $result.terminationRequested) {
                $result.timedOut = $true
                $result.timeoutPhase = if ($phaseAware -and $result.buildPhaseCompleted) { 'RUN' } elseif ($phaseAware) { 'BUILD' } else { 'TOTAL' }
                $result.terminationRequested = $true
                $result.terminationReason = if ($result.timeoutPhase -eq 'BUILD') { 'BUILD_TIMEOUT' } elseif ($result.timeoutPhase -eq 'RUN') { 'RUN_TIMEOUT' } else { 'TIMEOUT' }
            }
        } elseif ($rootWaitResult -eq [UnityBaselineProcess.NativeMethods]::WaitObject0) {
            $result.rootProcessExited = $true
            $nativeExitCode = [uint32]0
            if (-not [UnityBaselineProcess.NativeMethods]::GetExitCodeProcess($processInformation.Process, [ref]$nativeExitCode)) {
                $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw (New-Object System.ComponentModel.Win32Exception($errorCode))
            }
            $result.exitCode = [long]$nativeExitCode
            $initialTreeWait = Wait-UnityJobProcessTreeExit -JobHandle $jobHandle -TimeoutMilliseconds $TreeExitGraceMilliseconds
            $result.treeExitWaitMilliseconds = $initialTreeWait.elapsedMilliseconds
            $result.activeProcessCountAfterWait = $initialTreeWait.activeProcessCount
            if ($initialTreeWait.verified) {
                $result.processTreeExitVerified = $true
            } else {
                $result.terminationRequested = $true
                $result.terminationReason = 'DESCENDANTS_REMAINED_AFTER_ROOT_EXIT'
                if (-not [string]::IsNullOrWhiteSpace([string]$initialTreeWait.error)) {
                    $result.controlError = $initialTreeWait.error
                }
            }
        } else {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode))
        }

        if ($result.terminationRequested) {
            $result.terminationApiSucceeded = [UnityBaselineProcess.NativeMethods]::TerminateJobObject($jobHandle, 124)
            if (-not $result.terminationApiSucceeded -and [string]::IsNullOrWhiteSpace([string]$result.controlError)) {
                $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                $result.controlError = (New-Object System.ComponentModel.Win32Exception($errorCode)).Message
            }
            $terminatedTreeWait = Wait-UnityJobProcessTreeExit -JobHandle $jobHandle -TimeoutMilliseconds $TerminationWaitMilliseconds
            $result.treeExitWaitMilliseconds = [int]$result.treeExitWaitMilliseconds + [int]$terminatedTreeWait.elapsedMilliseconds
            $result.activeProcessCountAfterWait = $terminatedTreeWait.activeProcessCount
            $result.processTreeExitVerified = $terminatedTreeWait.verified
            if (-not $terminatedTreeWait.verified -and [string]::IsNullOrWhiteSpace([string]$result.controlError)) {
                $result.controlError = $terminatedTreeWait.error
            }
            $terminatedRootWait = [UnityBaselineProcess.NativeMethods]::WaitForSingleObject($processInformation.Process, [uint32]$TerminationWaitMilliseconds)
            if ($terminatedRootWait -eq [UnityBaselineProcess.NativeMethods]::WaitObject0) {
                $result.rootProcessExited = $true
            }
        }
    } catch {
        $result.controlError = $_.Exception.Message
        if ($result.processStarted) {
            $result.terminationRequested = $true
            if ([string]::IsNullOrWhiteSpace([string]$result.terminationReason)) {
                $result.terminationReason = 'PROCESS_CONTROL_ERROR'
            }
            if ($jobHandle -ne [IntPtr]::Zero -and $result.processAssignedToJob) {
                $result.terminationApiSucceeded = [UnityBaselineProcess.NativeMethods]::TerminateJobObject($jobHandle, 125)
                $errorTreeWait = Wait-UnityJobProcessTreeExit -JobHandle $jobHandle -TimeoutMilliseconds $TerminationWaitMilliseconds
                $result.treeExitWaitMilliseconds = [int]$result.treeExitWaitMilliseconds + [int]$errorTreeWait.elapsedMilliseconds
                $result.activeProcessCountAfterWait = $errorTreeWait.activeProcessCount
                $result.processTreeExitVerified = $errorTreeWait.verified
            } elseif ($processInformation.Process -ne [IntPtr]::Zero) {
                $result.terminationApiSucceeded = [UnityBaselineProcess.NativeMethods]::TerminateProcess($processInformation.Process, 125)
                if ($result.terminationApiSucceeded) {
                    $unassignedWait = [UnityBaselineProcess.NativeMethods]::WaitForSingleObject($processInformation.Process, [uint32]$TerminationWaitMilliseconds)
                    $result.rootProcessExited = $unassignedWait -eq [UnityBaselineProcess.NativeMethods]::WaitObject0
                    $result.processTreeExitVerified = $result.rootProcessExited
                    $result.activeProcessCountAfterWait = 0
                }
            }
        }
    } finally {
        if ($processInformation.Thread -ne [IntPtr]::Zero) {
            [void][UnityBaselineProcess.NativeMethods]::CloseHandle($processInformation.Thread)
        }
        if ($processInformation.Process -ne [IntPtr]::Zero) {
            [void][UnityBaselineProcess.NativeMethods]::CloseHandle($processInformation.Process)
        }
        if ($jobHandle -ne [IntPtr]::Zero) {
            [void][UnityBaselineProcess.NativeMethods]::CloseHandle($jobHandle)
        }
        foreach ($streamHandle in @($standardInputHandle, $standardOutputHandle, $standardErrorHandle)) {
            if ($streamHandle -ne [IntPtr]::Zero -and $streamHandle -ne $invalidHandle) {
                [void][UnityBaselineProcess.NativeMethods]::CloseHandle($streamHandle)
            }
        }
        $result.standardOutputCaptured = Test-Path -LiteralPath $StandardOutputPath -PathType Leaf
        $result.standardErrorCaptured = Test-Path -LiteralPath $StandardErrorPath -PathType Leaf
    }

    return [pscustomobject]$result
}
