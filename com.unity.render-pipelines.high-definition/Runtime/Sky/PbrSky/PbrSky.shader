Shader "Hidden/HDRP/Sky/RenderPbrSky"
{
    HLSLINCLUDE

    #pragma vertex Vert

    #pragma enable_d3d11_debug_symbols
    #pragma target 4.5
    #pragma only_renderers d3d11 ps4 xboxone vulkan metal switch

    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Sky/PbrSky/PbrSkyCommon.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Sky/SkyUtils.hlsl"

    float4x4 _PixelCoordToViewDirWS; // Actually just 3x3, but Unity can only set 4x4
    float3   _SunDirection;

    struct Attributes
    {
        uint vertexID : SV_VertexID;
        UNITY_VERTEX_INPUT_INSTANCE_ID
    };

    struct Varyings
    {
        float4 positionCS : SV_POSITION;
        UNITY_VERTEX_OUTPUT_STEREO
    };

    Varyings Vert(Attributes input)
    {
        Varyings output;
        UNITY_SETUP_INSTANCE_ID(input);
        UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
        output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID, UNITY_RAW_FAR_CLIP_VALUE);
        return output;
    }

    float4 RenderSky(Varyings input)
    {
        const uint n = PBRSKYCONFIG_IN_SCATTERED_RADIANCE_TABLE_SIZE_W / 2;

        // V points towards the camera. -V points towards the planet.
        float3 L = _SunDirection;
        float3 V = GetSkyViewDirWS(input.positionCS.xy, (float3x3)_PixelCoordToViewDirWS);
        float3 O = _WorldSpaceCameraPos * 0.001; // Convert m to km
        float3 C = _PlanetCenterPosition;
        float3 P = O - C;
        float3 N = normalize(P);
        float  h = max(0, length(P) - _PlanetaryRadius); // Must not be inside the planet

        float3 radiance = 0;

        if (h <= _AtmosphericDepth)
        {
            // We are inside the atmosphere.
        }
        else
        {
            // We are observing the planet from space.
            float t = IntersectAtmosphereFromOutside(-dot(N, V), h);

            if (t >= 0)
            {
                // It's in the view.
                P = (O - C) + t * -V;
                N = normalize(P);
                h = _AtmosphericDepth;
            }
            else
            {
                return float4(radiance, 1);
            }
        }

        float NdotL = dot(N, L);
        float NdotV = dot(N, V);

        float u = MapAerialPerspective(-NdotV, h).x;
        float v = MapAerialPerspective(-NdotV, h).y;
        float s = MapAerialPerspective(-NdotV, h).z;
        float t = MapCosineOfZenithAngle(NdotL);

        // Do we see the ground?
        if (s == 0)
        {
            // Shade the ground.
            const float3 groundBrdf = INV_PI * _GroundAlbedo;
            float3 transm = SampleTransmittanceTexture(-NdotV, h, true);
            radiance += transm * groundBrdf * SampleGroundIrradianceTexture(NdotL);
        }

        return float4(radiance, 1);

        /*

        // Express the view vector in the local space where N and L span the X-Z plane.
        float3x3 frame;

        if (abs(NdotL) < (1 - FLT_EPS))
        {
            frame = GetLocalFrame(N, Orthonormalize(L, N));
        }
        else // (N = ±L)
        {
            // The rotation angle doesn't matter due to the symmetry.
            frame = GetLocalFrame(N);
        }

        float3 localV = mul(V, transpose(frame));

        float k = (n - 1) * MapCosineOfAzimuthAngle(localV); // Index

        const uint zTexSize  = PBRSKYCONFIG_IN_SCATTERED_RADIANCE_TABLE_SIZE_Z;
        const uint zTexCount = PBRSKYCONFIG_IN_SCATTERED_RADIANCE_TABLE_SIZE_W;
        // We have (2 * n) NdotL textures along the Z dimension.
        // We treat them as separate textures (slices) and must NOT leak between them.
        t = clamp(t, 0 - 0.5 * rcp(zTexSize),
                     1 - 0.5 * rcp(zTexSize));

        // Shrink by the 'zTexCount' and offset according to the above/below horizon direction and phiV.
        float w0 = t * rcp(zTexCount) + 0.5 * (1 - s) + 0.5 * (floor(k) * rcp(n));
        float w1 = t * rcp(zTexCount) + 0.5 * (1 - s) + 0.5 * (ceil(k)  * rcp(n));

        radiance += lerp(SAMPLE_TEXTURE3D(_InScatteredRadianceTexture, s_linear_clamp_sampler, float3(u, v, w0)),
                         SAMPLE_TEXTURE3D(_InScatteredRadianceTexture, s_linear_clamp_sampler, float3(u, v, w1)),
                         frac(k)).rgb;

        // return float4(radiance, 1.0);
        return float4(log(radiance+1) / (log(radiance+1) + 1), 1.0);

        */
    }

    float4 FragBaking(Varyings input) : SV_Target
    {
        return RenderSky(input);
    }

    float4 FragRender(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float4 color = RenderSky(input);
        color.rgb *= GetCurrentExposureMultiplier();
        return color;
    }

    ENDHLSL

    SubShader
    {
        Pass
        {
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragBaking
            ENDHLSL

        }

        Pass
        {
            ZWrite Off
            ZTest LEqual
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragRender
            ENDHLSL
        }

    }
    Fallback Off
}
