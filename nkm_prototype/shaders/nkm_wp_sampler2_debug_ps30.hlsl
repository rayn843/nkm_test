sampler WorldPosInverseBuffer : register(s2);
float2 TexBaseSize : register(c4);

struct PS_INPUT {
    float2 P : VPOS;
    float2 uv : TEXCOORD0;
};

float4 main(PS_INPUT frag) : COLOR0 {
    float2 uv = (frag.P + 0.5) * TexBaseSize;
    float4 inverseWorldPosition = tex2Dlod(WorldPosInverseBuffer, float4(uv, 0, 0));

    // Match the world-position diagnostic's sky rejection and color transform.
    if (inverseWorldPosition.a <= 0.000251) {
        discard;
    }

    float3 worldPosition = 1.0 / inverseWorldPosition.rgb;
    float3 debugColor = frac(worldPosition * (1.0 / 256.0) + 0.5);
    return float4(debugColor, 1.0);
}
