// Captures skinned Source vertex normals and exposes depth-match diagnostics.
// c0.w: 0=strict normal, 1=ungated normal, 2=depth delta view, 3=reject mask.
sampler SourceWorldPositionBuffer : register(s0); // GShader _rt_WPDepth
const float4 ModelNormalParams : register(c0); // xy=inverse RT size, z=relative depth tolerance

struct PS_INPUT
{
    float2 screenPos   : VPOS;
    float3 worldNormal : TEXCOORD0;
    float clipW        : TEXCOORD1;
};

float2 EncodeSourceModelNormal(float3 normal)
{
    normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 0.000001);
    if (normal.z < 0.0)
    {
        float2 signs = float2(
            normal.x >= 0.0 ? 1.0 : -1.0,
            normal.y >= 0.0 ? 1.0 : -1.0);
        normal.xy = (1.0 - abs(normal.yx)) * signs;
    }
    return normal.xy * 0.5 + 0.5;
}

float4 main(PS_INPUT input) : COLOR0
{
    float2 uv = input.screenPos * ModelNormalParams.xy;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        clip(-1.0);

    float sceneDepth = tex2Dlod(SourceWorldPositionBuffer, float4(uv, 0, 0)).a;
    float expectedDepth = 1.0 / max(input.clipW, 0.0001);
    // Both values are reciprocal linear view depth: larger means nearer.
    // Positive signed delta means the scene buffer has a nearer occluder;
    // negative means it reports a surface farther away than this model fragment.
    float signedRelativeDepthDelta = (sceneDepth - expectedDepth)
        / max(expectedDepth, 0.00025);
    float relativeDepthDelta = abs(signedRelativeDepthDelta);
    float depthTolerance = max(ModelNormalParams.z, 0.0005);
    bool hasSceneDepth = sceneDepth > 0.00025;
    bool depthMismatch = !hasSceneDepth || relativeDepthDelta > depthTolerance;

    // Diagnostic modes run before strict rejection. They use the same model
    // rasterization and sampled scene depth as the normal capture pass.
    if (ModelNormalParams.w > 1.5 && ModelNormalParams.w < 2.5)
    {
        // Blue -> cyan -> red maps 0 .. 4x tolerance. Magenta means that the
        // GShader world-position buffer contains no scene depth at this pixel.
        if (!hasSceneDepth)
            return float4(1.0, 0.0, 1.0, 1.0);

        float deltaScale = saturate(relativeDepthDelta
            / max(depthTolerance * 4.0, 0.002));
        float3 deltaColor;
        if (deltaScale < 0.5)
            deltaColor = lerp(float3(0.0, 0.0, 0.35),
                float3(0.0, 0.9, 1.0), deltaScale * 2.0);
        else
            deltaColor = lerp(float3(0.0, 0.9, 1.0),
                float3(1.0, 0.05, 0.0), (deltaScale - 0.5) * 2.0);
        return float4(deltaColor, 1.0);
    }

    if (ModelNormalParams.w >= 2.5)
    {
        // Green = depth match. Orange = the sampled scene surface is nearer
        // than this prop (normally a foreground occluder, e.g. a jumping player).
        // Blue = the scene buffer reports a farther surface than this fragment,
        // which suggests screen/depth registration or reconstruction mismatch.
        // Red = no GShader depth; black = outside candidate model coverage.
        if (!hasSceneDepth) return float4(1.0, 0.0, 0.0, 1.0);
        if (signedRelativeDepthDelta > depthTolerance)
            return float4(1.0, 0.45, 0.0, 1.0);
        if (signedRelativeDepthDelta < -depthTolerance)
            return float4(0.0, 0.35, 1.0, 1.0);
        return float4(0.0, 1.0, 0.0, 1.0);
    }

    // Strict capture rejects hidden/mismatched fragments. c0.w=1 bypasses
    // only this comparison to create the ungated normal diagnostic.
    if (ModelNormalParams.w < 0.5 && depthMismatch)
        clip(-1.0);

    float3 normal = normalize(input.worldNormal);
    float2 encodedNormal = EncodeSourceModelNormal(normal);
    // Blue is an explicit coverage flag; alpha is kept opaque for RT writes.
    return float4(encodedNormal, 1.0, 1.0);
}
