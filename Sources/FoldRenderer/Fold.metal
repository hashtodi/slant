#include <metal_stdlib>
using namespace metal;

struct FoldUniforms {
    float3x3 screenToTexture;
    float    progress;       // 0...1 fold amount
    float    maxMipLevel;
    float    maxBlurRadius;  // in source pixels
    float    maxDim;         // darkening at full fold
    float    blurCurve;      // how blur ramps with fold amount
    float    dimCurve;       // how dim ramps with fold amount
    float    blurSpread;     // how blur is shaped by distance from the hinge
    float    dimSpread;      // how dim is shaped by distance from the hinge
    float    hingeBlurFloor; // blur weight at the hinge (1 = uniform)
    float    hingeDimFloor;  // dim weight at the hinge (1 = uniform)
    float    flipTexture;    // sample the source upside down
    float    flipOutput;     // put the hinge at the top instead of the bottom
    float4   voidColour;     // what sits behind the panel as it tips away
    float    vignette;       // corner darkening at full fold
    float    reduceMotion;   // 1 = fade only, no geometry
    float    rimShare;       // soft rim width, as a share of the wedge beside it
    float    visibleHeight;  // how far up the picture the panel still reaches
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// One oversized triangle covers the screen with no vertex buffer.
vertex VertexOut foldVertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             texture2d<float> picture [[texture(0)]],
                             constant FoldUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler linearSampler(filter::linear,
                                    mip_filter::linear,
                                    address::clamp_to_edge);

    float2 uv = in.uv;
    if (uniforms.flipOutput > 0.5) {
        uv.y = 1.0 - uv.y;
    }

    // Reduce Motion: no geometry, just a gentle fade to the void colour.
    if (uniforms.reduceMotion > 0.5) {
        float2 flat = float2(uv.x, uniforms.flipTexture > 0.5 ? 1.0 - uv.y : uv.y);
        float4 plain = picture.sample(linearSampler, flat, level(0.0));
        return mix(plain, uniforms.voidColour, clamp(uniforms.progress * uniforms.maxDim, 0.0, 1.0));
    }

    // Follow this pixel's line of sight through the panel to the desktop
    // pinned in the plane the screen occupied at the reference angle.
    //
    // Nothing is squeezed here. The desktop keeps its own coordinates; the
    // panel simply looks at a different part of it as it rotates, so the
    // picture narrows toward the top and is cut away from the top, while the
    // hinge edge stays exactly one to one.
    // Sample where this pixel's line of sight lands on the pinned desktop, not
    // where the pixel happens to sit on the panel. That difference is the whole
    // effect: the panel turns, the picture does not.
    //
    // Sampling at the pixel's own coordinate instead would glue the picture to
    // the panel and leave only a shrinking black aperture, which is no illusion
    // at all. Measured against the reference video, the picture holds still in
    // camera space to within 4% while the panel splays 40% wider.
    float3 looked = uniforms.screenToTexture * float3(uv, 1.0);
    float2 texCoord = looked.xy / looked.z;

    // Behind the panel is void, not the desktop.
    //
    // Leaving it transparent shows the real, unfolded desktop through the gap
    // the panel vacates, so a folded copy floats on top of an untouched
    // original and the illusion collapses. Opaque black reads as the screen
    // tipping away into nothing.
    //
    // Only the sides cut across the picture. The hinge row sits exactly at the
    // bottom of the desktop and the top is held in contact with it, so the two
    // horizontal edges never need this. The sides do, and the width of their
    // edge is decided below, once the blur there is known.
    if (texCoord.y < 0.0 || texCoord.y > uniforms.visibleHeight) {
        return uniforms.voidColour;
    }

    // Blur and dim: a static gradient keyed to distance from the hinge,
    // scaled by the fold amount through its own curve.
    //
    // This still reads as the softness filling downward from the top, because
    // the top carries the most weight and the whole field deepens as the lid
    // closes. An earlier version swept an explicit boundary down the screen;
    // no competitor does that, and it paced badly — the top edge reached
    // maximum blur by half fold, long before the lid was anywhere near shut.
    //
    // The floors are what keep the picture intact at the hinge, the way it
    // stays intact at the crease of a folding phone.
    float fromHinge = clamp(uv.y, 0.0, 1.0);

