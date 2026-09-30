package app.delore.android.ui.ghost

import android.content.Context
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import app.delore.android.ui.Palette
import app.delore.android.ui.reduceMotion
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** Native port of React Bits GhostFibers (ogl + GLSL 300 es). */
@Composable
fun GhostFibersBackground(modifier: Modifier = Modifier) {
    val reduce = reduceMotion()
    Box(modifier.fillMaxSize().background(Palette.backgroundDark)) {
        AndroidView(
            factory = { GhostFibersSurface(it) },
            update = { it.setPaused(reduce) },
            modifier = Modifier.fillMaxSize(),
        )
        DisposableEffect(Unit) {
            onDispose { }
        }
    }
}

class GhostFibersSurface(context: Context) : GLSurfaceView(context) {
    private val renderer = GhostFibersRenderer()

    init {
        setEGLContextClientVersion(3)
        setRenderer(renderer)
        renderMode = RENDERMODE_CONTINUOUSLY
        keepScreenOn = false
        isClickable = false
        isFocusable = false
    }

    private var userPaused = false

    fun setPaused(paused: Boolean) {
        userPaused = paused
        renderer.paused = paused
        renderMode = if (paused) RENDERMODE_WHEN_DIRTY else RENDERMODE_CONTINUOUSLY
        if (paused) requestRender()
    }

    override fun onPause() {
        renderer.paused = true
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        renderer.paused = userPaused
        renderMode = if (userPaused) RENDERMODE_WHEN_DIRTY else RENDERMODE_CONTINUOUSLY
    }
}

private class GhostFibersRenderer : GLSurfaceView.Renderer {
    @Volatile var paused = false

