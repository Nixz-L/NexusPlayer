package com.nexus.nexus_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

class PlaybackData(
    val trackId: String,
    val title: String,
    val artist: String?,
    val album: String?,
    val durationMs: Long,
    val positionMs: Long,
    val playing: Boolean,
    val cover: ByteArray?
) {
    companion object {
        fun fromArgs(arguments: Any?): PlaybackData {
            val map = arguments as Map<*, *>
            return PlaybackData(
                trackId = map["trackId"] as? String ?: "",
                title = map["title"] as? String ?: "Unknown track",
                artist = map["artist"] as? String,
                album = map["album"] as? String,
                durationMs = (map["durationMs"] as? Number)?.toLong() ?: 0L,
                positionMs = (map["positionMs"] as? Number)?.toLong() ?: 0L,
                playing = map["playing"] as? Boolean ?: false,
                cover = map["cover"] as? ByteArray
            )
        }
    }
}

class PlaybackService : Service() {

    companion object {
        private const val CHANNEL_ID = "nexus_playback"
        private const val NOTIFICATION_ID = 4210

        const val ACTION_TOGGLE = "com.nexus.nexus_player.action.TOGGLE"
        const val ACTION_PREVIOUS = "com.nexus.nexus_player.action.PREVIOUS"
        const val ACTION_NEXT = "com.nexus.nexus_player.action.NEXT"
        const val ACTION_CLOSE = "com.nexus.nexus_player.action.CLOSE"

        @Volatile private var instance: PlaybackService? = null
        @Volatile private var pendingData: PlaybackData? = null

        // Definido pela MainActivity: repassa cliques da notificacao ao Flutter.
        var actionSink: ((String, Long?) -> Unit)? = null

        fun update(context: Context, data: PlaybackData) {
            val running = instance
            if (running != null) {
                running.render(data)
                return
            }
            pendingData = data
            try {
                val intent = Intent(context, PlaybackService::class.java)
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                pendingData = null
            }
        }

        fun stop(context: Context) {
            pendingData = null
            val running = instance
            if (running != null) {
                running.shutdown()
            } else {
                context.stopService(Intent(context, PlaybackService::class.java))
            }
        }
    }

    private lateinit var session: MediaSession
    private var current: PlaybackData? = null
    private var currentTrackId: String? = null
    private var bitmap: Bitmap? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()

        session = MediaSession(this, "NexusPlayer").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { dispatch("play") }
                override fun onPause() { dispatch("pause") }
                override fun onSkipToNext() { dispatch("next") }
                override fun onSkipToPrevious() { dispatch("previous") }
                override fun onStop() { dispatch("stop") }
                override fun onSeekTo(pos: Long) { dispatch("seek", pos) }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> dispatch("toggle")
            ACTION_PREVIOUS -> dispatch("previous")
            ACTION_NEXT -> dispatch("next")
            ACTION_CLOSE -> dispatch("stop")
        }

        val data = pendingData
        pendingData = null

        if (data != null) {
            render(data)
        } else if (current == null) {
            // Iniciado sem dados: cumpre o contrato do startForeground e encerra.
            startAsForeground(buildNotification())
            shutdown()
        }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    private fun dispatch(action: String, positionMs: Long? = null) {
        val sink = actionSink
        if (sink == null) {
            shutdown()
            return
        }
        sink(action, positionMs)
    }

    fun render(data: PlaybackData) {
        if (data.trackId != currentTrackId) {
            currentTrackId = data.trackId
            bitmap = decodeCover(data.cover)
        } else if (data.cover != null) {
            bitmap = decodeCover(data.cover)
        }

        current = data
        updateSession(data)
        startAsForeground(buildNotification())
    }

    fun shutdown() {
        current = null
        currentTrackId = null
        bitmap = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun decodeCover(bytes: ByteArray?): Bitmap? {
        if (bytes == null || bytes.isEmpty()) return null
        return try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (e: Exception) {
            null
        }
    }

    private fun updateSession(data: PlaybackData) {
        val metadata = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, data.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, data.artist ?: "Unknown artist")
            .putString(MediaMetadata.METADATA_KEY_ALBUM, data.album ?: "")
        if (data.durationMs > 0) {
            metadata.putLong(MediaMetadata.METADATA_KEY_DURATION, data.durationMs)
        }
        bitmap?.let { metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) }
        session.setMetadata(metadata.build())

        val actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SEEK_TO

        val state = if (data.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
        val speed = if (data.playing) 1f else 0f

        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(state, data.positionMs, speed)
                .build()
        )
    }

    private fun startAsForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyBuilder(): Notification.Builder = Notification.Builder(this)

    private fun buildNotification(): Notification {
        val data = current
        val playing = data?.playing == true

        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            legacyBuilder()
        }

        builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(data?.title ?: "Nexus Player")
            .setContentText(data?.artist ?: "Unknown artist")
            .setLargeIcon(bitmap)
            .setColor(0xFF1A1226.toInt())
            .setColorized(true)
            .setContentIntent(openAppIntent())
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .addAction(action(android.R.drawable.ic_media_previous, "Previous", ACTION_PREVIOUS))
            .addAction(
                action(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "Pause" else "Play",
                    ACTION_TOGGLE
                )
            )
            .addAction(action(android.R.drawable.ic_media_next, "Next", ACTION_NEXT))
            .addAction(action(android.R.drawable.ic_menu_close_clear_cancel, "Close", ACTION_CLOSE))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )

        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        return builder.build()
    }

    private fun action(iconRes: Int, title: String, actionName: String): Notification.Action {
        val intent = Intent(this, PlaybackService::class.java).setAction(actionName)
        val pendingIntent = PendingIntent.getService(
            this,
            actionName.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Action.Builder(
            Icon.createWithResource(this, iconRes),
            title,
            pendingIntent
        ).build()
    }

    private fun openAppIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Reprodu\u00e7\u00e3o",
            NotificationManager.IMPORTANCE_LOW
        )
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }
}