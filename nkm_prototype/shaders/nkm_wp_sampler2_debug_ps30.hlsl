sampler WorldPosInverseBuffer : register(s2);

struct PS_INPUT {
    float2 P : VPOS;
    float2 uv : TEXCOORD0;
};

float4 main(PS_INPUT frag) : COLOR0 {
    // Use interpolated screen-quad UVs rather than VPOS. This makes the
    // diagnostic independent of pixel-position origin/viewport conventions.
    float2 uv = saturate(frag.uv);
    float4 inverseWorldPosition = tex2Dlod(WorldPosInverseBuffer, float4(uv, 0, 0));

    // GShader stores reciprocal world position in RGB and reciprocal linear
    // depth in A. Match the world-position diagnostic's sky rejection.
    if (inverseWorldPosition.a <= 0.000251) {
        discard;
    }

    float3 worldPosition = 1.0 / inverseWorldPosition.rgb;
    float3 debugColor = frac(worldPosition * (1.0 / 256.0) + 0.5);
    return float4(debugColor, 1.0);
}
