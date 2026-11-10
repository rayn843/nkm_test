// Captures Source model vertex normals after the engine's bone skinning step.
// Based on the standard screenspace_general model vertex path.
#include "common_vs_fxc.h"

struct VS_INPUT
{
    float4 vPos        : POSITION;
    float4 vTexCoord   : TEXCOORD0;
    float3 vNormal     : NORMAL0;
};

struct VS_OUTPUT
{
    float4 proj_pos    : POSITION;
    float3 worldNormal : TEXCOORD0;
    float clipW        : TEXCOORD1;
};

VS_OUTPUT main(VS_INPUT vert)
{
    float3 worldPosition;
    float3 worldNormal;
    SkinPositionAndNormal(
        0, vert.vPos, vert.vNormal, 0, 0,
        worldPosition, worldNormal);

    float4 projectedPosition = mul(float4(worldPosition, 1.0), cViewProj);

    VS_OUTPUT output = (VS_OUTPUT)0;
    output.proj_pos = projectedPosition;
    output.worldNormal = normalize(worldNormal);
    // Perspective-correct interpolation of clip W lets the pixel shader
    // reconstruct the reciprocal depth stored in GShader's _rt_WPDepth.
    output.clipW = projectedPosition.w;
    return output;
}
