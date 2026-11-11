// Capture a Source material's tangent-space $bumpmap as a world-space normal.
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
    float4 proj_pos      : POSITION;
    float2 uv            : TEXCOORD0;
    float3 worldPosition : TEXCOORD1;
    float3 worldNormal   : TEXCOORD2;
    float clipW          : TEXCOORD3;
};

VS_OUTPUT main(VS_INPUT vert)
{
    float3 worldPosition;
    float3 worldNormal;
    SkinPositionAndNormal(
        3, vert.vPos, vert.vNormal,
        vert.vBoneWeights, vert.vBoneIndices,
        worldPosition, worldNormal);

    float4 projectedPosition = mul(float4(worldPosition, 1.0), cViewProj);

    VS_OUTPUT output = (VS_OUTPUT)0;
    output.proj_pos = projectedPosition;
    output.uv = vert.vTexCoord.xy;
    output.worldPosition = worldPosition;
    output.worldNormal = normalize(worldNormal);
    output.clipW = projectedPosition.w;
    return output;
}
