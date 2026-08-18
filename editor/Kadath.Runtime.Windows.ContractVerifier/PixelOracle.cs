namespace Kadath.Runtime.Windows.ContractVerifier;

internal sealed class PixelMapping
{
    public required int RenderWidth { get; init; }
    public required int RenderHeight { get; init; }
    public required int ClientWidth { get; init; }
    public required int ClientHeight { get; init; }
    public required double ScaleX { get; init; }
    public required double ScaleY { get; init; }
    public required Dictionary<string, (int LogicalX, int LogicalY, int PhysicalX, int PhysicalY)> Points { get; init; }

    public IReadOnlyList<(int X, int Y)> PhysicalPoints => Points.Values
        .Select(value => (value.PhysicalX, value.PhysicalY))
        .ToArray();
}

internal static class PixelOracle
{
    private static readonly byte[] PrimaryBase =
    [
        255, 0, 0, 0,
        0, 255, 0, 64,
        0, 0, 255, 128,
        255, 255, 255, 255
    ];

    private static readonly byte[] GoalBase =
    [
        255, 0, 255, 255,
        0, 255, 255, 255,
        0, 0, 0, 255,
        255, 255, 255, 255
    ];

    private static readonly double[] ClearLinear = [0.035, 0.10, 0.22];
    private static readonly double[] WhiteTint = [1.0, 1.0, 1.0, 1.0];
    private static readonly double[] GoalTint = [1.0, 0.75, 0.1, 1.0];
    private static readonly double[] DecorationTint = [0.45, 0.65, 1.0, 0.8];

    private static readonly (string Name, int X, int Y)[] LogicalPoints =
    [
        ("Background", 100, 100),
        ("Alpha0", 392, 190),
        ("Alpha64", 552, 190),
        ("Alpha128", 392, 310),
        ("Alpha255", 552, 310),
        ("GoalBR", 772, 272),
        ("DecorationTL", 120, 440),
        ("DecorationTR", 160, 440),
        ("DecorationBL", 120, 480),
        ("DecorationBR", 160, 480)
    ];

    public static PixelMapping CreateMapping(int clientWidth, int clientHeight, int renderWidth, int renderHeight)
    {
        if (renderWidth <= 772 || renderHeight <= 480)
            throw Product($"Runtime render extent is too small for frozen logical samples: {renderWidth}x{renderHeight}");
        var scaleX = clientWidth / (double)renderWidth;
        var scaleY = clientHeight / (double)renderHeight;
        if (!double.IsFinite(scaleX) || !double.IsFinite(scaleY) || scaleX <= 0 || scaleY <= 0)
            throw Product($"Runtime logical-to-physical scale is invalid: {scaleX},{scaleY}");
        var scaleTolerance = Math.Max(0.02, Math.Max(scaleX, scaleY) * 0.01);
        if (Math.Abs(scaleX - scaleY) > scaleTolerance)
            throw Product($"Runtime client scaling is non-uniform: {scaleX},{scaleY}");

        var points = new Dictionary<string, (int, int, int, int)>(StringComparer.Ordinal);
        foreach (var (name, logicalX, logicalY) in LogicalPoints)
        {
            // 与旧 verifier 一致，以像素中心映射逻辑坐标，避免高 DPI 下半像素漂移。
            var physicalX = (int)Math.Round(((logicalX + 0.5) * scaleX) - 0.5, MidpointRounding.AwayFromZero);
            var physicalY = (int)Math.Round(((logicalY + 0.5) * scaleY) - 0.5, MidpointRounding.AwayFromZero);
            if (physicalX < 0 || physicalX >= clientWidth || physicalY < 0 || physicalY >= clientHeight)
                throw Product($"Mapped sample {name} escapes the physical Runtime client.");
            points.Add(name, (logicalX, logicalY, physicalX, physicalY));
        }

        return new PixelMapping
        {
            ClientWidth = clientWidth,
            ClientHeight = clientHeight,
            RenderWidth = renderWidth,
            RenderHeight = renderHeight,
            ScaleX = scaleX,
            ScaleY = scaleY,
            Points = points
        };
    }

