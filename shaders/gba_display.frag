#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uBrightness;
uniform float uScanlineStrength;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec2 texCoords = FlutterFragCoord().xy / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  texCoords.y = 1.0 - texCoords.y;
#endif

  vec4 color = texture(uTexture, texCoords);
  color.rgb *= uBrightness;

  if (uScanlineStrength > 0.0) {
    float scanline = sin(FlutterFragCoord().y * 3.14159265 * 0.5) * 0.5 + 0.5;
    color.rgb *= mix(1.0, scanline, uScanlineStrength);
  }

  fragColor = color;
}
