package de.quickconnect.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.SystemClock
import java.time.Instant
import java.io.File
import java.net.Inet4Address
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal object NativeLan {
    init { System.loadLibrary("quickconnect") }
    external fun start(ip: String, host: String, port: Int, key: ByteArray): String?
    external fun events(): String?
    external fun stop()
}

enum class Phase { IDLE, STARTING, WAITING, CONNECTED, TRANSFER, RELEASED, STOPPING, ERROR }

data class ConnectionState(
    val phase: Phase = Phase.IDLE,
    val target: String = "",
    val ip: String = "",
    val detail: String = "",
    val log: List<String> = emptyList()
) {
    val active: Boolean get() = phase !in setOf(Phase.IDLE, Phase.ERROR)
}

object ConnectionStateManager {
    private val mutable = MutableStateFlow(ConnectionState())
    val state = mutable.asStateFlow()
    internal fun set(next: ConnectionState) { mutable.value = next }
}

internal data class WifiLink(val network: Network, val ipv4: String)
internal fun LinkProperties.ipv4(): String? = linkAddresses
    .map { it.address }.filterIsInstance<Inet4Address>()
    .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }?.hostAddress

@Suppress("DEPRECATION")
internal fun ConnectivityManager.wifiLink(): WifiLink? {
    val networks = listOfNotNull(activeNetwork) + allNetworks
    return networks.distinct().firstNotNullOfOrNull { network ->
        if (getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true) {
            null
        } else getLinkProperties(network)?.ipv4()?.let { WifiLink(network, it) }
    }
}

