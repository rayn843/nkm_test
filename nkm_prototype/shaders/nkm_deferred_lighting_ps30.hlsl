// NKM deferred point lighting + screen-space contact shadows + local AO.
// Built against the GShader-library / Source SDK shader compiler toolchain.
#include "common_octahedron_encoding.h"

// screenspace_general exposes BASETEXTURE + TEXTURE1..TEXTURE3 (s0..s3).
// Keep every production input inside those four material texture slots.
sampler WorldPosBuffer      : register(s0); // NKM _rt_NKM_WPDepth or Source _rt_WPDepth
sampler NormalBuffer        : register(s1); // NKM _rt_NKM_Normals or Source _rt_NormalsTangents
sampler DynamicLightBuffer  : register(s2); // 2x32 RGBA32F NKM point-light LUT
sampler SceneBuffer         : register(s3); // _rt_FullFrameFB

// c0: x=light count, y=AO radius, z=AO strength, w=contact shadows enabled
const float4 NKMParams : register(c0);
// c1: x=screen width, y=screen height
const float4 ScreenParams : register(c1);
// c2: ambient RGB in 0..1
const float4 NKMAmbient : register(c2);
// Four directional lights: direction/intensity followed by color/shadow flag.
const float4 NKMDir0 : register(c3);
const float4 NKMDirColor0 : register(c4);
const float4 NKMDir1 : register(c5);
const float4 NKMDirColor1 : register(c6);
const float4 NKMDir2 : register(c7);
const float4 NKMDirColor2 : register(c8);
const float4 NKMDir3 : register(c9);
const float4 NKMDirColor3 : register(c10);
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

float4 ReadWorldPosDepth(float2 uv)
{
    return tex2Dlod(WorldPosBuffer, float4(uv, 0, 0));
}

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

    // Six short screen-space ray steps against the depth buffer bound for this pass.
    // The NKM pass samples NKM depth; the Source pass samples GShader scene depth.
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

        float sceneDepth = ReadWorldPosDepth(sampleUV).a;
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

float ReadDirectionalVisibility(float3 worldPosition, float3 normal, float3 lightDirection)
{
    if (NKMParams.w < 0.5)
        return 1.0;

    float3 rayOrigin = worldPosition + normal * 2.0;
    static const float NKM_DIRECTIONAL_SHADOW_DISTANCE = 4096.0;
    [unroll]
    for (int stepIndex = 1; stepIndex <= 6; ++stepIndex)
    {
        float t = (float)stepIndex / 7.0;
        float3 sampleWorld = rayOrigin + lightDirection * (NKM_DIRECTIONAL_SHADOW_DISTANCE * t);
        float4 clipPosition = mul(float4(sampleWorld, 1.0), ViewProj);
        if (clipPosition.w <= 0.0001)
            continue;

        float2 ndc = clipPosition.xy / clipPosition.w;
        float2 sampleUV = float2(ndc.x * 0.5 + 0.5, -ndc.y * 0.5 + 0.5);
        if (sampleUV.x <= 0.001 || sampleUV.x >= 0.999 || sampleUV.y <= 0.001 || sampleUV.y >= 0.999)
            continue;

        float sceneDepth = ReadWorldPosDepth(sampleUV).a;
        if (abs(sceneDepth - NKM_SKY_DEPTH) < 0.0000005)
            continue;

        float expectedDepth = 1.0 / clipPosition.w;
        float bias = max(NKM_DEPTH_BIAS, expectedDepth * 0.0125);
        if (sceneDepth > expectedDepth + bias)
            return 0.0;
    }
    return 1.0;
}

float3 EvaluateNKMDirLight(float3 worldPosition, float3 normal, float4 directionIntensity, float4 colorShadow)
{
    if (directionIntensity.w <= 0.0001)
        return float3(0.0, 0.0, 0.0);

    float3 lightDirection = normalize(directionIntensity.xyz);
    float diffuse = saturate(dot(normal, lightDirection));
    if (diffuse <= 0.0001)
        return float3(0.0, 0.0, 0.0);

    float visibility = 1.0;
    if (colorShadow.a > 0.5)
        visibility = ReadDirectionalVisibility(worldPosition, normal, lightDirection);

    return colorShadow.rgb * (diffuse * directionIntensity.w * visibility);
}

float3 CalculateNKMStaticLighting(float3 worldPosition, float3 normal)
{
    float3 lighting = NKMAmbient.rgb;
    lighting += EvaluateNKMDirLight(worldPosition, normal, NKMDir0, NKMDirColor0);
    lighting += EvaluateNKMDirLight(worldPosition, normal, NKMDir1, NKMDirColor1);
    lighting += EvaluateNKMDirLight(worldPosition, normal, NKMDir2, NKMDirColor2);
    lighting += EvaluateNKMDirLight(worldPosition, normal, NKMDir3, NKMDirColor3);
    return saturate(lighting);
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
        float4 neighborDepth = ReadWorldPosDepth(sampleUV);
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

    // The Lua bridge binds NKM buffers for pass 0 and GShader Source buffers for
    // pass 1. Both paths use the same four screenspace_general sampler slots.
    float4 worldPositionDepth = tex2Dlod(WorldPosBuffer, float4(uv, 0, 0));
    if (abs(worldPositionDepth.a - NKM_SKY_DEPTH) < 0.0000005)
        discard;

    float3 worldPosition = SafeUnpackWorldPos(worldPositionDepth.rgb);
    float4 packedNormal = tex2Dlod(NormalBuffer, float4(uv, 0, 0));
    // Both receiver textures store their per-pixel visibility mask in blue.
    if (packedNormal.b < 0.5)
        discard;
    float3 worldNormal = Decode(packedNormal.xy);
    float4 sceneColor = tex2Dlod(SceneBuffer, float4(uv, 0, 0));

    float ao = CalculateLocalAO(uv, worldPosition, worldNormal);
    float3 staticLighting = NKMAmbient.w > 0.5
        ? CalculateNKMStaticLighting(worldPosition, worldNormal)
        : float3(1.0, 1.0, 1.0);
    float3 directLight = CalculateNKMPointLights(worldPosition, worldNormal);
    // NKM pass applies AO and optional static lighting. The full-screen point
    // pass leaves pixels outside lights unchanged and adds only direct light.
    float3 albedoProxy = max(sceneColor.rgb, float3(0.12, 0.12, 0.12));
    float3 outputColor = sceneColor.rgb * ao * staticLighting + directLight * albedoProxy;
    return float4(saturate(outputColor), sceneColor.a);
}
