// Decode an individual model material's bump map and write a world-space
// octahedral normal. The source depth comparison rejects hidden surfaces.
sampler SourceWorldPositionBuffer : register(s0); // GShader _rt_WPDepth
sampler SourceBumpTexture         : register(s1); // current material's $bumpmap
const float4 BumpCaptureParams    : register(c0); // xy=inverse RT size, z=depth tolerance
const float4 BumpDecodeParams     : register(c1); // x=0 RGB, 1 DXT5nm, 2 ATI2N
const float4 BumpTransformS       : register(c2);
const float4 BumpTransformT       : register(c3);

struct PS_INPUT
{
    float2 screenPos   : VPOS;
    float2 uv          : TEXCOORD0;
    float3 worldPos    : TEXCOORD1;
    float3 worldNormal : TEXCOORD2;
    float clipW        : TEXCOORD3;
};

float2 EncodeWorldNormal(float3 normal)
{
    normal = normalize(normal);
    normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 0.000001);
    if (normal.z < 0.0)
    {
        float2 signs = float2(
            normal.x >= 0.0 ? 1.0 : -1.0,
            normal.y >= 0.0 ? 1.0 : -1.0);
        normal.xy = (1.0 - abs(normal.yx)) * signs;
    }
    return normal.xy * 0.5 + 0.5;
}

float3 DecodeTangentNormal(float4 sampleValue)
{
    float3 normal;
    if (BumpDecodeParams.x > 1.5)
    {
        normal.xy = sampleValue.rg * 2.0 - 1.0;
        normal.z = sqrt(saturate(1.0 - dot(normal.xy, normal.xy)));
    }
    else if (BumpDecodeParams.x > 0.5)
    {
        normal.xy = float2(sampleValue.a, sampleValue.g) * 2.0 - 1.0;
        normal.z = sqrt(saturate(1.0 - dot(normal.xy, normal.xy)));
    }
    else
    {
        normal = sampleValue.rgb * 2.0 - 1.0;
    }
    return normalize(normal);
}

float4 main(PS_INPUT input) : COLOR0
{
    float2 screenUV = input.screenPos * BumpCaptureParams.xy;
    float sceneDepth = tex2Dlod(
        SourceWorldPositionBuffer, float4(screenUV, 0, 0)).a;
    float expectedDepth = 1.0 / max(input.clipW, 0.0001);
    float relativeDepthDelta = abs(sceneDepth - expectedDepth)
        / max(expectedDepth, 0.00025);

    if (sceneDepth <= 0.00025
        || relativeDepthDelta > max(BumpCaptureParams.z, 0.0005))
        clip(-1.0);

    float2 bumpUV = float2(
        dot(float4(input.uv, 1.0, 1.0), BumpTransformS),
        dot(float4(input.uv, 1.0, 1.0), BumpTransformT));
    float4 bumpSample = tex2D(SourceBumpTexture, bumpUV);
    float3 tangentNormal = DecodeTangentNormal(bumpSample);

    float3 dpdx = ddx(input.worldPos);
    float3 dpdy = ddy(input.worldPos);
    float2 duvdx = ddx(bumpUV);
    float2 duvdy = ddy(bumpUV);
    float determinant = duvdx.x * duvdy.y - duvdx.y * duvdy.x;

    float3 geometricNormal = normalize(input.worldNormal);
    float3 worldNormal = geometricNormal;
    if (abs(determinant) > 0.000001)
    {
        float reciprocalDeterminant = 1.0 / determinant;
        float3 tangent = (dpdx * duvdy.y - dpdy * duvdx.y)
            * reciprocalDeterminant;
        float3 bitangent = (-dpdx * duvdy.x + dpdy * duvdx.x)
            * reciprocalDeterminant;

        tangent = normalize(tangent - geometricNormal * dot(geometricNormal, tangent));
        float handedness = dot(cross(geometricNormal, tangent), bitangent) < 0.0
            ? -1.0 : 1.0;
        bitangent = normalize(cross(geometricNormal, tangent)) * handedness;
        worldNormal = normalize(
            tangent * tangentNormal.x
            + bitangent * tangentNormal.y
            + geometricNormal * tangentNormal.z);
    }

    return float4(EncodeWorldNormal(worldNormal), 1.0, 1.0);
}
