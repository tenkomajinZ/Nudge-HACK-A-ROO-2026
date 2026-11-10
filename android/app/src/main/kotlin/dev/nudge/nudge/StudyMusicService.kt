package dev.nudge.nudge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.mp3.Mp3Extractor
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

class StudyMusicService : MediaSessionService() {
    companion object {
        var current: StudyMusicService? = null
        var lastError: String? = null
        fun command(context: Context, action: String, track: Int? = null,
            volume: Float? = null, until: Long? = null, run: String? = null,
            position: Long? = null, timerPaused: Boolean? = null) {
            if (action == "preview") {
                command(context, "startRun", track, volume,
                    System.currentTimeMillis() + 10 * 60 * 1000L, "__preview__")
                return
            }
            if (action == "syncPreview" || action == "stopPreview") {
                val prefs = context.getSharedPreferences("nudge_focus", Context.MODE_PRIVATE)
                if (prefs.getString("musicRun", null) != "__preview__") {
                    if (action == "syncPreview") command(context, "stop")
                    return
                }
                if (action == "stopPreview") command(context, "stop")
                else current?.handle("startRun", track, volume, null, "__preview__")
                return
            }
            if ((action == "startRun" || action == "deadline") && until != null &&
                timerPaused != true && until <= System.currentTimeMillis()) {
                command(context, "stop"); return
            }
            if (action == "stop") {
                context.getSharedPreferences("nudge_focus", Context.MODE_PRIVATE).edit()
                    .remove("musicRun").remove("musicUntil").remove("musicTimerPaused")
                    .remove("musicStartToken").apply()
                current?.shutdown()
                // Do not cancel a pending Media3 foreground-service start. Its onStartCommand
                // must acknowledge that start before observing the expired lease and stopping.
                return
            }
            val instance = current
            if (action == "volume" && instance == null && volume != null) {
                context.getSharedPreferences("nudge_focus", Context.MODE_PRIVATE).edit()
                    .putFloat("musicVolume", volume.coerceIn(0f, 1f)).apply()
                return
            }
            if (instance != null) {
                instance.handle(action, track, volume, until, run, position, timerPaused)
            } else if (action == "startRun" || action == "toggle") {
                val prefs = context.getSharedPreferences("nudge_focus", Context.MODE_PRIVATE)
                val deadline = until ?: prefs.getLong("musicUntil", 0)
                val held = if (until == null) prefs.getBoolean("musicTimerPaused", false)
                    else timerPaused == true
                if (!held && deadline <= System.currentTimeMillis()) return
                if (action == "startRun" && prefs.getString("musicRun", null) == run &&
                    prefs.getInt("musicTrack", -1) == track) {
                    // Keep the lease current without restarting a stopped player.
                    prefs.edit().putLong("musicUntil", deadline)
                        .putBoolean("musicTimerPaused", held).apply()
                    return
                }
                val token = SystemClock.elapsedRealtimeNanos()
                val lease = prefs.edit().putLong("musicStartToken", token)
                    .putLong("musicUntil", deadline).putBoolean("musicTimerPaused", held)
                if (volume != null) lease.putFloat("musicVolume", volume.coerceIn(0f, 1f))
                lease.apply()
                val intent = Intent(context, StudyMusicService::class.java)
                    .putExtra("nudgeAction", action)
                    .putExtra("track", track ?: prefs.getInt("musicTrack", 0))
                    .putExtra("run", run).putExtra("startToken", token)
                // These commands originate from the visible Flutter UI.
                context.startService(intent)
            }
        }
    }
    var player: ExoPlayer? = null
        private set
    private var mediaSession: MediaSession? = null
    private var closing = false
    private val handler = Handler(Looper.getMainLooper())
    private var expiresElapsed = 0L
    private val expiry = object : Runnable {
        override fun run() {
            if (SystemClock.elapsedRealtime() >= expiresElapsed) {
                command(this@StudyMusicService, "stop")
            } else {
                handler.postDelayed(this, minOf(1000L, expiresElapsed - SystemClock.elapsedRealtime()))
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        current = this
        lastError = null
        val extractors = DefaultExtractorsFactory()
            .setMp3ExtractorFlags(Mp3Extractor.FLAG_ENABLE_INDEX_SEEKING)
        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(this, extractors)).build().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
            setHandleAudioBecomingNoisy(true)
            repeatMode = Player.REPEAT_MODE_ALL
            val paths = listOf("aria", "variation13", "variation15")
            val names = listOf("Aria", "Variation 13", "Variation 15")
            setMediaItems(paths.mapIndexed { index, path ->
                MediaItem.Builder().setUri("asset:///flutter_assets/assets/audio/$path.mp3")
                    .setMediaId(path).setMediaMetadata(MediaMetadata.Builder()
                        .setTitle(names[index]).setArtist("Kimiko Ishizaka")
                        .setAlbumTitle("Open Goldberg Variations").build()).build()
            })
            addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    lastError = "Music could not play. Your study timer is still running."
                    command(this@StudyMusicService, "stop")
                }
            })
        }
        val openApp = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this)
            .setNotificationId(1001).setChannelId("nudge_music")
            .setChannelName(R.string.study_music_channel).build())
        mediaSession = MediaSession.Builder(this, player!!).setSessionActivity(openApp).build()
        addSession(mediaSession!!)
    }

    private fun acknowledgeForegroundStart() {
        val notification = if (android.os.Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("nudge_music", getString(R.string.study_music_channel),
                    NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, "nudge_music")
        } else Notification.Builder(this)
        val openApp = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val style = Notification.MediaStyle()
        mediaSession?.platformToken?.let { style.setMediaSession(it) }
        startForeground(1001, notification.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("NUDGE study music")
            .setContentText(player?.mediaMetadata?.title ?: "Preparing your piano…")
            .setContentIntent(openApp).setOngoing(true).setShowWhen(false)
            .setStyle(style).build())
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = mediaSession
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Media3 can post a startSelfIntent while its final playback update is in flight.
        // Acknowledge every start here, even if the lease expired before it was delivered.
        acknowledgeForegroundStart()
        super.onStartCommand(intent, flags, startId)
        if (closing) { stopSelf(); return START_NOT_STICKY }
        val action = intent?.getStringExtra("nudgeAction")
        val prefs = getSharedPreferences("nudge_focus", MODE_PRIVATE)
        val pending = prefs.getLong("musicStartToken", 0)
        val until = prefs.getLong("musicUntil", 0)
        val timerPaused = prefs.getBoolean("musicTimerPaused", false)
        if (action == null) {
            if (pending == 0L && !timerPaused && until <= System.currentTimeMillis()) shutdown()
        } else {
            // Finish cancels a queued start; resume may update the lease before delivery.
            if (pending == 0L || intent.getLongExtra("startToken", 0) != pending) {
                if (pending == 0L && !prefs.contains("musicRun")) shutdown()
                return START_NOT_STICKY
            }
            prefs.edit().remove("musicStartToken").apply()
            if (!timerPaused && until <= System.currentTimeMillis()) {
                command(this, "stop"); return START_NOT_STICKY
            }
            // A volume drag may have arrived after this service-start intent was posted.
            val latestVolume = prefs.getFloat("musicVolume", 0.5f)
            handle(action, intent.getIntExtra("track", 0), latestVolume,
                until, intent.getStringExtra("run"), timerPaused = timerPaused)
        }
        return START_NOT_STICKY
    }

    fun handle(action: String, track: Int?, volume: Float?, until: Long?, run: String?,
        position: Long? = null, timerPaused: Boolean? = null) {
        val p = player ?: return
        if (closing) return
        val prefs = getSharedPreferences("nudge_focus", MODE_PRIVATE)
        val held = if (until == null) prefs.getBoolean("musicTimerPaused", false)
            else timerPaused == true
        if (until != null) {
            prefs.edit().putLong("musicUntil", until).putBoolean("musicTimerPaused", held).apply()
            handler.removeCallbacks(expiry)
            expiresElapsed = if (held) 0L else
                SystemClock.elapsedRealtime() + maxOf(0, until - System.currentTimeMillis())
            if (!held) handler.post(expiry)
        }
        when (action) {
            "startRun" -> {
                val selected = (track ?: 0).coerceIn(0, 2)
                val changed = prefs.getString("musicRun", null) != run ||
                    prefs.getInt("musicTrack", -1) != selected
                prefs.edit().putString("musicRun", run).putInt("musicTrack", selected).apply()
                if (changed || p.playbackState == Player.STATE_IDLE) {
                    p.seekTo(selected, 0); p.prepare(); p.play()
                }
            }
            "toggle" -> {
                if (p.playWhenReady) p.pause()
                else {
                    if (p.playbackState == Player.STATE_IDLE) {
                        p.seekTo((track ?: prefs.getInt("musicTrack", 0)).coerceIn(0, 2), 0)
                        p.prepare()
                    }
                    if (!held && expiresElapsed == 0L) {
                        expiresElapsed = SystemClock.elapsedRealtime() +
                            maxOf(0, prefs.getLong("musicUntil", 0) - System.currentTimeMillis())
                        handler.post(expiry)
                    }
                    if (held || expiresElapsed > SystemClock.elapsedRealtime()) p.play()
                }
            }
            "next" -> p.seekToNextMediaItem()
            "previous" -> p.seekToPreviousMediaItem()
            "seek" -> {
                // A track may advance while the thumb is being dragged. Never seek its successor.
                if (track == p.currentMediaItemIndex && position != null &&
                    p.isCurrentMediaItemSeekable && p.duration > 0) {
                    p.seekTo(position.coerceIn(0L, p.duration))
                }
            }
        }
        if (volume != null) {
            p.volume = volume.coerceIn(0f, 1f)
            prefs.edit().putFloat("musicVolume", p.volume).apply()
        }
    }

    private fun releasePlayback() {
        handler.removeCallbacksAndMessages(null)
        // Detach notification/controller callbacks before stopping the player.
        mediaSession?.let {
            if (isSessionAdded(it)) removeSession(it)
            it.release()
        }
        mediaSession = null
        player?.release()
        player = null
        if (current === this) current = null
    }

    fun shutdown() {
        if (closing) return
        closing = true
        releasePlayback()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        closing = true
        releasePlayback()
        super.onDestroy()
    }
}
