// NKM-specific GShader normal reconstruction.
//
// The stock GShader shader derives UVs from VPOS * TexBaseSize. That path
// produced a flat +Z normal in NKM's dynamically rendered reconstruction pass.
// This variant uses the interpolated screen UV and its pixel derivatives,
// matching the UV basis validated by the NKM world-position diagnostics.
#include "common_octahedron_encoding.h"

sampler BASETEXTURE       : register(s0);
sampler SourceWorldPosBuffer : register(s1);
sampler WPDepthBuffer     : register(s2);

struct PS_INPUT {
    float2 P         : VPOS;
    float2 uv        : TEXCOORD0;
    float3 fogParams : TEXCOORD1;
};

float3 getWorldPosition(float2 uv) {
    float3 inverseWorldPosition = tex2Dlod(
        WPDepthBuffer, float4(uv, 0, 0)
    ).rgb;
    return 1.0 / inverseWorldPosition;
}

float4 main(PS_INPUT frag) : COLOR0 {
    // Use the same interpolated UV basis that passed the NKM sampler-s2 test.
    float2 uv = saturate(frag.uv);
    float4 center = tex2Dlod(WPDepthBuffer, float4(uv, 0, 0));

    // GShader stores reciprocal linear depth in alpha; this is its sky value.
    if (center.a <= 0.000251) {
        discard;
    }

    // Derive the one-pixel screen-space offsets from the actual quad UVs.
    float2 pixelStepX = ddx(uv);
    float2 pixelStepY = ddy(uv);

    float3 positionLeft  = getWorldPosition(uv - pixelStepX);
    float3 positionRight = getWorldPosition(uv + pixelStepX);
    float3 positionDown  = getWorldPosition(uv - pixelStepY);
    float3 positionUp    = getWorldPosition(uv + pixelStepY);

    // Match GShader's 4-tap cross-product orientation. The debug panel 9
    // uses this same operation and displays +Z as blue.
    float3 horizontalDerivative = positionRight - positionLeft;
    float3 verticalDerivative = positionUp - positionDown;
    float3 worldNormal = -cross(horizontalDerivative, verticalDerivative);

    float normalLengthSquared = dot(worldNormal, worldNormal);
    if (normalLengthSquared > 1e-12) {
        worldNormal *= rsqrt(normalLengthSquared);
    } else {
        worldNormal = float3(0.0, 0.0, 1.0);
    }

    // Compare the separately reconstructed NKM surface against the visible
    // Source/GShader surface at the same screen pixel. Reciprocal linear depth
    // is larger for nearer surfaces. Keep NKM when depths tie (for coplanar
    // host-BSP overlays), but reject its lighting receiver when Source is in front.
    float sourceDepth = tex2Dlod(SourceWorldPosBuffer, float4(uv, 0, 0)).a;
    bool sourceIsGeometry = sourceDepth > 0.000251;
    bool sourceOccludesNKM = sourceIsGeometry && sourceDepth > center.a + 0.0000005;
    float receiverVisible = sourceOccludesNKM ? 0.0 : 1.0;

    // RG contains the GShader octahedral normal. B is the NKM-visible receiver
    // mask consumed by the deferred lighting pass; alpha remains opaque.
    return float4(Encode(worldNormal), receiverVisible, 1.0);
}
