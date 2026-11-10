// NKM deferred point lighting + screen-space contact shadows + local AO.
// Built against the GShader-library / Source SDK shader compiler toolchain.
#include "common_octahedron_encoding.h"

sampler WorldPosBuffer       : register(s0); // GShader: _rt_WPDepth
sampler NormalBuffer         : register(s1); // GShader: _rt_NormalsTangents
sampler DynamicLightBuffer   : register(s2); // NKM: 2x32 RGBA32F LUT
sampler SceneBuffer          : register(s3); // GMod screen effect texture

// c0: x=light count, y=AO radius, z=AO strength, w=contact shadows enabled
const float4 NKMParams : register(c0);
// c1: x=screen width, y=screen height
const float4 ScreenParams : register(c1);
// GShader sets this through IMaterial:SetMatrix("$viewprojmat", ...).
const float4x4 ViewProj : register(c11);

static const float NKM_SKY_DEPTH = 0.00025;
static const float NKM_MAX_LIGHTS = 32.0;
static const float NKM_DEPTH_BIAS = 0.000025;

struct PS_INPUT
{
    float2 pPos      : VPOS;
    float2 vTexCoord : TEXCOORD0;
};

float3 SafeUnpackWorldPos(float3 packedPosition)
{
    float3 signValue = float3(
        packedPosition.x < 0.0 ? -1.0 : (packedPosition.x > 0.0 ? 1.0 : 0.0),
        packedPosition.y < 0.0 ? -1.0 : (packedPosition.y > 0.0 ? 1.0 : 0.0),
        packedPosition.z < 0.0 ? -1.0 : (packedPosition.z > 0.0 ? 1.0 : 0.0)
    );
    return signValue / max(abs(packedPosition), float3(0.000001, 0.000001, 0.000001));
}

float ReadContactVisibility(float3 worldPosition, float3 normal, float3 toLight, float lightDistance)
{
    if (NKMParams.w < 0.5 || lightDistance < 8.0)
        return 1.0;

    // Six short screen-space ray steps. The GBuffer includes Source BSP and
    // NKM depth, so BSP walls can block NKM lights without receiving the light.
    float3 rayOrigin = worldPosition + normal * 2.0;
    [unroll]
    for (int stepIndex = 1; stepIndex <= 6; ++stepIndex)
    {
        float t = (float)stepIndex / 7.0;
        float3 sampleWorld = rayOrigin + toLight * t;
        float4 clipPosition = mul(float4(sampleWorld, 1.0), ViewProj);
        if (clipPosition.w <= 0.0001)
            continue;

        float2 ndc = clipPosition.xy / clipPosition.w;
        float2 sampleUV = float2(ndc.x * 0.5 + 0.5, -ndc.y * 0.5 + 0.5);
        if (sampleUV.x <= 0.001 || sampleUV.x >= 0.999 || sampleUV.y <= 0.001 || sampleUV.y >= 0.999)
            continue;

        float sceneDepth = tex2Dlod(WorldPosBuffer, float4(sampleUV, 0, 0)).a;
        if (abs(sceneDepth - NKM_SKY_DEPTH) < 0.0000005)
            continue;

        // GShader stores reciprocal projected W in _rt_WPDepth.a.
        float expectedDepth = 1.0 / clipPosition.w;
        float bias = max(NKM_DEPTH_BIAS, expectedDepth * 0.0125);
        if (sceneDepth > expectedDepth + bias)
            return 0.0;
    }

    return 1.0;
}

