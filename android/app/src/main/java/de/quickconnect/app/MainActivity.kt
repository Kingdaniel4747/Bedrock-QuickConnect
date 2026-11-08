package de.quickconnect.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val Context.favoriteStore by preferencesDataStore("quickconnect")
private val dataKey = stringPreferencesKey("snapshot")
private const val UPDATE_PERMISSION_REQUEST = 101

class MainActivity : FlutterActivity() {
    private var scope: CoroutineScope? = null
    private var subscription: Job? = null
    private var availableUpdate: AppUpdate? = null
    private var updateResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        scope = jobs
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "quickconnect/control").setMethodCallHandler { call, result ->
            jobs.launch {
                try {
                    when (call.method) {
                        "load" -> result.success(applicationContext.favoriteStore.data.first()[dataKey])
                        "save" -> {
                            val payload = requireNotNull(call.argument<String>("json"))
                            applicationContext.favoriteStore.edit { it[dataKey] = payload }
                            result.success(null)
                        }
                        "wifi" -> result.success(getSystemService(ConnectivityManager::class.java).wifiLink()?.ipv4)
                        "notifications" -> {
                            if (Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                                !getPreferences(MODE_PRIVATE).getBoolean("asked_notifications", false)) {
                                getPreferences(MODE_PRIVATE).edit().putBoolean("asked_notifications", true).apply()
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100)
                            }
                            result.success(null)
                        }
                        "start" -> {
                            val host = requireNotNull(call.argument<String>("host"))
                            val port = requireNotNull(call.argument<Int>("port"))
                            require(host.length in 1..253 && host.matches(Regex("[a-zA-Z0-9.-]+")) && port in 1..65535)
                            ConnectionService.start(this@MainActivity, host, port,
                                call.argument<Boolean>("auto") ?: true)
                            result.success(null)
                        }
                        "stop" -> { ConnectionService.stop(this@MainActivity); result.success(null) }
                        "checkUpdate" -> {
                            val repository = requireNotNull(call.argument<String>("repository"))
                            availableUpdate = withContext(Dispatchers.IO) {
                                AppUpdate.find(applicationContext, repository)
                            }
                            result.success(availableUpdate?.version)
                        }
                        "installUpdate" -> {
                            check(updateResult == null) { "Ein Update läuft bereits." }
                            if (packageManager.canRequestPackageInstalls()) {
                                installUpdate(result)
                            } else {
                                startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.fromParts("package", packageName, null)), UPDATE_PERMISSION_REQUEST)
                                updateResult = result
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    result.error("quickconnect", e.message ?: "Android-Aktion fehlgeschlagen.", null)
                }
            }
        }
        EventChannel(messenger, "quickconnect/state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                subscription?.cancel()
                subscription = jobs.launch {
                    ConnectionStateManager.state.collect { state ->
                        events.success(mapOf("phase" to state.phase.name, "active" to state.active,
                            "target" to state.target, "ip" to state.ip, "detail" to state.detail,
                            "log" to state.log))
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                subscription?.cancel()
                subscription = null
            }
        })
    }

    @Deprecated("Uses FlutterActivity's activity result callback for Android's install permission.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != UPDATE_PERMISSION_REQUEST) return
        val result = updateResult ?: return
        updateResult = null
        if (!packageManager.canRequestPackageInstalls()) {
            result.error("update_permission", "Erlaube die Installation aus dieser Quelle für das Update.", null)
            return
        }
        scope?.launch { installUpdate(result) }
    }

    private suspend fun installUpdate(result: MethodChannel.Result) {
        try {
            val update = checkNotNull(availableUpdate) { "Es ist kein Update verfügbar." }
            val apk = withContext(Dispatchers.IO) { update.download(applicationContext) }
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
            startActivity(Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            result.success(null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            result.error("update_install", "Update fehlgeschlagen. ${e.message.orEmpty()}", null)
        }
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "quickconnect/control").setMethodCallHandler(null)
        EventChannel(messenger, "quickconnect/state").setStreamHandler(null)
        scope?.cancel()
        scope = null
        subscription = null
        updateResult = null
        super.cleanUpFlutterEngine(engine)
    }
}

