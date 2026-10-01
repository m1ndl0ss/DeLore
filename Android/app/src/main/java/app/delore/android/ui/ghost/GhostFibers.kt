package app.delore.android.ui.ghost

import android.content.Context
import android.graphics.RuntimeShader
import android.graphics.SurfaceTexture
import android.os.Build
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.util.Log
import android.view.TextureView
import androidx.annotation.RequiresApi
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ShaderBrush
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import app.delore.android.ui.Palette
import app.delore.android.ui.reduceMotion
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Same React Bits GhostFibers shader, drawn by Compose on API 33+ so it cannot
 * be covered by an opaque Compose layer. Older devices keep a TextureView/EGL path.
 */
@Composable
fun GhostFibersBackground(modifier: Modifier = Modifier) {
    val reduce = reduceMotion()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        GhostFibersAgsl(modifier, reduce)
    } else {
        GhostFibersTexture(modifier, reduce)
    }
}

@RequiresApi(Build.VERSION_CODES.TIRAMISU)
@Composable
private fun GhostFibersAgsl(modifier: Modifier, paused: Boolean) {
    val shader = remember {
        runCatching { RuntimeShader(AGSL).also { applyAgslUniforms(it) } }
            .onFailure { Log.e("GhostFibers", "AGSL compile failed", it) }
            .getOrNull()
    }
    var time by remember { mutableFloatStateOf(0f) }
    val startNs = remember { System.nanoTime() }
    LaunchedEffect(paused) {
        if (paused) {
            time = 0f
            return@LaunchedEffect
        }
        while (true) {
            withFrameNanos { ns ->
                time = (ns - startNs).coerceAtLeast(0L) / 1_000_000_000f
            }
        }
    }
    if (shader == null) {
        Box(modifier.fillMaxSize().background(Palette.backgroundDark))
        return
    }
    Canvas(modifier.fillMaxSize()) {
        applyAgslUniforms(shader)
        shader.setFloatUniform("uResolution", size.width, size.height)
        shader.setFloatUniform("uTime", time)
        drawRect(brush = ShaderBrush(shader))
    }
}

@RequiresApi(Build.VERSION_CODES.TIRAMISU)
private fun applyAgslUniforms(shader: RuntimeShader) {
    shader.setFloatUniform("uSpeed", 0.18f)
    shader.setFloatUniform("uScale", 1.85f)
    shader.setFloatUniform("uRotation", 0f)
    shader.setFloatUniform("uRotationSpeed", 0.16f)
    shader.setFloatUniform("uLayers", 4f)
    shader.setFloatUniform("uWaveAmplitude", 0.015f)
    shader.setFloatUniform("uWaveFrequency", 3f)
    shader.setFloatUniform("uWaveSpeed", 0.15f)
    shader.setFloatUniform("uLayerSpeed", 0.08f)
    shader.setFloatUniform("uTwist", 0.1f)
    shader.setFloatUniform("uTwistFrequency", 5f)
    shader.setFloatUniform("uTwistSpeed", 1.2f)
    shader.setFloatUniform("uLineFrequency", 5f)
    shader.setFloatUniform("uLineSpacing", 2f)
    shader.setFloatUniform("uLineSharpness", 16f)
    shader.setFloatUniform("uGlowFalloff", 10f)
    shader.setFloatUniform("uGlowIntensity", 0.58f)
    shader.setFloatUniform("uBrightness", 0.82f)
    shader.setFloatUniform("uBlueBoost", 1.05f)
    shader.setFloatUniform("uVignette", 0.9f)
    shader.setFloatUniform("uGrain", 0.04f)
    shader.setFloatUniform("uLightMode", 0f)
    shader.setFloatUniform("uLineColor", 0.42f, 0.34f, 0.78f)
    shader.setFloatUniform("uGlowColor", 0.16f, 0.10f, 0.38f)
}