    public static PixelEvidence Evaluate(PixelCapture capture, PixelMapping mapping, uint swapchainFormat)
    {
        if (capture.Width != mapping.ClientWidth || capture.Height != mapping.ClientHeight)
            throw Product("Runtime client extent changed during pixel evidence capture.");
        if (swapchainFormat is not (50 or 44))
            throw Product($"Unsupported frozen swapchain format: {swapchainFormat}");

        var expected = new Dictionary<string, Rgb>(StringComparer.Ordinal)
        {
            ["Background"] = Composite([0, 0, 0, 0], WhiteTint, swapchainFormat),
            ["Alpha0"] = Composite(PrimaryBase.AsSpan(0, 4), WhiteTint, swapchainFormat),
            ["Alpha64"] = Composite(PrimaryBase.AsSpan(4, 4), WhiteTint, swapchainFormat),
            ["Alpha128"] = Composite(PrimaryBase.AsSpan(8, 4), WhiteTint, swapchainFormat),
            ["Alpha255"] = Composite(PrimaryBase.AsSpan(12, 4), WhiteTint, swapchainFormat),
            ["GoalBR"] = Composite(GoalBase.AsSpan(12, 4), GoalTint, swapchainFormat),
            ["DecorationTL"] = Composite(GoalBase.AsSpan(0, 4), DecorationTint, swapchainFormat),
            ["DecorationTR"] = Composite(GoalBase.AsSpan(4, 4), DecorationTint, swapchainFormat),
            ["DecorationBL"] = Composite(GoalBase.AsSpan(8, 4), DecorationTint, swapchainFormat),
            ["DecorationBR"] = Composite(GoalBase.AsSpan(12, 4), DecorationTint, swapchainFormat)
        };
        AssertFrozenGoalOracle(expected, swapchainFormat);

        var points = new Dictionary<string, PixelPointEvidence>(StringComparer.Ordinal);
        foreach (var (name, coordinates) in mapping.Points)
        {
            var actual = capture.Sample(coordinates.PhysicalX, coordinates.PhysicalY);
            var expectedValue = expected[name];
            points.Add(name, new PixelPointEvidence(
                coordinates.LogicalX,
                coordinates.LogicalY,
                coordinates.PhysicalX,
                coordinates.PhysicalY,
                actual,
                expectedValue,
                actual.MaximumChannelDifference(expectedValue)));
        }

        var compositeMaximum = new[] { "Background", "Alpha0", "Alpha64", "Alpha128", "Alpha255" }
            .Max(name => points[name].MaximumChannelError);
        // GoalBR 冻结目标实体的 tint/placement；固定 decoration 复用同一 texture，提供无遮挡的完整四 texel oracle。
        var goalMaximum = new[]
            { "GoalBR", "DecorationTL", "DecorationTR", "DecorationBL", "DecorationBR" }
            .Max(name => points[name].MaximumChannelError);
        var coarseAlpha = points["Alpha0"].Actual.MaximumChannelDifference(points["Background"].Actual) <= 24
            && points["Alpha255"].Actual is { R: >= 230, G: >= 230, B: >= 230 };

        var colors = new HashSet<int>();
        long nonBlack = 0;
        for (var offset = 0; offset < capture.Bgra.Length; offset += 4)
        {
            var packed = capture.Bgra[offset]
                | capture.Bgra[offset + 1] << 8
                | capture.Bgra[offset + 2] << 16;
            colors.Add(packed);
            if ((packed & 0x00ffffff) != 0) nonBlack++;
        }
        var nonEmpty = colors.Count >= 8 && nonBlack >= 1_000;
        return new PixelEvidence
        {
            Passed = nonEmpty && coarseAlpha && compositeMaximum <= 8 && goalMaximum <= 24,
            NonEmpty = nonEmpty,
            DistinctColorCount = colors.Count,
            NonBlackPixelCount = nonBlack,
            CompositeTolerance = 8,
            GoalTolerance = 24,
            MaximumChannelError = compositeMaximum,
            GoalMaximumChannelError = goalMaximum,
            ScaleX = mapping.ScaleX,
            ScaleY = mapping.ScaleY,
            Samples = points
        };
    }