float CalculateLocalAO(float2 uv, float3 worldPosition, float3 normal)
{
    if (NKMParams.z <= 0.0001)
        return 1.0;

    float2 pixel = 1.0 / max(ScreenParams.xy, float2(1.0, 1.0));
    static const float2 offsets[8] = {
        float2(-1.0, -1.0), float2(0.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  0.0),                         float2(1.0,  0.0),
        float2(-1.0,  1.0), float2(0.0,  1.0), float2(1.0,  1.0)
    };

    float occlusion = 0.0;
    [unroll]
    for (int sampleIndex = 0; sampleIndex < 8; ++sampleIndex)
    {
        float2 sampleUV = uv + offsets[sampleIndex] * pixel * 2.0;
        float4 neighborDepth = tex2Dlod(WorldPosBuffer, float4(sampleUV, 0, 0));
        if (abs(neighborDepth.a - NKM_SKY_DEPTH) < 0.0000005)
            continue;

        float3 neighborPosition = SafeUnpackWorldPos(neighborDepth.rgb);
        float3 delta = neighborPosition - worldPosition;
        float distanceToNeighbor = length(delta);
        if (distanceToNeighbor < 0.5 || distanceToNeighbor > NKMParams.y)
            continue;

        float facing = dot(normal, delta / max(distanceToNeighbor, 0.0001));
        float rangeWeight = saturate(1.0 - distanceToNeighbor / max(NKMParams.y, 1.0));
        occlusion += saturate((facing - 0.08) * 2.0) * rangeWeight;
    }

    float ao = 1.0 - saturate((occlusion / 8.0) * NKMParams.z * 2.25);
    return ao;
}

float3 CalculateNKMPointLights(float3 worldPosition, float3 normal)
{
    float3 directLight = float3(0.0, 0.0, 0.0);
    int lightCount = (int)clamp(NKMParams.x, 0.0, NKM_MAX_LIGHTS);

    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; ++lightIndex)
    {
        float lutV = ((float)lightIndex + 0.5) / NKM_MAX_LIGHTS;
        float4 positionRadius = tex2Dlod(DynamicLightBuffer, float4(0.25, lutV, 0, 0));
        float4 colorShadow = tex2Dlod(DynamicLightBuffer, float4(0.75, lutV, 0, 0));

        float3 toLight = positionRadius.xyz - worldPosition;
        float distanceToLight = length(toLight);
        float radius = max(positionRadius.w, 1.0);
        if (distanceToLight <= 0.001 || distanceToLight >= radius)
            continue;

        float3 lightDirection = toLight / distanceToLight;
        float diffuse = saturate(dot(normal, lightDirection));
        if (diffuse <= 0.0001)
            continue;

        float remaining = saturate(1.0 - distanceToLight / radius);
        float attenuation = remaining * remaining;
        float visibility = 1.0;
        if (colorShadow.a > 0.5)
            visibility = ReadContactVisibility(worldPosition, normal, toLight, distanceToLight);

        directLight += colorShadow.rgb * (diffuse * attenuation * visibility * 0.85);
    }

    return directLight;
}

float4 main(PS_INPUT input) : COLOR0
{
    float2 uv = input.vTexCoord;
    float4 worldPositionDepth = tex2Dlod(WorldPosBuffer, float4(uv, 0, 0));
    if (abs(worldPositionDepth.a - NKM_SKY_DEPTH) < 0.0000005)
        discard;

    float3 worldPosition = SafeUnpackWorldPos(worldPositionDepth.rgb);
    float3 worldNormal = Decode(tex2Dlod(NormalBuffer, float4(uv, 0, 0)).xy);
    float4 sceneColor = tex2Dlod(SceneBuffer, float4(uv, 0, 0));

    float ao = CalculateLocalAO(uv, worldPosition, worldNormal);
    float3 directLight = CalculateNKMPointLights(worldPosition, worldNormal);
    // The current opaque NKM pass already contains the static vertex bake.
    // Use its color as an albedo proxy, but keep a small floor so a point light
    // can still reach a surface whose baked/static illumination is very dark.
    // A future albedo-only RT pass can remove this approximation.
    float3 albedoProxy = max(sceneColor.rgb, float3(0.12, 0.12, 0.12));
    float3 outputColor = sceneColor.rgb * ao + directLight * albedoProxy;
    return float4(saturate(outputColor), sceneColor.a);
}
