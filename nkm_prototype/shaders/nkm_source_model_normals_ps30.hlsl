// Writes interpolated, bone-skinned Source vertex normals only where this
// model fragment matches the visible Source scene depth at the same pixel.
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
    float relativeDepthDelta = abs(sceneDepth - expectedDepth)
        / max(expectedDepth, 0.00025);
    float depthTolerance = max(ModelNormalParams.z, 0.0005);

    // Discard hidden model surfaces and pixels that do not belong to the
    // currently visible Source depth buffer.
    if (sceneDepth <= 0.00025 || relativeDepthDelta > depthTolerance)
        clip(-1.0);

    float3 normal = normalize(input.worldNormal);
    float2 encodedNormal = EncodeSourceModelNormal(normal);
    // Blue is an explicit coverage flag; alpha is kept opaque for RT writes.
    return float4(encodedNormal, 1.0, 1.0);
}