    private var program = 0
    private var vao = 0
    private var startNs = 0L
    private var width = 1
    private var height = 1
    private var ready = false

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        val vs = compile(GLES30.GL_VERTEX_SHADER, VERTEX)
        val fs = compile(GLES30.GL_FRAGMENT_SHADER, FRAGMENT)
        if (vs == 0 || fs == 0) return
        program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glBindAttribLocation(program, 0, "position")
        GLES30.glLinkProgram(program)
        val ok = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) {
            Log.e(TAG, GLES30.glGetProgramInfoLog(program))
            return
        }
        val verts = floatArrayOf(-1f, -1f, 3f, -1f, -1f, 3f)
        val buf = ByteBuffer.allocateDirect(verts.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        buf.put(verts).position(0)
        val vbo = IntArray(1)
        val va = IntArray(1)
        GLES30.glGenVertexArrays(1, va, 0)
        GLES30.glGenBuffers(1, vbo, 0)
        vao = va[0]
        GLES30.glBindVertexArray(vao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo[0])
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, verts.size * 4, buf, GLES30.GL_STATIC_DRAW)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 0, 0)
        GLES30.glBindVertexArray(0)
        startNs = System.nanoTime()
        ready = true
        applyStaticUniforms()
    }

    override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
        width = w.coerceAtLeast(1)
        height = h.coerceAtLeast(1)
        GLES30.glViewport(0, 0, width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        if (!ready) {
            GLES30.glClearColor(0.063f, 0.043f, 0.125f, 1f)
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
            return
        }
        GLES30.glUseProgram(program)
        val t = if (paused) 0f else ((System.nanoTime() - startNs) / 1_000_000_000f)
        GLES30.glUniform2f(loc("uResolution"), width.toFloat(), height.toFloat())
        GLES30.glUniform1f(loc("uTime"), t)
        GLES30.glBindVertexArray(vao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
        GLES30.glBindVertexArray(0)
    }

    private fun applyStaticUniforms() {
        GLES30.glUseProgram(program)
        GLES30.glUniform1f(loc("uSpeed"), 0.18f)
        GLES30.glUniform1f(loc("uScale"), 1.85f)
        GLES30.glUniform1f(loc("uRotation"), 0f)
        GLES30.glUniform1f(loc("uRotationSpeed"), 0.16f)
        GLES30.glUniform1f(loc("uLayers"), 4f)
        GLES30.glUniform1f(loc("uWaveAmplitude"), 0.015f)
        GLES30.glUniform1f(loc("uWaveFrequency"), 3f)
        GLES30.glUniform1f(loc("uWaveSpeed"), 0.15f)
        GLES30.glUniform1f(loc("uLayerSpeed"), 0.08f)
        GLES30.glUniform1f(loc("uTwist"), 0.1f)
        GLES30.glUniform1f(loc("uTwistFrequency"), 5f)
        GLES30.glUniform1f(loc("uTwistSpeed"), 1.2f)
        GLES30.glUniform1f(loc("uLineFrequency"), 5f)
        GLES30.glUniform1f(loc("uLineSpacing"), 2f)
        GLES30.glUniform1f(loc("uLineSharpness"), 16f)
        GLES30.glUniform1f(loc("uGlowFalloff"), 10f)
        GLES30.glUniform1f(loc("uGlowIntensity"), 0.58f)
        GLES30.glUniform1f(loc("uBrightness"), 0.82f)
        GLES30.glUniform1f(loc("uBlueBoost"), 1.05f)
        GLES30.glUniform1f(loc("uVignette"), 0.9f)
        GLES30.glUniform1f(loc("uGrain"), 0.04f)
        GLES30.glUniform1f(loc("uLightMode"), 0f)
        GLES30.glUniform3f(loc("uLineColor"), 0.42f, 0.34f, 0.78f)
        GLES30.glUniform3f(loc("uGlowColor"), 0.16f, 0.10f, 0.38f)
    }

    private fun loc(name: String) = GLES30.glGetUniformLocation(program, name)

    private fun compile(type: Int, src: String): Int {
        val id = GLES30.glCreateShader(type)
        GLES30.glShaderSource(id, src)
        GLES30.glCompileShader(id)
        val ok = IntArray(1)
        GLES30.glGetShaderiv(id, GLES30.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            Log.e(TAG, GLES30.glGetShaderInfoLog(id))
            GLES30.glDeleteShader(id)
            return 0
        }
        return id
    }

    companion object {
        private const val TAG = "GhostFibers"
        private const val VERTEX = """#version 300 es
in vec2 position;
void main() {
  gl_Position = vec4(position, 0.0, 1.0);
}
"""
        private const val FRAGMENT = """#version 300 es
precision highp float;

uniform vec2 uResolution;
uniform float uTime;
uniform float uSpeed;
uniform float uScale;
uniform float uRotation;
uniform float uLayers;
uniform float uWaveAmplitude;
uniform float uWaveFrequency;
uniform float uWaveSpeed;
uniform float uLayerSpeed;
uniform float uTwist;
uniform float uTwistFrequency;
uniform float uTwistSpeed;
uniform float uLineFrequency;
uniform float uLineSpacing;
uniform float uLineSharpness;
uniform float uGlowFalloff;
uniform float uGlowIntensity;
uniform float uBrightness;
uniform float uBlueBoost;
uniform float uVignette;
uniform float uGrain;
uniform float uRotationSpeed;
uniform float uLightMode;
uniform vec3 uLineColor;
uniform vec3 uGlowColor;

out vec4 fragColor;

#define MAX_LAYERS 10

mat2 rotate2d(float angle) {
  float sine = sin(angle);
  float cosine = cos(angle);
  return mat2(cosine, -sine, sine, cosine);
}

float grainHash(vec2 point) {
  point = floor(point);
  float hash = 52.9829189 * fract(dot(point, vec2(0.065, 0.005)));
  return fract(hash);
}

float layeredGrain(vec2 fragmentPixel) {
  vec2 point = mod(fragmentPixel + vec2(uTime * 30.0, -uTime * 21.0), 1024.0);
  vec2 rotated = mat2(0.8, -0.5, 0.5, 0.8) * point;
  float grain = 0.0;
  grain += 0.40 * grainHash(rotated);
  grain += 0.25 * grainHash(rotated * 2.0 + 17.0);
  grain += 0.20 * grainHash(rotated * 4.0 + 47.0);
  grain += 0.10 * grainHash(rotated * 8.0 + 113.0);
  grain += 0.05 * grainHash(rotated * 16.0 + 191.0);
  return grain;
}

void main() {
  vec2 resolution = max(uResolution, vec2(1.0));
  vec2 uv = (2.0 * gl_FragCoord.xy - resolution) / resolution.y;
  float time = uTime * uSpeed;
  vec3 backdrop = mix(vec3(0.063, 0.043, 0.125), vec3(1.0), step(0.5, uLightMode));
  vec3 centerTone = max(uLineColor * 0.85567 - uGlowColor * 0.06186, vec3(0.0));
  vec3 cloudTone = uLineColor * 0.19588 + uGlowColor * 0.2268;
  vec2 p = uv;
  p /= max(uScale, 0.05);
  p = rotate2d(radians(uRotation) + time * uRotationSpeed) * p;
  vec3 color = vec3(0.0);
  float fiberField = 0.0;

  for (int index = 0; index < MAX_LAYERS; index++) {
    float fi = float(index) + 1.0;
    if (fi > uLayers) break;

    p += uWaveAmplitude * sin(p.yx * fi * uWaveFrequency + time * (uWaveSpeed + fi * uLayerSpeed));

    float radius = length(p);
    float polarAngle = atan(p.y, p.x);
    polarAngle += sin(radius * uTwistFrequency - time * uTwistSpeed + fi) * uTwist;
    p = vec2(cos(polarAngle), sin(polarAngle)) * radius;

    float lines = abs(sin(p.x * (uLineFrequency + fi * uLineSpacing) + sin(p.y * 3.0 + time)));
    lines = pow(max(0.0, 1.0 - lines), uLineSharpness);
    fiberField += lines / fi;
    color += uLineColor * lines / fi;

    float glow = exp(-uGlowFalloff * abs(sin(p.x * 3.0 + time + fi)));
    color += uGlowColor * glow * uGlowIntensity / (fi * 2.0);
  }

  float center = exp(-2.2 * dot(uv, uv));
  color += centerTone * center;

  float cloud = exp(-1.5 * length(uv + vec2(sin(time * 0.3) * 0.25, cos(time * 0.25) * 0.18)));
  color += cloudTone * cloud;

  float vignette = 1.0 - smoothstep(0.35, 1.45, length(uv));
  color *= mix(1.0 - uVignette, 1.0, vignette);
  color = 1.0 - exp(-color * uBrightness);
  color.b *= uBlueBoost;

  vec3 outputColor;
  if (uLightMode > 0.5) {
    float edgeFade = mix(1.0 - uVignette, 1.0, vignette);
    float fibers = pow(smoothstep(0.12, 1.05, fiberField) * edgeFade, 1.5);
    float atmosphere = (center * 0.025 + cloud * 0.015) * edgeFade;
    vec3 fiberInk = mix(backdrop, uLineColor, 0.52);
    vec3 airColor = mix(backdrop, uGlowColor, 0.16);

    outputColor = mix(backdrop, airColor, atmosphere);
    outputColor = mix(outputColor, fiberInk, fibers * 0.3);
  } else {
    outputColor = backdrop + color;
  }

  float noise = (layeredGrain(gl_FragCoord.xy) - 0.5) * uGrain;
  outputColor = clamp(outputColor + noise, 0.0, 1.0);
  fragColor = vec4(outputColor, 1.0);
}
"""
    }
}
