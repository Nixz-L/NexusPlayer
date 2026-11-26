package com.nexus.nexus_player

import android.Manifest
import android.content.ContentUris
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "com.nexus.nexus_player/media"
    private val permissionRequestCode = 4107
    private val notificationPermissionRequestCode = 4108
    private var notificationPermissionAsked = false
    private lateinit var playbackChannel: MethodChannel
    private var pendingResult: MethodChannel.Result? = null
    private lateinit var mediaChannel: MethodChannel

    private val ioExecutor = Executors.newFixedThreadPool(2)
    private val mainHandler = Handler(Looper.getMainLooper())

    // Cache de capas em memoria (16 MB). ByteArray vazio = faixa sem capa.
    private val coverCache = object : LruCache<String, ByteArray>(16 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ByteArray): Int = maxOf(1, value.size)
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33 || notificationPermissionAsked) return
        notificationPermissionAsked = true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequestCode
            )
        }
    }

    override fun onDestroy() {
        // O motor de audio vive neste processo/engine: sem activity, sem musica.
        PlaybackService.actionSink = null
        PlaybackService.stop(applicationContext)
        super.onDestroy()
    }

    private fun audioPermission(): String {
        return if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        mediaChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        )

        playbackChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nexus.nexus_player/playback"
        )

        PlaybackService.actionSink = { action, positionMs ->
            runOnUiThread {
                playbackChannel.invokeMethod(
                    "mediaAction",
                    mapOf("action" to action, "positionMs" to positionMs)
                )
            }
        }

        playbackChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    ensureNotificationPermission()
                    PlaybackService.update(
                        applicationContext,
                        PlaybackData.fromArgs(call.arguments)
                    )
                    result.success(null)
                }
                "stop" -> {
                    PlaybackService.stop(applicationContext)
                    result.success(null)
                }
                "moveToBackground" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        mediaChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAudioTracks" -> {
                    if (pendingResult != null) {
                        result.error("busy", "Permission request already pending", null)
                        return@setMethodCallHandler
                    }

                    val permission = audioPermission()

                    if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
                        result.success(readAudioTracks())
                    } else {
                        pendingResult = result
                        requestPermissions(arrayOf(permission), permissionRequestCode)
                    }
                }
                "getCover" -> {
                    val id = call.argument<String>("id")
                    val size = call.argument<Int>("size") ?: 400
                    if (id == null) {
                        result.error("bad_args", "Missing track id", null)
                        return@setMethodCallHandler
                    }
                    loadCoverAsync(id, size, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun loadCoverAsync(id: String, size: Int, result: MethodChannel.Result) {
        val key = "$id:$size"
        val cached = coverCache.get(key)
        if (cached != null) {
            result.success(if (cached.isEmpty()) null else cached)
            return
        }

        ioExecutor.execute {
            val bytes = loadCover(id, size)
            coverCache.put(key, bytes ?: ByteArray(0))
            mainHandler.post { result.success(bytes) }
        }
    }

    private fun loadCover(id: String, size: Int): ByteArray? {
        if (Build.VERSION.SDK_INT < 29) return null
        return try {
            val trackId = id.toLong()
            val uri = ContentUris.withAppendedId(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                trackId
            )
            val bitmap = contentResolver.loadThumbnail(uri, Size(size, size), null)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 88, stream)
            bitmap.recycle()
            stream.toByteArray()
        } catch (e: Exception) {
            // Faixa sem capa embutida (ou erro de leitura): a UI usa o fallback.
            null
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == permissionRequestCode) {
            val result = pendingResult
            pendingResult = null

            if (grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            ) {
                result?.success(readAudioTracks())
            } else {
                result?.error(
                    "permission_denied",
                    "Audio library permission was denied",
                    null
                )
            }
        }
    }

    private fun readAudioTracks(): List<Map<String, Any?>> {
        val tracks = mutableListOf<Map<String, Any?>>()

        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

        @Suppress("DEPRECATION")
        val dataColumnName = MediaStore.Audio.Media.DATA

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.IS_MUSIC,
            dataColumnName
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC"

        val cursor: Cursor? = contentResolver.query(
            collection,
            projection,
            selection,
            null,
            sortOrder
        )

        cursor?.use {
            val idColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val nameColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val dataColumn = it.getColumnIndexOrThrow(dataColumnName)

            while (it.moveToNext()) {
                val id = it.getLong(idColumn)
                val title = it.getString(titleColumn)
                    ?.takeIf { value -> value.isNotBlank() }
                    ?: it.getString(nameColumn)
                    ?: "Unknown track"

                val artist = it.getString(artistColumn)
                    ?.takeUnless { value -> value == "<unknown>" || value.isBlank() }

                val album = it.getString(albumColumn)
                    ?.takeUnless { value -> value == "<unknown>" || value.isBlank() }

                val duration = it.getLong(durationColumn)
                val contentUri = ContentUris.withAppendedId(collection, id)

                // O MPV abre o caminho do arquivo direto; content:// so como reserva.
                val path = it.getString(dataColumn)?.takeIf { value -> value.isNotBlank() }

                tracks.add(
                    mapOf(
                        "id" to id.toString(),
                        "uri" to (path ?: contentUri.toString()),
                        "title" to title,
                        "artist" to artist,
                        "album" to album,
                        "durationMs" to duration
                    )
                )
            }
        }

        return tracks
    }
}