class ConnectionService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private var worker: Job? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var runningLink: WifiLink? = null
    private var stopReason: String? = null
    private var startedAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            halt()
            return START_NOT_STICKY
        }
        if (intent?.action != START) {
            if (worker == null) stopSelf()
            return START_NOT_STICKY
        }
        if (worker != null) return START_NOT_STICKY

        val host = intent.getStringExtra("host").orEmpty()
        val port = intent.getIntExtra("port", 0)
        val target = "$host:$port"
        val autoStop = intent.getBooleanExtra("auto", true)
        stopReason = null
        startedAt = SystemClock.elapsedRealtime()
        val history = ConnectionStateManager.state.value.log
        ConnectionStateManager.set(ConnectionState(Phase.STARTING, target = target, log = history))
        appendLog("Verbindungsversuch gestartet.")
        try {
            startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } catch (e: RuntimeException) {
            publish(Phase.ERROR, e.message ?: "Vordergrunddienst konnte nicht starten.")
            stopSelf()
            return START_NOT_STICKY
        }

        // Launch after returning from onStartCommand so worker is assigned even if setup fails.
        worker = scope.launch(Dispatchers.Main) {
            try {
                val link = connectivity.wifiLink() ?: error("Kein WLAN mit lokaler IPv4-Adresse gefunden.")
                runningLink = link
                val current = ConnectionStateManager.state.value
                ConnectionStateManager.set(current.copy(ip = link.ipv4))
                monitor(link)
                multicast = applicationContext.getSystemService(WifiManager::class.java)
                    .createMulticastLock("quickconnect-lan").apply { setReferenceCounted(false); acquire() }
                engineLock.withLock {
                    var started = false
                    try {
                        val failure = withContext(Dispatchers.IO + NonCancellable) {
                            NativeLan.start(link.ipv4, host, port, privateKey()).also { started = it == null }
                        }
                        check(failure == null) { failure.orEmpty() }
                        publish(Phase.WAITING, "NetherNet-LAN-Dienst lauscht auf UDP 7551.")
                        poll(autoStop)
                    } finally {
                        if (started) withContext(Dispatchers.IO + NonCancellable) { NativeLan.stop() }
                    }
                }
                publish(Phase.IDLE, "LAN-Dienst nach der lokalen Übergabe automatisch beendet.")
            } catch (e: CancellationException) {
                val reason = stopReason
                if (reason == null) publish(Phase.IDLE, "LAN-Dienst gestoppt.")
                else publish(Phase.ERROR, reason)
                throw e
            } catch (e: Exception) {
                publish(Phase.ERROR, e.message ?: "LAN-Dienst konnte nicht gestartet werden.")
            } catch (e: LinkageError) {
                publish(Phase.ERROR, "NetherNet-Bibliothek fehlt oder passt nicht zur Gerätearchitektur.")
            } finally {
                releaseNetwork()
                worker = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private suspend fun poll(autoStop: Boolean) {
        while (scope.isActive) {
            delay(250)
            val events = withContext(Dispatchers.IO) { NativeLan.events() }.orEmpty()
            for (event in events.lineSequence()) {
                if (event.startsWith("diagnostic:")) {
                    val state = ConnectionStateManager.state.value
                    if (state.phase == Phase.WAITING || state.phase == Phase.CONNECTED) {
                        publish(state.phase, event.substringAfter(':'), event.substringAfter(':'))
                    }
                    continue
                }
                val next = reduceEvent(event) ?: continue
                if (next.first == Phase.ERROR) error(next.second)
                publish(next.first, next.second, if (event.startsWith("peer-error:")) "Lokaler Beitritt vor dem Transfer abgebrochen." else null)
                if (next.first == Phase.RELEASED && autoStop) return
            }
        }
    }

    private fun monitor(link: WifiLink) {
        val listener = object : ConnectivityManager.NetworkCallback() {
            override fun onLost(network: Network) {
                if (wifiInvalidated(network == link.network, link.ipv4, null)) scope.launch {
                    if (runningLink == link) halt("WLAN-Verbindung verloren. Starte den LAN-Dienst erneut.")
                }
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                if (wifiInvalidated(network == link.network, link.ipv4, properties.ipv4())) scope.launch {
                    if (runningLink == link) halt("WLAN-Adresse geändert. Starte den LAN-Dienst erneut.")
                }
            }
        }
        connectivity.registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), listener
        )
        callback = listener
        check(connectivity.getLinkProperties(link.network)?.ipv4() == link.ipv4) {
            "WLAN-Verbindung hat sich beim Start geändert."
        }
    }

    private fun releaseNetwork() {
        runningLink = null
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
        multicast?.let { if (it.isHeld) it.release() }
        multicast = null
    }

    private fun privateKey(): ByteArray {
        val file = File(noBackupFilesDir, "operator.pk8")
        val atomic = android.util.AtomicFile(file)
        if (file.exists()) return atomic.readFully()
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp384r1"))
        val data = generator.generateKeyPair().private.encoded
        val output = atomic.startWrite()
        try {
            output.write(data)
            atomic.finishWrite(output)
        } catch (e: Exception) {
            atomic.failWrite(output)
            throw e
        }
        return data
    }

    private fun appendLog(message: String) {
        val state = ConnectionStateManager.state.value
        val elapsed = SystemClock.elapsedRealtime() - startedAt
        val entry = "${Instant.now()}  +${elapsed} ms  $message"
        ConnectionStateManager.set(state.copy(log = (state.log + entry).takeLast(80)))
    }

    private fun publish(phase: Phase, detail: String, safeLog: String? = null) {
        val current = ConnectionStateManager.state.value
        ConnectionStateManager.set(current.copy(phase = phase, detail = detail))
        // Use fixed messages here. UI details may contain addresses or raw upstream errors.
        appendLog(safeLog ?: when (phase) {
            Phase.STARTING -> "LAN-Dienst startet."
            Phase.WAITING -> "NetherNet-Discovery auf UDP 7551 bereit."
            Phase.CONNECTED -> "Bedrock-Login abgeschlossen."
            Phase.TRANSFER -> "Transferpaket gesendet."
            Phase.RELEASED -> "Lokale Sitzung geschlossen."
            Phase.STOPPING -> "LAN-Dienst wird beendet."
            Phase.IDLE -> "LAN-Dienst beendet."
            Phase.ERROR -> "LAN-Dienst fehlgeschlagen. Details stehen im Verbindungsstatus."
        })
        if (ConnectionStateManager.state.value.active) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
        }
    }

    private fun halt(reason: String? = null) {
        if (worker == null) { stopSelf(); return }
        if (ConnectionStateManager.state.value.phase == Phase.STOPPING) return
        stopReason = reason
        publish(Phase.STOPPING, "LAN-Dienst wird beendet …")
        worker?.cancel()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "LAN-Verbindung", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 1, Intent(this, javaClass).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE)
        val state = ConnectionStateManager.state.value
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_block)
            .setContentTitle("Bedrock QuickConnect").setContentText(state.detail.ifBlank { state.target })
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Stoppen", stop).build()).build()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private val engineLock = Mutex()
        const val START = "de.quickconnect.START"
        const val STOP = "de.quickconnect.STOP"
        private const val CHANNEL = "quickconnect.lan"
        private const val NOTIFICATION = 7551
        fun start(context: Context, host: String, port: Int, auto: Boolean) {
            context.startForegroundService(Intent(context, ConnectionService::class.java)
                .setAction(START).putExtra("host", host).putExtra("port", port)
                .putExtra("auto", auto))
        }
        fun stop(context: Context) {
            context.startService(Intent(context, ConnectionService::class.java).setAction(STOP))
        }
    }
}

internal fun reduceEvent(event: String): Pair<Phase, String>? = when (event.substringBefore(':')) {
    "connected" -> Phase.CONNECTED to "Ein Bedrock-Client hat sich verbunden."
    "transfer" -> Phase.TRANSFER to "Transferpaket an den Client gesendet: ${event.substringAfter(':')}"
    "released" -> Phase.RELEASED to "Lokale Sitzung beendet. Prüfe den Zielbeitritt in Minecraft."
    "peer-error" -> Phase.WAITING to "Clientverbindung fehlgeschlagen: ${event.substringAfter(':')}"
    "error" -> Phase.ERROR to event.substringAfter(':')
    else -> null
}


internal fun wifiInvalidated(sameNetwork: Boolean, boundIp: String, currentIp: String?): Boolean =
    sameNetwork && boundIp != currentIp



