// Realistic candle flame + soft glow, written in HLSL for Unity's Universal Render Pipeline (URP).
// Put it on a Quad (3D Object > Quad) at the wick tip. Unlit, additive, always faces the camera.
//
// Unity always wraps shader code in a small ShaderLab block (Shader / Properties / SubShader / Pass).
// Everything between HLSLPROGRAM and ENDHLSL is plain HLSL.
//
// Look: teardrop outline, white-yellow hot core, yellow -> orange edges,
// faint blue at the base, thin dark wick, soft orange halo.
// It flickers on its own (each candle gets a different phase from its position),
// so the CandleFlicker script is optional. _Flicker and _Bend are still read
// if the script sets them, but _Flicker is clamped so a bad value can't blow it out.
Shader "Custom/CandleFlame"
{
    Properties
    {
        _ColorDim      ("Dim Colour (outer flame)",     Color) = (1.00, 0.36, 0.06, 1)
        _ColorBright   ("Bright Colour (mid flame)",    Color) = (1.00, 0.74, 0.22, 1)
        _CoreColor     ("Hot Core Colour",              Color) = (1.00, 0.96, 0.80, 1)
        _Intensity     ("Intensity",                    Range(0, 8))  = 1.5
        _HaloStrength  ("Halo Strength",                Range(0, 1))  = 0.35
        _BlueBase      ("Blue Base Amount",             Range(0, 1))  = 0.3
        _AutoFlicker   ("Built-in Flicker",             Range(0, 2))  = 1
        _Flicker       ("Flicker (set by CandleFlicker)", Float)      = 1
        _Bend          ("Bend (set by CandleFlicker)",    Range(-1, 1)) = 0
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "Queue"          = "Transparent"
            "RenderType"     = "Transparent"
            "IgnoreProjector" = "True"
        }

        Pass
        {
            Name "CandleFlame"
            Tags { "LightMode" = "UniversalForward" }

            Blend One One      // additive
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _ColorDim;
                float4 _ColorBright;
                float4 _CoreColor;
                float  _Intensity;
                float  _HaloStrength;
                float  _BlueBase;
                float  _AutoFlicker;
                float  _Flicker;
                float  _Bend;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float  seed       : TEXCOORD1;   // per-candle phase so they don't flicker in sync
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;

                // Billboard: rebuild the quad from the camera's right/up axes
                float4x4 o2w   = GetObjectToWorldMatrix();
                float3 centre  = float3(o2w._m03, o2w._m13, o2w._m23);
                float2 scale   = float2(length(float3(o2w._m00, o2w._m10, o2w._m20)),
                                        length(float3(o2w._m01, o2w._m11, o2w._m21)));
                float3 right   = UNITY_MATRIX_V[0].xyz;
                float3 up      = UNITY_MATRIX_V[1].xyz;
                float3 worldPos = centre + right * (IN.positionOS.x * scale.x)
                                         + up    * (IN.positionOS.y * scale.y);

                OUT.positionCS = TransformWorldToHClip(worldPos);
                OUT.uv         = IN.uv;
                OUT.seed       = frac(sin(dot(centre, float3(12.9898, 78.233, 37.719))) * 43758.5453) * 6.2831853;
                return OUT;
            }

            float hash21(float2 p)
            {
                p = frac(p * float2(123.34, 456.21));
                p += dot(p, p + 45.32);
                return frac(p.x * p.y);
            }

            float vnoise(float2 p)
            {
                float2 i = floor(p);
                float2 f = frac(p);
                f = f * f * (3.0 - 2.0 * f);
                float a = hash21(i);
                float b = hash21(i + float2(1, 0));
                float c = hash21(i + float2(0, 1));
                float d = hash21(i + float2(1, 1));
                return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
            }

            float4 frag(Varyings IN) : SV_Target
            {
                // Script value is clamped: it used to scale height AND brightness,
                // so out-of-range values (e.g. 10) turned the flame into a white blob.
                float k  = clamp(_Flicker, 0.8, 1.25);
                float T  = _Time.y;
                float ph = IN.seed;
                float a  = _AutoFlicker;

                // ---- Flicker (small, layered at different speeds) ----
                float heightWobble = 1.0 + a * (0.07 * sin(T * 9.0  + ph)
                                              + 0.05 * sin(T * 17.0 + ph * 1.7)
                                              + 0.03 * sin(T * 29.0 + ph * 2.3));
                float sway  = a * (0.05 * sin(T * 4.7 + ph) + 0.03 * sin(T * 9.3 + ph * 1.3))
                            + _Bend * 0.25;
                float flare = 1.0 + a * 0.06 * sin(T * 13.0 + ph * 0.7);

                // ---- Flame coordinates ----
                float H  = 0.62 * k * heightWobble;                 // flame height in uv units
                float t  = (IN.uv.y - 0.12) / H;                    // 0 at base, 1 at tip
                float tc = saturate(t);
                float x  = (IN.uv.x - 0.5) * 2.0;                   // -1..1 across the quad

                // Tip licks sideways more than the base
                float lick = (vnoise(float2(tc * 2.5 - T * 2.5, ph)) - 0.5) * 0.22 * a;
                x -= (sway + lick) * tc * tc;

                // ---- Teardrop outline: round base, pointed tip ----
                float s     = sin(3.14159265 * pow(tc, 0.55));
                float halfW = 0.30 * pow(max(s, 0.0), 0.9) + 1e-4;
                float r     = abs(x) / halfW;                       // 0 on the axis, 1 at the edge

                float edge = 1.0 - smoothstep(0.35, 1.0, r);        // soft outer edge

                // ---- Heat: hottest in the lower middle, cooler toward the tip ----
                float c    = saturate(1.0 - r);
                c          = c * c * (3.0 - 2.0 * c);
                float heat = pow(c, 1.3) * (1.0 - 0.6 * tc) * smoothstep(0.0, 0.14, tc);

                // Thin dark wick at the bottom of the flame
                float wick = (1.0 - smoothstep(0.0, 0.035, abs(x)))
                           * (1.0 - smoothstep(0.08, 0.22, tc));
                edge *= 1.0 - 0.7 * wick;

                // ---- Colour ramp: orange edge -> yellow -> white-hot core ----
                float3 col = lerp(_ColorDim.rgb, _ColorBright.rgb, smoothstep(0.05, 0.55, heat));
                col        = lerp(col, _CoreColor.rgb,             smoothstep(0.45, 0.95, heat));

                // Faint blue at the outer base of the flame
                float blue = _BlueBase * (1.0 - smoothstep(0.0, 0.3, tc))
                                       * smoothstep(0.25, 0.85, r) * edge;
                col += float3(0.15, 0.35, 1.0) * blue;

                float3 flame = col * edge * flare * _Intensity;

                // ---- Soft halo around the flame (fades to 0 before the quad edge) ----
                float2 hp   = (IN.uv - float2(0.5, 0.12 + H * 0.35)) * 2.0;
                hp.y       *= 0.8;
                float  h2   = dot(hp, hp);
                float  halo = exp(-h2 * 5.0) * (1.0 - smoothstep(0.6, 1.0, sqrt(h2)));
                float3 haloCol = lerp(_ColorDim.rgb, _ColorBright.rgb, 0.4);
                float3 glow = haloCol * halo * _HaloStrength * flare;

                return float4((flame + glow) * sqrt(k), 1.0);
            }
            ENDHLSL
        }
    }
}
