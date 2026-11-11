// Visualize the angular response of captured Source model normals to all
// active NKM point lights. This intentionally ignores light radius/falloff,
// color, material albedo, AO, and shadows: it isolates max(saturate(N dot L)).
#include "common_octahedron_encoding.h"

sampler SourceWorldPositionBuffer : register(s0); // GShader _rt_WPDepth
sampler SourceModelNormalBuffer   : register(s1); // optional captured skinned/bump model normals
sampler DynamicLightBuffer        : register(s2); // 2x32 point-light LUT
sampler SourceReceiverNormalBuffer : register(s3); // reconstructed Source normals + receiver mask
const float4 LightParams : register(c0); // x = active point-light count

struct PS_INPUT
{
    float2 uv : TEXCOORD0;
};

static const float MAX_POINT_LIGHTS = 32.0;
static const float SOURCE_SKY_DEPTH = 0.00025;

float3 SafeUnpackWorldPos(float3 packedPosition)
{
    float3 signValue = float3(
        packedPosition.x < 0.0 ? -1.0 : (packedPosition.x > 0.0 ? 1.0 : 0.0),
        packedPosition.y < 0.0 ? -1.0 : (packedPosition.y > 0.0 ? 1.0 : 0.0),
        packedPosition.z < 0.0 ? -1.0 : (packedPosition.z > 0.0 ? 1.0 : 0.0)
    );
    return signValue / max(abs(packedPosition),
        float3(0.000001, 0.000001, 0.000001));
}

float4 main(PS_INPUT input) : COLOR0
{
    float2 uv = saturate(input.uv);
    float4 worldPositionDepth = tex2Dlod(SourceWorldPositionBuffer, float4(uv, 0, 0));
    float4 capturedModelNormal = tex2Dlod(SourceModelNormalBuffer, float4(uv, 0, 0));
    float4 receiverNormal = tex2Dlod(SourceReceiverNormalBuffer, float4(uv, 0, 0));

    // Match the actual Source deferred pass: only visible Source pixels with
    // an NKM receiver behind them participate. Use the captured bump/skinned
    // normal when present; ordinary props and materials without a bump map
    // fall back to GShader's reconstructed per-pixel geometric normal.
    if (worldPositionDepth.a <= SOURCE_SKY_DEPTH || receiverNormal.b < 0.5)
        return float4(0.0, 0.0, 0.0, 1.0);

    float3 worldPosition = SafeUnpackWorldPos(worldPositionDepth.rgb);
    float3 worldNormal = capturedModelNormal.b >= 0.5
        ? Decode(capturedModelNormal.rg)
        : Decode(receiverNormal.rg);
    float maxDiffuse = 0.0;

    int lightCount = (int)clamp(LightParams.x, 0.0, MAX_POINT_LIGHTS);
    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; ++lightIndex)
    {
        float lutV = ((float)lightIndex + 0.5) / MAX_POINT_LIGHTS;
        float4 positionRadius = tex2Dlod(DynamicLightBuffer, float4(0.25, lutV, 0, 0));
        float4 colorShadow = tex2Dlod(DynamicLightBuffer, float4(0.75, lutV, 0, 0));

        // Ignore empty LUT slots, but deliberately do not test distance/radius.
        if (positionRadius.w <= 1.0
            || dot(colorShadow.rgb, float3(0.2126, 0.7152, 0.0722)) <= 0.0001)
            continue;

        float3 toLight = positionRadius.xyz - worldPosition;
        float distanceSqr = dot(toLight, toLight);
        if (distanceSqr <= 0.000001)
            continue;

        float3 lightDirection = toLight * rsqrt(distanceSqr);
        maxDiffuse = max(maxDiffuse, saturate(dot(worldNormal, lightDirection)));
    }

    return float4(maxDiffuse, maxDiffuse, maxDiffuse, 1.0);
}
