// Packs GShader's reconstructed world normal with a per-pixel Source receiver mask.
// Source depth is reciprocal linear depth: larger values are closer to the camera.

sampler SourceWorldPosBuffer : register(s0); // GShader _rt_WPDepth
sampler NKMWorldPosBuffer    : register(s1); // NKM _rt_NKM_WPDepth
sampler SourceNormalBuffer   : register(s2); // GShader _rt_NormalsTangents

struct PS_INPUT
{
    float2 screenPos : VPOS;
    float2 uv        : TEXCOORD0;
};

static const float SOURCE_SKY_DEPTH = 0.00025;
static const float NKM_DEPTH_EPSILON = 0.0000005;

float4 main(PS_INPUT input) : COLOR0
{
    float2 uv = saturate(input.uv);
    float4 sourcePositionDepth = tex2Dlod(SourceWorldPosBuffer, float4(uv, 0, 0));
    float4 nkmPositionDepth = tex2Dlod(NKMWorldPosBuffer, float4(uv, 0, 0));
    float4 sourceNormal = tex2Dlod(SourceNormalBuffer, float4(uv, 0, 0));

    bool sourceHasGeometry = sourcePositionDepth.a > SOURCE_SKY_DEPTH + 0.0000001;
    bool nkmHasGeometry = nkmPositionDepth.a > SOURCE_SKY_DEPTH + 0.0000001;
    float depthBias = max(NKM_DEPTH_EPSILON, nkmPositionDepth.a * 0.0005);

    // A Source pixel is eligible only if it is actually in front of the NKM
    // surface at this pixel, or if no NKM surface exists here. Coplanar BSP/NKM
    // pixels belong to the NKM pass, avoiding double shading.
    bool sourceIsVisibleReceiver = sourceHasGeometry
        && (!nkmHasGeometry || sourcePositionDepth.a > nkmPositionDepth.a + depthBias);

    // RG retains GShader's per-pixel octahedral world normal; B is receiver mask.
    return float4(sourceNormal.rg, sourceIsVisibleReceiver ? 1.0 : 0.0, 1.0);
}
