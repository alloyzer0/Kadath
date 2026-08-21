using System.Text.RegularExpressions;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal sealed partial class WindowsRuntimeProductVerifier
{
    private const int VirtualKeyR = 0x52;
    private const int VirtualKeyUp = 0x26;
    private const int VirtualKeyRight = 0x27;

    private static readonly string[] StartupMarkers =
    [
        "Platform window created (960x540)",
        "Vulkan RHI initialized",
        "Loaded preview scene artifact: assets/scenes/preview.scene, artifact_version=6",
        "Loaded behavior package: assets/scripts/preview.script, artifact_version=2",
        "Behavior on_start hooks applied",
        "Runtime host initialized with Vulkan RHI scene objects=5",
        "Runtime main loop entered",
        "Audio initialized: backend=winmm"
    ];

    private static readonly string[] FinalMarkers =
    [
        .. StartupMarkers,
        "Game session lost: timer expired",
        "Audio cue played: lost",
        "Game session restarted:",
        "Game session won:",
        "Audio cue played: won",
        "Audio shutdown complete",
        "Vulkan RHI shutdown complete",
        "Platform shutdown complete",
        "Kadath runtime shutdown complete"
    ];

    public async Task<VerificationOutcome> VerifyAsync(VerificationRequest request)
    {
        EvidenceStore? evidence = null;
        PackageContract? package = null;
        RuntimeProcessSession? runtime = null;
        Win32RuntimeWindow? window = null;
        nint windowHandle = 0;
        var stage = "preflight";
        VerifierFailure? failure = null;
        var manifest = new RuntimeVerificationManifest
        {
            PackageRoot = request.PackageRoot,
            EvidenceDirectory = request.EvidenceDirectory,
            RequiredLogMarkers = FinalMarkers
        };

        using var overallTimeout = new CancellationTokenSource(request.OverallTimeout);
        try
        {
            var packageRoot = PathSafety.RequireExistingDirectory(request.PackageRoot, "PackageRoot");
            manifest.PackageRoot = packageRoot;
            evidence = EvidenceStore.Create(packageRoot, request.EvidenceDirectory);
            manifest.EvidenceDirectory = evidence.Root;

            if (!OperatingSystem.IsWindows())
                throw new VerifierFailure(FailureClassification.UnsupportedPlatform, "platform", "This verifier requires native Windows.");
            if (!Environment.UserInteractive)
                throw new VerifierFailure(FailureClassification.WindowEnvironment, "platform", "The verifier requires an interactive Windows desktop.");

            stage = "package_preflight";
            manifest.Stage = stage;
            package = PackageContract.Load(packageRoot);
            manifest.RuntimeExecutable = package.RuntimePath;
            manifest.Optimize = package.Optimize;
            manifest.BuildPreflightSidecarSha256 = package.BuildPreflightSidecarSha256;
            manifest.PackageIdentityBefore = package.IdentityBefore.ToDictionary(
                pair => pair.Key,
                pair => pair.Value,
                StringComparer.Ordinal);

            var arguments = new[]
            {
                "--scene", package.RuntimeRelativeArgument(package.SceneArtifactPath),
                "--script", package.RuntimeRelativeArgument(package.ScriptArtifactPath),
                "--preview-status", "jsonl-v1"
            };
            manifest.RuntimeArguments = arguments;

            stage = "runtime_start";
            manifest.Stage = stage;
            try
            {
                runtime = RuntimeProcessSession.Start(package.RuntimePath, package.WorkingDirectory, arguments);
            }
            catch (Exception exception) when (exception is not VerifierFailure)
            {
                throw new VerifierFailure(
                    FailureClassification.ProductContract,
                    stage,
                    $"Cannot launch package Runtime: {exception.Message}",
                    exception);
            }
            manifest.RuntimePid = runtime.Id;

            stage = "window_ready";
            manifest.Stage = stage;
            windowHandle = await WaitForReadyWindowAsync(runtime, overallTimeout.Token).ConfigureAwait(false);
            window = new Win32RuntimeWindow(windowHandle, runtime.Id);
            manifest.WindowHandle = $"0x{windowHandle:x}";
            manifest.WindowOwnerPid = window.OwnerProcessId;
            manifest.WindowClass = window.ClassName;
            manifest.WindowDpi = window.Dpi;
            manifest.WindowVisible = window.IsVisible;
            if (manifest.WindowDpi == 0)
                throw new VerifierFailure(FailureClassification.WindowEnvironment, stage, "Runtime window did not report a valid physical DPI.");

            var stderr = runtime.StderrText;
            var swapchain = ParseSwapchain(stderr, requireExactlyOneCreation: true);
            manifest.SwapchainFormat = swapchain.Format;
            manifest.RenderWidth = swapchain.Width;
            manifest.RenderHeight = swapchain.Height;

            stage = "initial_loaded";
            manifest.Stage = stage;
            manifest.InitialLoaded = RuntimeStatusProtocol.ParseInitialLoaded(
                runtime.StdoutText,
                package.IdentityBefore["bin/assets/scenes/preview.scene"],
                package.IdentityBefore["bin/assets/scripts/preview.script"]);

            stage = "window_capture_setup";
            manifest.Stage = stage;
            manifest.ForegroundAcquired = window.PrepareUnobscuredCapture();
            await Task.Delay(200, overallTimeout.Token).ConfigureAwait(false);
            var metrics = window.GetMetrics();
            manifest.ClientWidth = metrics.Width;
            manifest.ClientHeight = metrics.Height;
            if (metrics.Width < 773 || metrics.Height < 311)
                throw new VerifierFailure(
                    FailureClassification.WindowEnvironment,
                    stage,
                    $"Runtime physical client is too small for frozen samples: {metrics.Width}x{metrics.Height} < 773x311.");
            var mapping = PixelOracle.CreateMapping(metrics.Width, metrics.Height, swapchain.Width, swapchain.Height);
            manifest.WindowUnobscured = window.EvidencePointsAreUnobscured(mapping.PhysicalPoints);
            if (!manifest.WindowUnobscured)
                throw new VerifierFailure(
                    FailureClassification.WindowEnvironment,
                    stage,
                    "Runtime client grid/sample points are obscured; GDI capture is not trustworthy.");

            stage = "wait_loss";
            manifest.Stage = stage;
            var lossPosition = await WaitForGameplayMarkerAsync(
                runtime,
                "Game session lost: timer expired",
                TimeSpan.FromSeconds(6),
                0,
                stage,
                overallTimeout.Token).ConfigureAwait(false);
            await WaitForGameplayMarkerAsync(
                runtime,
                "Audio cue played: lost",
                TimeSpan.FromSeconds(2),
                0,
                "lost_audio",
                overallTimeout.Token).ConfigureAwait(false);
            manifest.LostAudioCueObserved = true;

            stage = "restart_input";
            manifest.Stage = stage;
            var restartMarker = "Game session restarted:";
            var beforeRestart = runtime.StderrText;
            var unexpectedRestart = beforeRestart.IndexOf(
                restartMarker,
                lossPosition + "Game session lost: timer expired".Length,
                StringComparison.Ordinal);
            if (unexpectedRestart >= 0)
                throw Product(stage, "GameSession restart appeared after loss before verifier posted R.");
            var restartSearchStart = beforeRestart.Length;
            PostKey(window, VirtualKeyR, "R", manifest);
            var restartPosition = await WaitForGameplayMarkerAsync(
                runtime,
                restartMarker,
                TimeSpan.FromSeconds(2),
                restartSearchStart,
                stage,
                overallTimeout.Token).ConfigureAwait(false);
            if (restartPosition < restartSearchStart || restartPosition <= lossPosition)
                throw Product(stage, "GameSession restart evidence is outside the verifier-owned R input boundary.");
            manifest.RestartObserved = true;

            stage = "pixel_capture";
            manifest.Stage = stage;
            var (baselineCapture, pixels, consecutiveFramesPassed) = await CaptureTwoPassingFramesAsync(
                window,
                mapping,
                swapchain.Format,
                overallTimeout.Token).ConfigureAwait(false);
            manifest.Pixels = pixels;
            evidence.WritePixels(pixels);
            PngEvidenceWriter.Write(evidence.ScreenshotPath, baselineCapture);
            if (!consecutiveFramesPassed)
                throw Product(
                    stage,
                    $"Runtime pixels did not pass two consecutive frames at least 100ms apart: passed={pixels.Passed}, nonempty={pixels.NonEmpty}, max_error={pixels.MaximumChannelError}, goal_error={pixels.GoalMaximumChannelError}.");

            stage = "player_movement";
            manifest.Stage = stage;
            await HoldKeyAsync(
                window,
                runtime,
                VirtualKeyUp,
                "Up",
                TimeSpan.FromMilliseconds(800),
                manifest,
                overallTimeout.Token).ConfigureAwait(false);
            await Task.Delay(75, overallTimeout.Token).ConfigureAwait(false);
            EnsureWindowCaptureIsTrustworthy(window, mapping, stage);
            var movementCapture = window.CaptureClient();
            var movement = PixelOracle.EvaluateUpwardMovement(
                baselineCapture,
                movementCapture,
                mapping,
                swapchain.Format);
            manifest.PlayerMovementSample = movement;
            PngEvidenceWriter.Write(evidence.MovementScreenshotPath, movementCapture);
            if (!movement.Passed)
                throw Product(
                    stage,
                    $"Player did not leave the frozen Alpha255 sample after Up input: difference={movement.BeforeAfterDifference}, background_error={movement.AfterBackgroundError}.");
            manifest.PlayerMovementObserved = true;

            stage = "won_gameplay";
            manifest.Stage = stage;
            var wonSearchStart = runtime.StderrText.Length;
            await HoldKeyAsync(
                window,
                runtime,
                VirtualKeyRight,
                "Right",
                TimeSpan.FromMilliseconds(450),
                manifest,
                overallTimeout.Token).ConfigureAwait(false);
            var wonPosition = await WaitForGameplayMarkerAsync(
                runtime,
                "Game session won:",
                TimeSpan.FromSeconds(2),
                restartPosition,
                stage,
                overallTimeout.Token).ConfigureAwait(false);
            manifest.WonObserved = true;
            await WaitForGameplayMarkerAsync(
                runtime,
                "Audio cue played: won",
                TimeSpan.FromSeconds(2),
                wonSearchStart,
                "won_audio",
                overallTimeout.Token).ConfigureAwait(false);
            manifest.WonAudioCueObserved = true;

            stage = "runtime_close";
            manifest.Stage = stage;
            // 关闭前撤销临时置顶，WM_CLOSE 仍只投递给本 verifier 启动且校验过 owner PID 的 HWND。
            window.Dispose();
            window.PostCloseOrThrow();
            manifest.WmClosePosted = true;
            await runtime.WaitForExitAsync(TimeSpan.FromSeconds(10), overallTimeout.Token).ConfigureAwait(false);
            manifest.RuntimeExitCode = runtime.ExitCode;
            if (runtime.ExitCode != 0)
                throw Product(stage, $"Runtime exited with code {runtime.ExitCode} after WM_CLOSE.");

            stage = "final_contract";
            manifest.Stage = stage;
            stderr = runtime.StderrText;
            AssertFinalLogContract(stderr);
            _ = ParseSwapchain(stderr, requireExactlyOneCreation: true);
            RuntimeStatusProtocol.AssertWindowClose(runtime.StdoutText, stage);
            manifest.RuntimeStoppingWindowCloseObserved = true;

            manifest.PackageIdentityAfter = package.CaptureCurrentIdentities();
            PackageContract.AssertIdentityUnchanged(manifest.PackageIdentityBefore, manifest.PackageIdentityAfter);
            manifest.Stage = "complete";
        }
        catch (VerifierFailure exception)
        {
            failure = ReclassifyEnvironmentFailure(exception, runtime);
        }
        catch (OperationCanceledException exception)
        {
            failure = ReclassifyEnvironmentFailure(
                new VerifierFailure(FailureClassification.Timeout, stage, $"Overall verifier timeout elapsed during {stage}.", exception),
                runtime);
        }
        catch (Exception exception)
        {
            failure = ReclassifyEnvironmentFailure(
                new VerifierFailure(FailureClassification.Internal, stage, $"Unexpected verifier failure during {stage}: {exception.Message}", exception),
                runtime);
        }
        finally
        {
            window?.Dispose();
            if (runtime is not null)
            {
                try
                {
                    // 成功和失败共用有界清理；失败时必要才 Kill(entireProcessTree)，不能遗留旧 Runtime 身份。
                    await runtime.EnsureStoppedAsync(windowHandle, CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception exception)
                {
                    manifest.CleanupError = $"Process cleanup failed: {exception.Message}";
                    failure ??= new VerifierFailure(FailureClassification.Internal, "process_cleanup", manifest.CleanupError, exception);
                }

                manifest.RawStdout = runtime.StdoutText;
                manifest.RawStderr = runtime.StderrText;
                manifest.RuntimeExitCode = runtime.ExitCode;
                manifest.ForcedProcessTreeKill = runtime.ForcedTreeKill;
                manifest.ProcessTreeStopped = runtime.HasExited;
                try
                {
                    await runtime.DisposeAsync().ConfigureAwait(false);
                }
                catch (Exception exception)
                {
                    manifest.CleanupError = JoinErrors(manifest.CleanupError, $"Process disposal failed: {exception.Message}");
                    failure ??= new VerifierFailure(FailureClassification.Internal, "process_cleanup", manifest.CleanupError, exception);
                }
            }

            if (package is not null && manifest.PackageIdentityAfter.Count == 0)
            {
                try
                {
                    manifest.PackageIdentityAfter = package.CaptureCurrentIdentities();
                    PackageContract.AssertIdentityUnchanged(manifest.PackageIdentityBefore, manifest.PackageIdentityAfter);
                }
                catch (Exception exception)
                {
                    var identityFailure = exception as VerifierFailure
                        ?? new VerifierFailure(FailureClassification.PackageIdentity, "identity_after", $"Cannot verify final package identity: {exception.Message}", exception);
                    if (failure is not null)
                        manifest.CleanupError = JoinErrors(manifest.CleanupError, $"Earlier failure: [{failure.Stage}] {failure.Message}");
                    failure = identityFailure;
                }
            }
        }

        if (evidence is null)
            throw failure ?? new VerifierFailure(FailureClassification.EvidenceIo, "evidence_create", "Evidence directory was not created.");

        var status = failure is null
            ? VerificationStatus.Pass
            : failure.Classification.IsEnvironmentBlock()
                ? VerificationStatus.BlockedEnvironment
                : VerificationStatus.Fail;
        manifest.Status = status.ToWireName();
        manifest.Classification = (failure?.Classification ?? FailureClassification.None).ToWireName();
        manifest.Stage = failure?.Stage ?? "complete";
        manifest.FirstError = failure?.Message;
        manifest.EndedAtUtc = DateTimeOffset.UtcNow.ToString("O");

        try
        {
            evidence.WriteLogs(manifest.RawStdout ?? string.Empty, manifest.RawStderr ?? string.Empty);
            manifest.StdoutSha256 = EvidenceStore.HashFile(evidence.StdoutPath);
            manifest.StderrSha256 = EvidenceStore.HashFile(evidence.StderrPath);
            if (File.Exists(evidence.ScreenshotPath))
                manifest.ScreenshotSha256 = EvidenceStore.HashFile(evidence.ScreenshotPath);
            if (File.Exists(evidence.MovementScreenshotPath))
                manifest.MovementScreenshotSha256 = EvidenceStore.HashFile(evidence.MovementScreenshotPath);
            evidence.WriteManifest(manifest);
            evidence.WriteStatus(new VerificationStatusDocument(
                manifest.VerificationVersion,
                manifest.Status,
                manifest.Classification,
                manifest.Stage,
                manifest.FirstError,
                manifest.CleanupError,
                manifest.StartedAtUtc,
                manifest.EndedAtUtc,
                evidence.ManifestPath,
                evidence.StdoutPath,
                evidence.StderrPath,
                File.Exists(evidence.ScreenshotPath) ? evidence.ScreenshotPath : null,
                File.Exists(evidence.MovementScreenshotPath) ? evidence.MovementScreenshotPath : null));
        }
        catch (Exception exception)
        {
            throw new VerifierFailure(
                FailureClassification.EvidenceIo,
                "evidence_write",
                $"Cannot finalize verifier evidence: {exception.Message}",
                exception);
        }

        return new VerificationOutcome(
            status,
            failure?.Classification ?? FailureClassification.None,
            failure?.Message,
            evidence.Root,
            evidence.StatusPath,
            evidence.ManifestPath);
    }

    private static async Task<nint> WaitForReadyWindowAsync(
        RuntimeProcessSession runtime,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(15);
        while (DateTimeOffset.UtcNow <= deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var stderr = runtime.StderrText;
            var window = Win32RuntimeWindow.FindLargestVisibleWindow(runtime.Id);
            var markersReady = StartupMarkers.All(marker => stderr.Contains(marker, StringComparison.Ordinal))
                && CountOccurrences(stderr, "Renderer2D texture upload complete: mip_levels=2") >= 2
                && CountOccurrences(stderr, "RHI texture created:") >= 2
                && runtime.StdoutText.Contains("\"event\":\"runtime_ready\"", StringComparison.Ordinal);
            if (window != 0 && markersReady) return window;
            if (runtime.HasExited)
                throw new VerifierFailure(
                    ClassifyFromRuntimeLogs(runtime, FailureClassification.ProductContract),
                    "window_ready",
                    $"Runtime exited with code {runtime.ExitCode} before native Window/Vulkan readiness.");
            await Task.Delay(50, cancellationToken).ConfigureAwait(false);
        }

        var fallback = Win32RuntimeWindow.FindLargestVisibleWindow(runtime.Id) == 0
            ? FailureClassification.WindowEnvironment
            : FailureClassification.Timeout;
        throw new VerifierFailure(
            ClassifyFromRuntimeLogs(runtime, fallback),
            "window_ready",
            "Timed out waiting for visible native Runtime window, Vulkan initialization, textures, Audio, and runtime_ready identity.");
    }

    private static async Task<int> WaitForGameplayMarkerAsync(
        RuntimeProcessSession runtime,
        string marker,
        TimeSpan timeout,
        int searchStart,
        string stage,
        CancellationToken cancellationToken)
    {
        try
        {
            return await runtime.WaitForStderrAsync(marker, timeout, searchStart, stage, cancellationToken).ConfigureAwait(false);
        }
        catch (VerifierFailure exception)
        {
            throw ReclassifyEnvironmentFailure(exception, runtime);
        }
    }

    private static async Task<(PixelCapture Capture, PixelEvidence Evidence, bool ConsecutiveFramesPassed)> CaptureTwoPassingFramesAsync(
        Win32RuntimeWindow window,
        PixelMapping mapping,
        uint format,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
        DateTimeOffset? previousPass = null;
        var passTimes = new List<string>();
        PixelCapture? lastCapture = null;
        PixelEvidence? lastEvidence = null;

        while (DateTimeOffset.UtcNow <= deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            EnsureWindowCaptureIsTrustworthy(window, mapping, "pixel_capture");
            var capture = window.CaptureClient();
            var evidence = PixelOracle.Evaluate(capture, mapping, format);
            var now = DateTimeOffset.UtcNow;
            lastCapture = capture;
            lastEvidence = evidence;
            if (evidence.Passed)
            {
                if (previousPass is null)
                {
                    previousPass = now;
                    passTimes.Clear();
                    passTimes.Add(now.ToString("O"));
                }
                else if (now - previousPass.Value >= TimeSpan.FromMilliseconds(100))
                {
                    passTimes.Add(now.ToString("O"));
                    evidence.ConsecutivePassTimesUtc = passTimes.ToArray();
                    return (capture, evidence, true);
                }
            }
            else
            {
                previousPass = null;
                passTimes.Clear();
            }
            await Task.Delay(100, cancellationToken).ConfigureAwait(false);
        }

        if (lastCapture is null || lastEvidence is null)
            throw Product("pixel_capture", "Runtime pixel capture deadline elapsed before any frame was captured.");
        lastEvidence.ConsecutivePassTimesUtc = passTimes.ToArray();
        return (lastCapture, lastEvidence, false);
    }

    private static void EnsureWindowCaptureIsTrustworthy(
        Win32RuntimeWindow window,
        PixelMapping mapping,
        string stage)
    {
        if (!window.IsVisible || !window.EvidencePointsAreUnobscured(mapping.PhysicalPoints))
            throw new VerifierFailure(
                FailureClassification.WindowEnvironment,
                stage,
                "Runtime window became hidden, minimized, or obscured during capture.");
    }

    private static void PostKey(
        Win32RuntimeWindow window,
        int virtualKey,
        string keyName,
        RuntimeVerificationManifest manifest)
    {
        window.PostKeyDown(virtualKey);
        manifest.InputEvents.Add(new InputEventEvidence(keyName, "WM_KEYDOWN", DateTimeOffset.UtcNow.ToString("O")));
        window.PostKeyUp(virtualKey);
        manifest.InputEvents.Add(new InputEventEvidence(keyName, "WM_KEYUP", DateTimeOffset.UtcNow.ToString("O")));
    }

    private static async Task HoldKeyAsync(
        Win32RuntimeWindow window,
        RuntimeProcessSession runtime,
        int virtualKey,
        string keyName,
        TimeSpan duration,
        RuntimeVerificationManifest manifest,
        CancellationToken cancellationToken)
    {
        window.PostKeyDown(virtualKey);
        manifest.InputEvents.Add(new InputEventEvidence(keyName, "WM_KEYDOWN", DateTimeOffset.UtcNow.ToString("O")));
        try
        {
            await Task.Delay(duration, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            // 即使超时也必须释放 held key；只在本 Runtime 尚存活时向已验证 owner 的窗口投递。
            if (!runtime.HasExited)
            {
                window.PostKeyUp(virtualKey);
                manifest.InputEvents.Add(new InputEventEvidence(keyName, "WM_KEYUP", DateTimeOffset.UtcNow.ToString("O")));
            }
        }
    }

    private static SwapchainEvidence ParseSwapchain(string stderr, bool requireExactlyOneCreation)
    {
        var matches = SwapchainLine().Matches(stderr);
        if (matches.Count == 0)
            throw Product("swapchain", "Runtime log does not contain a valid Vulkan swapchain creation record.");
        if (requireExactlyOneCreation && matches.Count != 1)
            throw Product("swapchain", $"Expected exactly one Vulkan swapchain creation record, got {matches.Count}.");

        var formats = matches.Select(match => uint.Parse(match.Groups["format"].Value)).Distinct().ToArray();
        var extents = matches.Select(match => (
            Width: int.Parse(match.Groups["width"].Value),
            Height: int.Parse(match.Groups["height"].Value))).Distinct().ToArray();
        if (formats.Length != 1 || formats[0] is not (50 or 44))
            throw Product("swapchain", $"Swapchain format must be VK_FORMAT_B8G8R8A8_SRGB (50) or UNORM (44), got {string.Join(',', formats)}.");
        if (extents.Length != 1)
            throw Product("swapchain", "Runtime log contains conflicting Vulkan swapchain extents.");
        return new SwapchainEvidence(formats[0], extents[0].Width, extents[0].Height);
    }

    private static void AssertFinalLogContract(string stderr)
    {
        foreach (var marker in FinalMarkers)
        {
            if (!stderr.Contains(marker, StringComparison.Ordinal))
                throw Product("final_contract", $"Runtime log is missing required marker: {marker}");
        }
        if (CountOccurrences(stderr, "Renderer2D texture upload complete: mip_levels=2") < 2
            || CountOccurrences(stderr, "RHI texture created:") < 2)
        {
            throw Product("final_contract", "Runtime did not publish both frozen texture upload/create records.");
        }
        if (RuntimeErrorEvidence().IsMatch(stderr))
            throw Product("final_contract", "Runtime log contains Vulkan validation/error evidence.");

        var audio = stderr.IndexOf("Audio shutdown complete", StringComparison.Ordinal);
        var rhi = stderr.IndexOf("Vulkan RHI shutdown complete", StringComparison.Ordinal);
        var platform = stderr.IndexOf("Platform shutdown complete", StringComparison.Ordinal);
        var runtime = stderr.IndexOf("Kadath runtime shutdown complete", StringComparison.Ordinal);
        if (!(audio >= 0 && audio < rhi && rhi < platform && platform < runtime))
            throw Product("final_contract", "Runtime shutdown markers are missing or out of ownership order.");
    }

    private static VerifierFailure ReclassifyEnvironmentFailure(
        VerifierFailure failure,
        RuntimeProcessSession? runtime)
    {
        if (runtime is null) return failure;
        var classification = ClassifyFromRuntimeLogs(runtime, failure.Classification);
        return classification == failure.Classification
            ? failure
            : new VerifierFailure(classification, failure.Stage, failure.Message, failure);
    }

    private static FailureClassification ClassifyFromRuntimeLogs(
        RuntimeProcessSession runtime,
        FailureClassification fallback)
    {
        var logs = runtime.StdoutText + "\n" + runtime.StderrText;
        if (logs.Contains("Audio cue failed:", StringComparison.Ordinal))
            return FailureClassification.AudioEnvironment;
        if (GpuFailureEvidence().IsMatch(logs))
            return FailureClassification.GpuEnvironment;
        return fallback;
    }

    private static int CountOccurrences(string value, string marker)
    {
        var count = 0;
        var offset = 0;
        while ((offset = value.IndexOf(marker, offset, StringComparison.Ordinal)) >= 0)
        {
            count++;
            offset += marker.Length;
        }
        return count;
    }

    private static string JoinErrors(string? current, string addition) =>
        string.IsNullOrWhiteSpace(current) ? addition : current + " | " + addition;

    private static VerifierFailure Product(string stage, string message) =>
        new(FailureClassification.ProductContract, stage, message);

    [GeneratedRegex(
        @"(?im)^.*Vulkan swapchain created:.*\bformat=(?<format>\d+)\b.*\bextent=(?<width>[1-9]\d*)x(?<height>[1-9]\d*)\b.*$",
        RegexOptions.CultureInvariant)]
    private static partial Regex SwapchainLine();

    [GeneratedRegex(@"(?im)\bVUID-|validation\s+error|VulkanCallFailed|^.*error:.*$", RegexOptions.CultureInvariant)]
    private static partial Regex RuntimeErrorEvidence();

    [GeneratedRegex(
        @"(?im)VulkanCallFailed|RequiredInstanceExtensionMissing|NoPhysicalDevice|NoGraphicsPresentQueue|ColorAttachmentUnsupported|NoSurfaceFormat|NoCompositeAlphaMode|NoCompatibleMemoryType|NoSuitablePhysicalDevice|NoVulkan|vkCreate(?:Instance|Device|SwapchainKHR).*failed|Runtime startup failed:.*Vulkan|failed to (?:create|initialize).*Vulkan",
        RegexOptions.CultureInvariant)]
    private static partial Regex GpuFailureEvidence();

    private sealed record SwapchainEvidence(uint Format, int Width, int Height);
}
