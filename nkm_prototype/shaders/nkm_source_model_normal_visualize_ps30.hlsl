// Visualize signed world-space normals as readable RGB axes.
// Red = world X, green = world Y, blue = world Z.
// 0 maps to 0.5; -1 maps to 0; +1 maps to 1.
#include "common_octahedron_encoding.h"

sampler EncodedNormalBuffer : register(s0);
float2 TexelSize : register(c4);

struct PS_INPUT
{
    float2 screenPos : VPOS;
    float2 uv : TEXCOORD0;
};

float4 main(PS_INPUT input) : COLOR0
{
    float2 uv = (input.screenPos + 0.5) * TexelSize;
    float4 packedNormal = tex2Dlod(EncodedNormalBuffer, float4(uv, 0, 0));

    // The capture pass clears uncovered pixels to alpha/blue zero and writes
    // blue=1 for valid model-normal fragments.
    if (packedNormal.b < 0.5)
        return float4(0.0, 0.0, 0.0, 1.0);

    float3 worldNormal = Decode(packedNormal.rg);
    return float4(worldNormal * 0.5 + 0.5, 1.0);
}
