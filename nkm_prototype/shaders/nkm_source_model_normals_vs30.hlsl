// Captures Source model vertex normals after the engine's bone skinning step.
// Based on the standard screenspace_general model vertex path.
#include "common_vs_fxc.h"

struct VS_INPUT
{
    float4 vPos          : POSITION;
    float4 vBoneWeights  : BLENDWEIGHT;
    float4 vBoneIndices  : BLENDINDICES;
    float4 vTexCoord     : TEXCOORD0;
    float3 vNormal       : NORMAL0;
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
    // screenspace_general does not provide a NUMBONES shader combo, so use
    // the Source SDK's three-influence skinning path. For rigid/unskinned
    // models, zero weights/indices naturally resolve to cModel[0].
    SkinPositionAndNormal(
        3, vert.vPos, vert.vNormal,
        vert.vBoneWeights, vert.vBoneIndices,
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
