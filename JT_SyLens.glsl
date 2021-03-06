#version 120
  
/*
  Original Lens Distortion Algorithm from SSontech (Syntheyes)
  http://www.ssontech.com/content/lensalg.htm
  
  r2 is radius squared.
  
  r2 = image_aspect*image_aspect*u*u + v*v
  f = 1 + r2*(k + kcube*sqrt(r2))
  u' = f*u
  v' = f*v
 
*/

// Controls 
uniform float kCoeff, kCube, uShift, vShift;
uniform float chroma_red, chroma_green, chroma_blue;
uniform bool apply_disto;

// Front texture
uniform sampler2D input1;
// Matte
uniform sampler2D input2;

// First texture pixel size and ratio
uniform float adsk_input1_w, adsk_input1_h, adsk_input1_frameratio;

// Output pixel size and ratio
uniform float adsk_result_w, adsk_result_h;

float distortion_f(float r) {
    float f = 1 + (r*r)*(kCoeff + kCube * r);
    return f;
}

// Returns the F multiplier for the passed distorted radius
float inverse_f(float r_distorted)
{
    
    // Build a lookup table on the radius, as a fixed-size table.
    // We will use a vec2 since we will store the F (distortion coefficient at this R)
    // and the result of F*radius
    vec2[48] lut;
    
    // Since out LUT is shader-global check if it's been computed alrite
    // Flame has no overflow bbox so we can safely max out at the image edge, plus some cushion
    float max_r = sqrt((adsk_input1_frameratio * adsk_input1_frameratio) + 1) + 1;
    float incr = max_r / 48;
    float lut_r = 0;
    float f;
    for(int i=0; i < 48; i++) {
        f = distortion_f(lut_r);
        lut[i] = vec2(f, lut_r * f);
        lut_r += incr;
    }
    
    float t;
    // Now find the nehgbouring elements
    // only iterate to 46 since we will need
    // 47 as i+1
    for(int i=0; i < 47; i++) {
        if(lut[i].y < r_distorted && lut[i+1].y > r_distorted) {
            // BAM! our distorted radius is between these two
            // get the T interpolant and mix
            t = (r_distorted - lut[i].y) / (lut[i+1].y - lut[i]).y;
            return mix(lut[i].x, lut[i+1].x, t );
        }
    }
    // Rolled off the edge
    return lut[47].x;
}

float aberrate(float f, float chroma)
{
   return f + (f * chroma);
}

vec3 chromaticize_and_invert(float f)
{
   vec3 rgb_f = vec3(aberrate(f, chroma_red), aberrate(f, chroma_green), aberrate(f, chroma_blue));
   // We need to DIVIDE by F when we redistort, and x / y == x * (1 / y)
   if(apply_disto) {
      rgb_f = 1 / rgb_f;
   }
   return rgb_f;
}

void main(void)
{
   vec2 px, uv;
   float f = 1;
   float r = 1;
   
   px = gl_FragCoord.xy;
   
   // Make sure we are still centered
   // and account for overscan
   px.x -= (adsk_result_w - adsk_input1_w) / 2;
   px.y -= (adsk_result_h - adsk_input1_h) / 2;
   
   // Push the destination coordinates into the [0..1] range
   uv.x = px.x / adsk_input1_w;
   uv.y = px.y / adsk_input1_h;
       
   // And to Syntheyes UV which are [1..-1] on both X and Y
   uv.x = (uv.x *2 ) - 1;
   uv.y = (uv.y *2 ) - 1;

   // Add UV shifts
   uv.x += uShift;
   uv.y += vShift;
   
   // Make the X value the aspect value, so that the X coordinates go to [-aspect..aspect]
   // _frameratio uniform _already_ accounts for non-square pixel size, which is good!
   uv.x = uv.x * adsk_input1_frameratio;
   
   // Compute the radius
   r = sqrt(uv.x*uv.x + uv.y*uv.y);
   
   // If we are redistorting, account for the oversize plate in the input, assume that
   // the input aspect is the same
   if(apply_disto) {
      r = r / (float(adsk_result_w) / float(adsk_input1_w));
      f = inverse_f(r);
   } else {
      f = distortion_f(r);
   }
   
   vec2[3] rgb_uvs = vec2[](uv, uv, uv);
   
   // Compute distortions per component
   vec3 rgb_f = chromaticize_and_invert(f);
   
   // Apply the disto coefficients, per component
   rgb_uvs[0] = rgb_uvs[0] * rgb_f.rr;
   rgb_uvs[1] = rgb_uvs[1] * rgb_f.gg;
   rgb_uvs[2] = rgb_uvs[2] * rgb_f.bb;
   
   // Convert all the UVs back to the texture space, per color component
   for(int i=0; i < 3; i++) {
       uv = rgb_uvs[i];
       
       // Back from [-aspect..aspect] to [-1..1]
       uv.x = uv.x / adsk_input1_frameratio;
       
       // Remove UV shifts
       uv.x -= uShift;
       uv.y -= vShift;
       
       // Back to OGL UV
       uv.x = (uv.x + 1) / 2;
       uv.y = (uv.y + 1) / 2;
       
       rgb_uvs[i] = uv;
   }
   
   // Sample the input plate, per component
   vec4 sampled;
   sampled.r = texture2D(input1, rgb_uvs[0]).r;
   sampled.g = texture2D(input1, rgb_uvs[1]).g;
   sampled.b = texture2D(input1, rgb_uvs[2]).b;
   
   // Alpha from the input2's R channel
   sampled.a = texture2D(input2, rgb_uvs[0]).r;
   
   // and assign to the output
   gl_FragColor.rgba = sampled;
}