    float blurRamp = pow(clamp(uniforms.progress, 0.0, 1.0), uniforms.blurCurve);
    float blurShape = mix(uniforms.hingeBlurFloor, 1.0, pow(fromHinge, uniforms.blurSpread));
    float blurRadius = uniforms.maxBlurRadius * blurRamp * blurShape;

    float dimRamp = pow(clamp(uniforms.progress, 0.0, 1.0), uniforms.dimCurve);
    float dimShape = mix(uniforms.hingeDimFloor, 1.0, pow(fromHinge, uniforms.dimSpread));
    float dimAmount = uniforms.maxDim * dimRamp * dimShape;

    // Magnifying the picture to fill a foreshortened panel resamples it above
    // one source pixel per screen pixel, and the field does not correct that —
    // it hides it. DhananjayBhosale/MacDuo (MIT) floors its blur on the same
    // quantity: `max(sigma, 0.5 * max(0, rayScale - 1) / height)`. fwidth is
    // source pixels per screen pixel, so below one we are magnifying.
    float2 pictureSize = float2(picture.get_width(), picture.get_height());
    float2 sourcePerPixel = fwidth(texCoord) * pictureSize;
    float magnification = 1.0 / max(sourcePerPixel.y, 1e-4);
    blurRadius = max(blurRadius, 0.5 * max(0.0, magnification - 1.0));

    // Feather the exposed sides across the blur that is already there, rather
    // than cutting a sharp trapezoid out of a soft picture — MacDuo again,
    // which ties its border to the blur sigma and calls it exactly that. One
    // pixel is the floor, for when there is no blur yet to hide behind.
    // The rim is a share of the void beside it, measured at this height.
    //
    // In the reference video it holds 0.18 of the local wedge across every
    // frame and every height — widest at the top, gone at the hinge, growing
    // with the bend. It tracks the geometry, so it is derived from the
    // geometry: the row's texture span says how far past the picture this row
    // reaches, and half of the excess is the wedge on each side.
    //
    // It was tied to the blur radius before, which made it a side-effect of a
    // look control. Turning blur down removed it — and it is not decoration. A
    // crisp converging outline reads as a slanted plane; softening it turns the
    // boundary into an occlusion, and the picture's own undistorted content is
    // then what says the surface is upright.
    //
    // Centred on the edge, not inside it, so the boundary softens without
    // moving.
    float3 rowLeft  = uniforms.screenToTexture * float3(0.0, uv.y, 1.0);
    float3 rowRight = uniforms.screenToTexture * float3(1.0, uv.y, 1.0);
    float rowSpan = rowRight.x / rowRight.z - rowLeft.x / rowLeft.z;
    float wedge = max(0.0, (rowSpan - 1.0) * 0.5);
    float edgeWidth = max(uniforms.rimShare * wedge, fwidth(texCoord).x);
    float coverage = smoothstep(-edgeWidth, edgeWidth, texCoord.x)
                   * smoothstep(-edgeWidth, edgeWidth, 1.0 - texCoord.x);
    if (coverage <= 0.0) {
        return uniforms.voidColour;
    }

    float mipLevel = clamp(log2(max(blurRadius, 1.0)), 0.0, uniforms.maxMipLevel);

    float2 sampleAt = texCoord;
    if (uniforms.flipTexture > 0.5) {
        sampleAt.y = 1.0 - sampleAt.y;
    }

    float4 colour = picture.sample(linearSampler, sampleAt, level(mipLevel));

    // Straight multiply. Applying a 2.2 gamma here darkened far too fast —
    // it drove the panel to near-black by half fold.
    colour.rgb *= (1.0 - dimAmount);

    // A little corner falloff stops the panel reading as a flat cut-out.
    float2 fromCentre = abs(texCoord - 0.5) * 2.0;
    float corner = clamp(max(fromCentre.x, fromCentre.y), 0.0, 1.0);
    colour.rgb *= 1.0 - uniforms.vignette * corner * corner;

    colour.rgb = mix(uniforms.voidColour.rgb, colour.rgb, coverage);
    colour.a = 1.0;
    return colour;
}
