// Packs GShader's reconstructed world normal with a per-pixel Source receiver mask.
// Source depth is reciprocal linear depth: larger values are closer to the camera.
// The normal filter is edge-aware: it averages nearby normals only when depth and
// normal direction agree, reducing visible depth-triangle faceting on models.

sampler SourceWorldPosBuffer : register(s0); // GShader _rt_WPDepth
sampler NKMWorldPosBuffer    : register(s1); // NKM _rt_NKM_WPDepth
sampler SourceNormalBuffer   : register(s2); // GShader _rt_NormalsTangents

const float4 SmoothingParams : register(c0); // x=strength, y=relative depth tolerance, z=min normal dot, w=center weight
float2 TexelSize : register(c4);

struct PS_INPUT
{
    float2 screenPos : VPOS;
    float2 uv        : TEXCOORD0;
};

static const float SOURCE_SKY_DEPTH = 0.00025;

float3 DecodeSourceNormal(float2 encoded)
{
    float2 f = encoded * 2.0 - 1.0;
    float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = saturate(-n.z);
    n.xy += n.xy >= 0.0 ? -t : t;
    return normalize(n);
}

float2 OctWrapSourceNormal(float2 value)
{
    float2 signs = float2(value.x >= 0.0 ? 1.0 : -1.0,
                          value.y >= 0.0 ? 1.0 : -1.0);
    return (1.0 - abs(value.yx)) * signs;
}

float2 EncodeSourceNormal(float3 normal)
{
    normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 0.000001);
    normal.xy = normal.z >= 0.0 ? normal.xy : OctWrapSourceNormal(normal.xy);
    return normal.xy * 0.5 + 0.5;
}

float3 SmoothSourceNormal(float2 uv, float4 centerDepth, float3 centerNormal)
{
    float strength = saturate(SmoothingParams.x);
    if (strength <= 0.001 || centerDepth.a <= SOURCE_SKY_DEPTH)
        return centerNormal;

    // Three rings reach farther across low-poly triangle faces. The wider
    // taps make the result visibly smoother than a 1-3 px cleanup filter.
    static const float2 offsets[24] = {
        // Ring 2 px
        float2(-2.0, -2.0), float2( 0.0, -2.0), float2( 2.0, -2.0),
        float2(-2.0,  0.0),                       float2( 2.0,  0.0),
        float2(-2.0,  2.0), float2( 0.0,  2.0), float2( 2.0,  2.0),
        // Ring 7 px
        float2(-7.0, -7.0), float2( 0.0, -7.0), float2( 7.0, -7.0),
        float2(-7.0,  0.0),                       float2( 7.0,  0.0),
        float2(-7.0,  7.0), float2( 0.0,  7.0), float2( 7.0,  7.0),
        // Ring 16 px
        float2(-16.0, -16.0), float2( 0.0, -16.0), float2( 16.0, -16.0),
        float2(-16.0,   0.0),                         float2( 16.0,   0.0),
        float2(-16.0,  16.0), float2( 0.0,  16.0), float2( 16.0,  16.0)
    };
    static const float spatialWeights[24] = {
        1.00, 1.00, 1.00,
        1.00,        1.00,
        1.00, 1.00, 1.00,
        0.65, 0.65, 0.65,
        0.65,        0.65,
        0.65, 0.65, 0.65,
        0.35, 0.35, 0.35,
        0.35,        0.35,
        0.35, 0.35, 0.35
    };

    // A moderately permissive threshold blends polygon facets on a curved
    // surface, while near-perpendicular hard edges remain excluded.
    float minimumNormalDot = saturate(SmoothingParams.z);
    float normalRange = max(1.0 - minimumNormalDot, 0.001);
    float centerWeight = max(SmoothingParams.w, 0.05);

    float3 normalSum = centerNormal * centerWeight;
    float totalWeight = centerWeight;

    [unroll]
    for (int sampleIndex = 0; sampleIndex < 24; ++sampleIndex)
    {
        float2 offset = offsets[sampleIndex];
        float2 sampleUV = saturate(uv + offset * TexelSize);
        float4 sampleDepth = tex2Dlod(SourceWorldPosBuffer, float4(sampleUV, 0, 0));
        if (sampleDepth.a <= SOURCE_SKY_DEPTH)
            continue;

        // Depth tolerance grows with sample radius. This allows depth to change
        // gradually across a sloped mesh without allowing distant background
        // surfaces to bleed through silhouettes.
        float sampleRadius = max(abs(offset.x), abs(offset.y));
        float depthTolerance = max(SmoothingParams.y, 0.001)
            * (1.0 + max(sampleRadius - 1.0, 0.0) * 0.22);
        float relativeDepthDelta = abs(sampleDepth.a - centerDepth.a)
            / max(centerDepth.a, SOURCE_SKY_DEPTH);
        float depthWeight = saturate(1.0 - relativeDepthDelta / depthTolerance);
        if (depthWeight <= 0.001)
            continue;

        float2 sampleEncodedNormal = tex2Dlod(
            SourceNormalBuffer, float4(sampleUV, 0, 0)).rg;
        float3 sampleNormal = DecodeSourceNormal(sampleEncodedNormal);
        float normalAgreement = dot(centerNormal, sampleNormal);
        float normalWeight = saturate(
            (normalAgreement - minimumNormalDot) / normalRange);
        // Linear falloff avoids suppressing too many samples on the same surface.
        if (normalWeight <= 0.001)
            continue;

        float weight = spatialWeights[sampleIndex]
            * depthWeight * normalWeight;
        normalSum += sampleNormal * weight;
        totalWeight += weight;
    }

    float3 filteredNormal = normalize(normalSum / max(totalWeight, 0.001));
    return normalize(lerp(centerNormal, filteredNormal, strength));
}

float4 main(PS_INPUT input) : COLOR0
{
    float2 uv = saturate(input.uv);
    float4 sourcePositionDepth = tex2Dlod(SourceWorldPosBuffer, float4(uv, 0, 0));
    float4 nkmPositionDepth = tex2Dlod(NKMWorldPosBuffer, float4(uv, 0, 0));
    float4 sourceNormal = tex2Dlod(SourceNormalBuffer, float4(uv, 0, 0));

    bool sourceHasGeometry = sourcePositionDepth.a > SOURCE_SKY_DEPTH + 0.0000001;
    bool nkmHasGeometry = nkmPositionDepth.a > SOURCE_SKY_DEPTH + 0.0000001;
    float depthBias = max(0.0000005, nkmPositionDepth.a * 0.0005);

    // A Source pixel is eligible only when an NKM surface is actually behind
    // it at this screen pixel. If no NKM surface exists, leave the Source scene
    // untouched: otherwise the Source pass would also relight ordinary room
    // walls, floors and ceilings which are not NKM receivers.
    // Coplanar BSP/NKM pixels belong to the NKM pass, avoiding double shading.
    bool sourceIsVisibleReceiver = sourceHasGeometry && nkmHasGeometry
        && sourcePositionDepth.a > nkmPositionDepth.a + depthBias;

    float3 centerNormal = DecodeSourceNormal(sourceNormal.rg);
    float3 smoothedNormal = SmoothSourceNormal(uv, sourcePositionDepth, centerNormal);

    // RG remains octahedrally encoded; B remains the receiver-visibility mask.
    return float4(EncodeSourceNormal(smoothedNormal),
        sourceIsVisibleReceiver ? 1.0 : 0.0, 1.0);
}
