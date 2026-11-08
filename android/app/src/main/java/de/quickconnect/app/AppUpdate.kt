package de.quickconnect.app

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.URL
import javax.net.ssl.HttpsURLConnection

internal class UpdateFileProvider : FileProvider()

internal data class AppUpdate(
    val version: String,
    val versionCode: Long,
    val size: Long,
    val downloadUrl: URL,
) {
    companion object {
        private val repositoryName = Regex("[A-Za-z0-9-]+/[A-Za-z0-9_.-]+")
        private val releaseTag = Regex("""v(\d+\.\d+\.\d+)-build\.(\d+)""")
        private val supportedAbis = setOf("arm64-v8a", "x86_64")
        private val downloadHosts =
            setOf("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com")

        fun find(context: Context, repository: String): AppUpdate? {
            if (!repositoryName.matches(repository)) return null
            val abi = Build.SUPPORTED_ABIS.firstOrNull { it in supportedAbis } ?: return null
            val assetName = "Bedrock-QuickConnect-$abi.apk"
            val installedCode = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode
            val endpoint = URL("https://api.github.com/repos/$repository/releases/latest")
            val release = endpoint.readFrom(setOf("api.github.com")) {
                JSONObject(it.bufferedReader(Charsets.UTF_8).readText())
            }
            val tag = release.optString("tag_name")
            val match = releaseTag.matchEntire(tag) ?: return null
            val (version, build) = match.destructured
            val versionCode = build.toLongOrNull()?.takeIf { it > installedCode } ?: return null
            val assets = release.optJSONArray("assets") ?: return null
            for (index in 0 until assets.length()) {
                val asset = assets.optJSONObject(index) ?: continue
                if (asset.optString("name") != assetName || asset.optString("state") != "uploaded") continue
                val size = asset.optLong("size").takeIf { it in 1..100L * 1024 * 1024 } ?: return null
                return AppUpdate("$version (Build $build)", versionCode, size,
                    URL("https://github.com/$repository/releases/download/$tag/$assetName"))
            }
            return null
        }
    }

    @Suppress("DEPRECATION")
    fun download(context: Context): File {
        val directory = File(context.cacheDir, "updates").apply { mkdirs() }
        val file = File(directory, "Bedrock-QuickConnect.apk")
        var verified = false
        try {
            downloadUrl.readFrom(downloadHosts) { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count == -1) break
                        total += count
                        if (total > size) throw IOException("Die APK ist größer als erwartet.")
                        output.write(buffer, 0, count)
                    }
                    if (total != size) throw IOException("Der APK-Download ist unvollständig.")
                }
            }
            val manager = context.packageManager
            val flags = PackageManager.GET_SIGNING_CERTIFICATES
            val installed = manager.getPackageInfo(context.packageName, flags)
            val apk = manager.getPackageArchiveInfo(file.absolutePath, flags)
            val signers = installed.signingInfo?.apkContentsSigners?.toSet()
            if (apk == null || apk.packageName != context.packageName ||
                apk.longVersionCode != versionCode || apk.longVersionCode <= installed.longVersionCode ||
                signers.isNullOrEmpty() || signers != apk.signingInfo?.apkContentsSigners?.toSet()) {
                throw IOException("Die APK passt bei Version oder Signatur nicht zur installierten App.")
            }
            verified = true
            return file
        } finally {
            if (!verified) file.delete()
        }
    }
}

private fun <T> URL.readFrom(hosts: Set<String>, read: (InputStream) -> T): T {
    var url = this
    repeat(5) {
        if (url.protocol != "https" || url.host !in hosts) {
            throw IOException("Unerwartete Weiterleitung beim GitHub-Download.")
        }
        val connection = url.openConnection() as HttpsURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8_000
            connection.readTimeout = 12_000
            connection.setRequestProperty("User-Agent", "Bedrock-QuickConnect")
            when (val status = connection.responseCode) {
                200 -> return connection.inputStream.use(read)
                301, 302, 303, 307, 308 -> {
                    val location = connection.getHeaderField("Location")
                        ?: throw IOException("Die GitHub-Weiterleitung enthält kein Ziel.")
                    url = URL(url, location)
                }
                else -> throw IOException("GitHub antwortet mit HTTP $status.")
            }
        } finally {
            connection.disconnect()
        }
    }
    throw IOException("Zu viele GitHub-Weiterleitungen.")
}
