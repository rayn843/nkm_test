#include "common_octahedron_encoding.h"

sampler NKMWorldPosBuffer : register(s0);
sampler NKMNormalBuffer   : register(s1);
sampler DynamicLightBuffer: register(s2);

const float4 LightParams : register(c0); // x = active point-light count

struct PS_INPUT {
    float2 P  : VPOS;
    float2 uv : TEXCOORD0;
};

static const float MAX_POINT_LIGHTS = 32.0;

float4 main(PS_INPUT frag) : COLOR0 {
    float2 uv = saturate(frag.uv);
    float4 inverseWorldPosition = tex2Dlod(NKMWorldPosBuffer, float4(uv, 0, 0));

    // The NKM WP buffer stores reciprocal linear depth in alpha.
    if (inverseWorldPosition.a <= 0.000251) {
        discard;
    }

    float3 worldPosition = 1.0 / inverseWorldPosition.rgb;
    float2 packedNormal = tex2Dlod(NKMNormalBuffer, float4(uv, 0, 0)).xy;
    float3 worldNormal = Decode(packedNormal);

    float3 directLight = float3(0.0, 0.0, 0.0);
    int lightCount = (int)clamp(LightParams.x, 0.0, MAX_POINT_LIGHTS);

    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; ++lightIndex) {
        float lutV = ((float)lightIndex + 0.5) / MAX_POINT_LIGHTS;
        float4 positionRadius = tex2Dlod(DynamicLightBuffer, float4(0.25, lutV, 0, 0));
        float4 colorShadow = tex2Dlod(DynamicLightBuffer, float4(0.75, lutV, 0, 0));

        float3 toLight = positionRadius.xyz - worldPosition;
        float distanceToLight = length(toLight);
        float radius = max(positionRadius.w, 1.0);
        if (distanceToLight <= 0.001 || distanceToLight >= radius)
            continue;

        float3 lightDirection = toLight / distanceToLight;
        float diffuse = saturate(dot(worldNormal, lightDirection));
        if (diffuse <= 0.0001)
            continue;

        float remaining = saturate(1.0 - distanceToLight / radius);
        float attenuation = remaining * remaining;
        directLight += colorShadow.rgb * diffuse * attenuation * 0.85;
    }

    // Soft tone mapping keeps HDR-like contributions visible in an 8-bit
    // diagnostic target without clipping the brightest light colors.
    float3 debugColor = 1.0 - exp(-max(directLight, 0.0));
    return float4(debugColor, 1.0);
}