@Composable
private fun GhostFibersTexture(modifier: Modifier, reduce: Boolean) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    Box(modifier.fillMaxSize().background(Palette.backgroundDark)) {
        AndroidView(
            factory = { ctx -> GhostFibersTextureView(ctx).also { it.bind(lifecycle) } },
            update = { it.reduceMotion = reduce },
            onRelease = { it.unbind(); it.release() },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

class GhostFibersTextureView(context: Context) : TextureView(context), TextureView.SurfaceTextureListener {
    @Volatile var reduceMotion = false
        set(value) {
            field = value
            paused = value || !resumed
        }

    @Volatile private var paused = false
    @Volatile private var resumed = true
    @Volatile private var running = false
    @Volatile private var widthPx = 1
    @Volatile private var heightPx = 1

    private val renderer = GhostFibersGL()
    private var lifecycle: Lifecycle? = null
    private var thread: Thread? = null
    private val observer = LifecycleEventObserver { _, event ->
        when (event) {
            Lifecycle.Event.ON_RESUME -> {
                resumed = true
                paused = reduceMotion
            }
            Lifecycle.Event.ON_PAUSE -> {
                resumed = false
                paused = true
            }
            else -> Unit
        }
    }

    init {
        isOpaque = true
        isClickable = false
        isFocusable = false
        surfaceTextureListener = this
    }

    fun bind(owner: Lifecycle) {
        lifecycle?.removeObserver(observer)
        lifecycle = owner
        owner.addObserver(observer)
        resumed = owner.currentState.isAtLeast(Lifecycle.State.STARTED)
        paused = reduceMotion || !resumed
    }

    fun unbind() {
        lifecycle?.removeObserver(observer)
        lifecycle = null
    }

    fun release() = stopRenderer()

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (thread != null) return
        if (isAvailable) {
            val texture = surfaceTexture ?: return
            val w = width.coerceAtLeast(1)
            val h = height.coerceAtLeast(1)
            onSurfaceTextureAvailable(texture, w, h)
        }
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, w: Int, h: Int) {
        widthPx = w.coerceAtLeast(1)
        heightPx = h.coerceAtLeast(1)
        if (widthPx < 2 || heightPx < 2) return
        Log.i(TAG, "surface ${widthPx}x${heightPx}")
        startRenderer(surface)
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, w: Int, h: Int) {
        widthPx = w.coerceAtLeast(1)
        heightPx = h.coerceAtLeast(1)
        if (thread == null && widthPx >= 2 && heightPx >= 2) {
            startRenderer(surface)
        } else {
            surface.setDefaultBufferSize(widthPx, heightPx)
        }
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        stopRenderer()
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    private fun startRenderer(texture: SurfaceTexture) {
        stopRenderer()
        running = true
        val startW = widthPx
        val startH = heightPx
        thread = Thread({
            val egl = EglSession()
            if (!egl.attach(texture, startW, startH)) {
                Log.e(TAG, "EGL GLES3 surface failed")
                return@Thread
            }
            renderer.create()
            renderer.resize(startW, startH)
            try {
                while (running && !Thread.currentThread().isInterrupted) {
                    if (widthPx != renderer.width || heightPx != renderer.height) {
                        texture.setDefaultBufferSize(widthPx, heightPx)
                        renderer.resize(widthPx, heightPx)
                    }
                    renderer.draw(paused)
                    if (!egl.swap()) break
                    post { invalidate() }
                    try {
                        Thread.sleep(if (paused) 120 else 16)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            } finally {
                renderer.release()
                egl.release()
            }
        }, "ghost-fibers").also { it.start() }
    }

    private fun stopRenderer() {
        running = false
        thread?.interrupt()
        try {
            thread?.join(2000)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        thread = null
    }

    companion object {
        private const val TAG = "GhostFibers"
    }
}

private class EglSession {
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var surface: EGLSurface = EGL14.EGL_NO_SURFACE

    fun attach(texture: SurfaceTexture, width: Int, height: Int): Boolean {
        texture.setDefaultBufferSize(width.coerceAtLeast(1), height.coerceAtLeast(1))
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return false
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) return false
        EGL14.eglBindAPI(EGL14.EGL_OPENGL_ES_API)
        val config = chooseConfig() ?: return false
        context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE),
            0,
        )
        if (context == EGL14.EGL_NO_CONTEXT) return false
        surface = EGL14.eglCreateWindowSurface(display, config, texture, intArrayOf(EGL14.EGL_NONE), 0)
        if (surface == EGL14.EGL_NO_SURFACE) return false
        return EGL14.eglMakeCurrent(display, surface, surface, context)
    }

    private fun chooseConfig(): EGLConfig? {
        val tries = arrayOf(
            intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            ),
            intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, 0x0040,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_NONE,
            ),
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        for (attribs in tries) {
            if (EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) && n[0] > 0) {
                return configs[0]
            }
        }
        return null
    }

    fun swap(): Boolean {
        if (display == EGL14.EGL_NO_DISPLAY) return false
        return EGL14.eglSwapBuffers(display, surface)
    }

    fun release() {
        if (display == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
        if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
        EGL14.eglTerminate(display)
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        surface = EGL14.EGL_NO_SURFACE
    }
}

private class GhostFibersGL {
    @Volatile var width = 1
        private set
    @Volatile var height = 1
        private set

    private var program = 0
    private var vao = 0
    private var startNs = 0L
    private var ready = false

    fun create() {
        ready = false
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
            Log.e("GhostFibers", GLES30.glGetProgramInfoLog(program))
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

    fun resize(w: Int, h: Int) {
        width = w.coerceAtLeast(1)
        height = h.coerceAtLeast(1)
        GLES30.glViewport(0, 0, width, height)
    }

    fun draw(paused: Boolean) {
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

    fun release() {
        if (program != 0) GLES30.glDeleteProgram(program)
        program = 0
        ready = false
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
            Log.e("GhostFibers", GLES30.glGetShaderInfoLog(id))
            GLES30.glDeleteShader(id)
            return 0
        }
        return id
    }
}

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

private const val AGSL = """
uniform float2 uResolution;
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
uniform float3 uLineColor;
uniform float3 uGlowColor;

float2x2 rotate2d(float angle) {
  float sine = sin(angle);
  float cosine = cos(angle);
  return float2x2(cosine, -sine, sine, cosine);
}

float grainHash(float2 point) {
  point = floor(point);
  float hash = 52.9829189 * fract(dot(point, float2(0.065, 0.005)));
  return fract(hash);
}

float layeredGrain(float2 fragmentPixel, float time) {
  float2 point = mod(fragmentPixel + float2(time * 30.0, -time * 21.0), 1024.0);
  float2 rotated = float2x2(0.8, -0.5, 0.5, 0.8) * point;
  float grain = 0.0;
  grain += 0.40 * grainHash(rotated);
  grain += 0.25 * grainHash(rotated * 2.0 + 17.0);
  grain += 0.20 * grainHash(rotated * 4.0 + 47.0);
  grain += 0.10 * grainHash(rotated * 8.0 + 113.0);
  grain += 0.05 * grainHash(rotated * 16.0 + 191.0);
  return grain;
}

half4 main(float2 fragCoord) {
  float2 resolution = max(uResolution, float2(1.0));
  float2 uv = (2.0 * fragCoord - resolution) / resolution.y;
  float time = uTime * uSpeed;
  float3 backdrop = mix(float3(0.063, 0.043, 0.125), float3(1.0), step(0.5, uLightMode));
  float3 centerTone = max(uLineColor * 0.85567 - uGlowColor * 0.06186, float3(0.0));
  float3 cloudTone = uLineColor * 0.19588 + uGlowColor * 0.2268;
  float2 p = uv;
  p /= max(uScale, 0.05);
  p = rotate2d(radians(uRotation) + time * uRotationSpeed) * p;
  float3 color = float3(0.0);
  float fiberField = 0.0;

  for (int index = 0; index < 10; index++) {
    float fi = float(index) + 1.0;
    if (fi <= uLayers) {
      p += uWaveAmplitude * sin(p.yx * fi * uWaveFrequency + time * (uWaveSpeed + fi * uLayerSpeed));

      float radius = length(p);
      float polarAngle = atan(p.y, p.x);
      polarAngle += sin(radius * uTwistFrequency - time * uTwistSpeed + fi) * uTwist;
      p = float2(cos(polarAngle), sin(polarAngle)) * radius;

      float lines = abs(sin(p.x * (uLineFrequency + fi * uLineSpacing) + sin(p.y * 3.0 + time)));
      lines = pow(max(0.0, 1.0 - lines), uLineSharpness);
      fiberField += lines / fi;
      color += uLineColor * lines / fi;

      float glow = exp(-uGlowFalloff * abs(sin(p.x * 3.0 + time + fi)));
      color += uGlowColor * glow * uGlowIntensity / (fi * 2.0);
    }
  }

  float center = exp(-2.2 * dot(uv, uv));
  color += centerTone * center;

  float cloud = exp(-1.5 * length(uv + float2(sin(time * 0.3) * 0.25, cos(time * 0.25) * 0.18)));
  color += cloudTone * cloud;

  float vignette = 1.0 - smoothstep(0.35, 1.45, length(uv));
  color *= mix(1.0 - uVignette, 1.0, vignette);
  color = 1.0 - exp(-color * uBrightness);
  color.b *= uBlueBoost;

  float3 outputColor;
  if (uLightMode > 0.5) {
    float edgeFade = mix(1.0 - uVignette, 1.0, vignette);
    float fibers = pow(smoothstep(0.12, 1.05, fiberField) * edgeFade, 1.5);
    float atmosphere = (center * 0.025 + cloud * 0.015) * edgeFade;
    float3 fiberInk = mix(backdrop, uLineColor, 0.52);
    float3 airColor = mix(backdrop, uGlowColor, 0.16);

    outputColor = mix(backdrop, airColor, atmosphere);
    outputColor = mix(outputColor, fiberInk, fibers * 0.3);
  } else {
    outputColor = backdrop + color;
  }

  float noise = (layeredGrain(fragCoord, uTime) - 0.5) * uGrain;
  outputColor = saturate(outputColor + noise);
  return half4(outputColor, 1.0);
}
"""
