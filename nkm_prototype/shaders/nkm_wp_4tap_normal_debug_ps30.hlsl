sampler WorldPosInverseBuffer : register(s2);
struct PS_INPUT {
    float2 P : VPOS;
    float2 uv : TEXCOORD0;
};

float3 getWorldPosition(float2 uv) {
    float3 inverseWorldPosition = tex2Dlod(
        WorldPosInverseBuffer, float4(uv, 0, 0)
    ).rgb;
    return 1.0 / inverseWorldPosition;
}

float4 main(PS_INPUT frag) : COLOR0 {
    // Use interpolated screen-quad UVs, as in the working sampler-s2 debug
    // shader. Do not derive the base UV from VPOS in this diagnostic.
    float2 uv = saturate(frag.uv);
    float4 center = tex2Dlod(WorldPosInverseBuffer, float4(uv, 0, 0));

    if (center.a <= 0.000251) {
        discard;
    }

    // Derive the actual one-pixel UV step from the interpolated screen quad.
    // This avoids relying on c4/TexBaseSize, which can be overridden by
    // screenspace_general and otherwise produce large shifted copies.
    float2 pixelStepX = ddx(uv);
    float2 pixelStepY = ddy(uv);

    float2 uvLeft  = uv - pixelStepX;
    float2 uvRight = uv + pixelStepX;
    float2 uvDown  = uv - pixelStepY;
    float2 uvUp    = uv + pixelStepY;

    float3 positionLeft  = getWorldPosition(uvLeft);
    float3 positionRight = getWorldPosition(uvRight);
    float3 positionDown  = getWorldPosition(uvDown);
    float3 positionUp    = getWorldPosition(uvUp);

    float3 horizontalDerivative = positionRight - positionLeft;
    float3 verticalDerivative = positionUp - positionDown;
    float3 normalVector = -cross(horizontalDerivative, verticalDerivative);

    float normalLengthSquared = dot(normalVector, normalVector);
    if (normalLengthSquared > 1e-12) {
        normalVector *= rsqrt(normalLengthSquared);
    } else {
        normalVector = float3(0.0, 0.0, 1.0);
    }

    // Direct XYZ visualization. +Z is (0.5, 0.5, 1.0).
    return float4(normalVector * 0.5 + 0.5, 1.0);
}
