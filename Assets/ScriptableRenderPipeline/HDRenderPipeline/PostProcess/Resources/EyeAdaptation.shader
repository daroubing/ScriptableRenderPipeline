Shader "Hidden/HDRenderPipeline/EyeAdaptation"
{
    Properties
    {
        _MainTex("Texture", any) = "" {}
    }

    HLSLINCLUDE

        #pragma target 4.5
        #include "ShaderLibrary/Common.hlsl"
        #include "HDRenderPipeline/ShaderVariables.hlsl"
        #include "EyeAdaptation.hlsl"

        TEXTURE2D(_MainTex);
        SAMPLER2D(sampler_MainTex);

        float4 _Params; // x: lowPercent, y: highPercent, z: minBrightness, w: maxBrightness
        float2 _Speed; // x: down, y: up
        float4 _ScaleOffsetRes; // x: scale, y: offset, w: histogram pass width, h: histogram pass height
        float _ExposureCompensation;

        StructuredBuffer<uint> _Histogram;

        float GetBinValue(uint index, float maxHistogramValue)
        {
            return float(_Histogram[index]) * maxHistogramValue;
        }

        float FindMaxHistogramValue()
        {
            uint maxValue = 0u;

            for (uint i = 0; i < HISTOGRAM_BINS; i++)
            {
                uint h = _Histogram[i];
                maxValue = max(maxValue, h);
            }

            return float(maxValue);
        }

        void FilterLuminance(uint i, float maxHistogramValue, inout float4 filter)
        {
            float binValue = GetBinValue(i, maxHistogramValue);

            // Filter dark areas
            float offset = min(filter.z, binValue);
            binValue -= offset;
            filter.zw -= offset.xx;

            // Filter highlights
            binValue = min(filter.w, binValue);
            filter.w -= binValue;

            // Luminance at the bin
            float luminance = GetLuminanceFromHistogramBin(float(i) / float(HISTOGRAM_BINS), _ScaleOffsetRes.xy);

            filter.xy += float2(luminance * binValue, binValue);
        }

        float GetAverageLuminance(float maxHistogramValue)
        {
            // Sum of all bins
            uint i;
            float totalSum = 0.0;

            [loop]
            for (i = 0; i < HISTOGRAM_BINS; i++)
                totalSum += GetBinValue(i, maxHistogramValue);

            // Skip darker and lighter parts of the histogram to stabilize the auto exposure
            // x: filtered sum
            // y: accumulator
            // zw: fractions
            float4 filter = float4(0.0, 0.0, totalSum * _Params.xy);

            [loop]
            for (i = 0; i < HISTOGRAM_BINS; i++)
                FilterLuminance(i, maxHistogramValue, filter);

            // Clamp to user brightness range
            return clamp(filter.x / max(filter.y, 1.0e-4), _Params.z, _Params.w);
        }

        float GetExposureMultiplier(float avgLuminance)
        {
            avgLuminance = max(1.0e-4, avgLuminance);

            //half keyValue = 1.03 - (2.0 / (2.0 + log2(avgLuminance + 1.0)));
            half keyValue = _ExposureCompensation;
            half exposure = keyValue / avgLuminance;

            return exposure;
        }

        float InterpolateExposure(float newExposure, float oldExposure)
        {
            float delta = newExposure - oldExposure;
            float speed = delta > 0.0 ? _Speed.x : _Speed.y;
            float exposure = oldExposure + delta * (1.0 - exp2(-unity_DeltaTime.x * speed));
            //float exposure = oldExposure + delta * (unity_DeltaTime.x * speed);
            return exposure;
        }

        struct Attributes
        {
            float4 vertex : POSITION;
            float4 texcoord : TEXCOORD0;
        };

        struct Varyings
        {
            float4 pos : SV_POSITION;
            float2 uv : TEXCOORD0;
        };

        Varyings Vert(Attributes v)
        {
            Varyings o;
            o.pos = TransformWorldToHClip(v.vertex.xyz);
            o.uv = v.texcoord.xy;
            return o;
        }

        float4 FragAdaptProgressive(Varyings i) : SV_Target
        {
            float maxValue = 1.0 / FindMaxHistogramValue();
            float avgLuminance = GetAverageLuminance(maxValue);
            float exposure = GetExposureMultiplier(avgLuminance);
            float prevExposure = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, (0.5).xx).r;
            exposure = InterpolateExposure(exposure, prevExposure);
            return exposure.xxxx;
        }

        float4 FragAdaptFixed(Varyings i) : SV_Target
        {
            float maxValue = 1.0 / FindMaxHistogramValue();
            float avgLuminance = GetAverageLuminance(maxValue);
            float exposure = GetExposureMultiplier(avgLuminance);
            return exposure.xxxx;
        }

        // Editor stuff (histogram debug visualization)
        int _DebugWidth;

        struct VaryingsEditorHisto
        {
            float4 pos : SV_POSITION;
            float2 uv : TEXCOORD0;
            float maxValue : TEXCOORD1;
            float avgLuminance : TEXCOORD2;
        };

        VaryingsEditorHisto VertEditorHisto(Attributes v)
        {
            VaryingsEditorHisto o;
            o.pos = TransformWorldToHClip(v.vertex.xyz);
            o.uv = v.texcoord.xy;
            o.maxValue = 1.0 / FindMaxHistogramValue();
            o.avgLuminance = GetAverageLuminance(o.maxValue);
            return o;
        }

        float4 FragEditorHisto(VaryingsEditorHisto i) : SV_Target
        {
            const float3 kRangeColor = float3(0.05, 0.4, 0.6);
            const float3 kAvgColor = float3(0.8, 0.3, 0.05);

            float4 color = float4(0.0, 0.0, 0.0, 0.7);

            uint ix = (uint)(round(i.uv.x * HISTOGRAM_BINS));
            float bin = saturate(float(_Histogram[ix]) * i.maxValue);
            float fill = step(i.uv.y, bin);

            // Min / max brightness markers
            float luminanceMin = GetHistogramBinFromLuminance(_Params.z, _ScaleOffsetRes.xy);
            float luminanceMax = GetHistogramBinFromLuminance(_Params.w, _ScaleOffsetRes.xy);

            color.rgb += fill.rrr;

            if (i.uv.x > luminanceMin && i.uv.x < luminanceMax)
            {
                color.rgb = fill.rrr * kRangeColor;
                color.rgb += kRangeColor;
            }

            // Current average luminance marker
            float luminanceAvg = GetHistogramBinFromLuminance(i.avgLuminance, _ScaleOffsetRes.xy);
            float avgPx = luminanceAvg * _DebugWidth;

            if (abs(i.pos.x - avgPx) < 2)
                color.rgb = kAvgColor;

            return color;
        }

    ENDHLSL

    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM

                #pragma vertex Vert
                #pragma fragment FragAdaptProgressive

            ENDHLSL
        }

        Pass
        {
            HLSLPROGRAM

                #pragma vertex Vert
                #pragma fragment FragAdaptFixed

            ENDHLSL
        }

        Pass
        {
            HLSLPROGRAM

                #pragma vertex VertEditorHisto
                #pragma fragment FragEditorHisto

            ENDHLSL
        }
    }

    Fallback Off
}