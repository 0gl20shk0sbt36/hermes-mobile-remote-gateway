package ai.ailigent.hermes_mobile

import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.net.Uri
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One engine owns one gateway even when the Activity is removed from recents. */
class HermesApplication : Application() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /**
     * 引擎是不是还"活着"（JNI 还 attach 着）。
     *
     * 2026-10-16 加：包替换（用户升级 App）会让正在启动的 Activity 重建，此时自管的引擎
     * 可能已经 destroy 过；旧实现把这种引擎继续交给新 Activity，FlutterView 布局时会抛
     * `RuntimeException: Cannot execute operation because FlutterJNI is not attached to native`
     * （栈：FlutterJNI.setViewportMetrics ← FlutterView.onSizeChanged）。
     * 现在：引擎销毁时置位，拿引擎时发现已死就重建，并把共享引擎登记进 FlutterEngineCache。
     */
    private var alive = false
    private val engineLifecycle = object : FlutterEngine.EngineLifecycleListener {
        override fun onPreEngineRestart() {}
        override fun onEngineWillDestroy() {
            alive = false
        }
    }

    @Synchronized
    fun getEngine(): FlutterEngine {
        engine?.let {
            if (alive && it.dartExecutor.isExecutingDart) return it
            // 已经销毁/没在跑 Dart：丢掉重建，别把死引擎交给 Activity。
            FlutterEngineCache.getInstance().remove(ENGINE_ID)
            engine = null
            channel = null
        }
        val created = FlutterEngine(this)
        created.addEngineLifecycleListener(engineLifecycle)
        engine = created
        alive = true
        FlutterEngineCache.getInstance().put(ENGINE_ID, created)
        channel = MethodChannel(created.dartExecutor.binaryMessenger, "hermes/background")
        channel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, GatewayService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        observeNetwork()
                        result.success(null)
                    }
                    "update" -> {
                        GatewayService.update(call.argument<String>("status") ?: "متصل")
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, GatewayService::class.java))
                        stopObservingNetwork()
                        result.success(null)
                    }
                    "status" -> {
                        val power = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(mapOf("running" to GatewayService.running,
                            "batteryExempt" to power.isIgnoringBatteryOptimizations(packageName)))
                    }
                    "batterySettings" -> {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("background_service", e.message, null)
            }
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    companion object {
        /** 共享引擎在 FlutterEngineCache 里的 id（供 Activity/Service 复用）。 */
        const val ENGINE_ID = "hermes-gateway-engine"
    }

    private fun observeNetwork() {
        if (networkCallback != null) return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handler.post { channel?.invokeMethod("networkAvailable", null) }
            }
        }
        networkCallback = callback
        (getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).registerDefaultNetworkCallback(callback)
    }

    private fun stopObservingNetwork() {
        networkCallback?.let {
            (getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).unregisterNetworkCallback(it)
        }
        networkCallback = null
    }

    fun serviceStopped() {
        stopObservingNetwork()
        channel?.invokeMethod("stopped", null)
    }
}