    public static PlayerMovementEvidence EvaluateUpwardMovement(
        PixelCapture before,
        PixelCapture after,
        PixelMapping mapping,
        uint swapchainFormat)
    {
        var point = mapping.Points["Alpha255"];
        var beforeRgb = before.Sample(point.PhysicalX, point.PhysicalY);
        var afterRgb = after.Sample(point.PhysicalX, point.PhysicalY);
        var background = Composite([0, 0, 0, 0], WhiteTint, swapchainFormat);
        var difference = beforeRgb.MaximumChannelDifference(afterRgb);
        var backgroundError = afterRgb.MaximumChannelDifference(background);
        var passed = beforeRgb is { R: >= 230, G: >= 230, B: >= 230 }
            && difference >= 80
            && backgroundError <= 24;
        return new PlayerMovementEvidence(
            point.LogicalX,
            point.LogicalY,
            point.PhysicalX,
            point.PhysicalY,
            beforeRgb,
            afterRgb,
            background,
            difference,
            backgroundError,
            passed);
    }

    private static Rgb Composite(ReadOnlySpan<byte> source, double[] tint, uint format)
    {
        var alpha = source[3] / 255.0 * tint[3];
        Span<int> output = stackalloc int[3];
        for (var channel = 0; channel < 3; channel++)
        {
            var sourceLinear = SrgbByteToLinear(source[channel]) * tint[channel];
            var outputLinear = sourceLinear * alpha + ClearLinear[channel] * (1.0 - alpha);
            output[channel] = format == 50
                ? LinearToSrgbByte(outputLinear)
                : (int)Math.Round(255.0 * Math.Clamp(outputLinear, 0.0, 1.0), MidpointRounding.AwayFromZero);
        }
        return new Rgb(output[0], output[1], output[2]);
    }

    private static double SrgbByteToLinear(byte value)
    {
        var encoded = value / 255.0;
        return encoded <= 0.04045
            ? encoded / 12.92
            : Math.Pow((encoded + 0.055) / 1.055, 2.4);
    }

    private static int LinearToSrgbByte(double value)
    {
        var linear = Math.Clamp(value, 0.0, 1.0);
        var encoded = linear <= 0.0031308
            ? 12.92 * linear
            : 1.055 * Math.Pow(linear, 1.0 / 2.4) - 0.055;
        return (int)Math.Round(255.0 * encoded, MidpointRounding.AwayFromZero);
    }

    private static void AssertFrozenGoalOracle(IReadOnlyDictionary<string, Rgb> expected, uint format)
    {
        var frozen = format == 50
            ? new Dictionary<string, Rgb>
            {
                ["GoalBR"] = new(255, 225, 89),
                ["DecorationTL"] = new(163, 39, 237),
                ["DecorationTR"] = new(20, 194, 237),
                ["DecorationBL"] = new(20, 39, 59),
                ["DecorationBR"] = new(163, 194, 237)
            }
            : new Dictionary<string, Rgb>
            {
                ["GoalBR"] = new(255, 191, 26),
                ["DecorationTL"] = new(94, 5, 215),
                ["DecorationTR"] = new(2, 138, 215),
                ["DecorationBL"] = new(2, 5, 11),
                ["DecorationBR"] = new(94, 138, 215)
            };
        foreach (var (name, color) in frozen)
        {
            if (expected[name] != color) throw Product($"Frozen goal pixel oracle changed for {name} on format {format}.");
        }
    }

    private static VerifierFailure Product(string message) =>
        new(FailureClassification.ProductContract, "pixel_oracle", message);
}
