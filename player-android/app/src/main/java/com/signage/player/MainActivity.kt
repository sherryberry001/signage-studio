package com.signage.player

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.VideoView
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val prefs by lazy { getSharedPreferences("signage-player", MODE_PRIVATE) }
    private lateinit var root: FrameLayout
    private var screenId: String? = null
    private var slides = JSONArray()
    private var index = 0
    private var lastSync = ""
    private var playerVideo: VideoView? = null
    private var dashboardView: WebView? = null
    private var refreshTask: Runnable? = null
    private var advanceTask: Runnable? = null
    private var clockTask: Runnable? = null
    private var heartbeatTask: Runnable? = null
    private var scheduleTask: Runnable? = null
    private var slideGeneration = 0
    private var currentSlide: JSONObject? = null
    private var currentTitle = "Väntar på innehåll"
    private var currentBody = ""
    private var currentKind: String? = null
    private var currentSourceUrl: String? = null
    private val mediaDir by lazy { File(filesDir, "media").apply { mkdirs() } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enterImmersive()
        root = FrameLayout(this).apply { setBackgroundColor(Color.rgb(12, 15, 22)) }
        setContentView(root)
        screenId = prefs.getString("screen_id", null)
        if (screenId.isNullOrBlank()) showPairing() else startPlayer()
    }

    private fun enterImmersive() {
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
    }

    private fun showPairing(message: String = "") {
        root.removeAllViews()
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(72, 30, 72, 30)
        }
        page.addView(label("SIGNAGE PLAYER", 14, Color.rgb(183, 243, 106), true))
        page.addView(label("Koppla den här skärmen", 40, Color.WHITE, true).apply {
            setPadding(0, 20, 0, 8)
        })
        page.addView(label("Skapa en skärm i adminvyn och skriv in parkopplingskoden här.", 18, Color.LTGRAY, false))
        val code = EditText(this).apply {
            hint = "SEX TECKEN"
            setSingleLine(true)
            textSize = 25f
            gravity = Gravity.CENTER
            letterSpacing = .28f
            setTextColor(Color.WHITE)
            setHintTextColor(Color.GRAY)
            setBackgroundColor(Color.rgb(34, 42, 56))
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            filters = arrayOf(android.text.InputFilter.LengthFilter(6))
            isFocusable = true
            isFocusableInTouchMode = true
        }
        val params = LinearLayout.LayoutParams(420, 70).apply { topMargin = 28 }
        page.addView(code, params)
        val button = Button(this).apply {
            text = "AKTIVERA SKÄRM"
            textSize = 16f
            isFocusable = true
            setOnClickListener { claimCode(code.text.toString().trim().uppercase()) }
        }
        page.addView(button, LinearLayout.LayoutParams(420, 64).apply { topMargin = 14 })
        if (message.isNotBlank()) page.addView(label(message, 15, Color.rgb(255, 153, 153), false).apply { setPadding(0, 18, 0, 0) })
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
        code.requestFocus()
    }

    private fun claimCode(code: String) {
        if (code.length != 6) return showPairing("Koden ska innehålla sex tecken.")
        worker.execute {
            try {
                val json = JSONObject().put("input_code", code).toString()
                val response = apiRequest("${baseUrl()}/rest/v1/rpc/activate_screen", "POST", json)
                val id = response.trim().removeSurrounding("\"")
                if (id.isBlank() || id == "null") throw IllegalArgumentException("Koden hittades inte eller har redan använts.")
                prefs.edit().putString("screen_id", id).apply()
                screenId = id
                handler.post { startPlayer() }
            } catch (error: Exception) {
                handler.post { showPairing(error.message ?: "Kunde inte aktivera skärmen.") }
            }
        }
    }

    private fun startPlayer() {
        enterImmersive()
        showMessage("Ansluter till Signage Studio …", "Senast publicerade innehåll visas när det går att synka.")
        syncPlaylist()
        refreshTask?.let(handler::removeCallbacks)
        refreshTask = object : Runnable {
            override fun run() {
                syncPlaylist()
                handler.postDelayed(this, 15_000)
            }
        }
        handler.postDelayed(refreshTask!!, 15_000)
        heartbeatTask?.let(handler::removeCallbacks)
        heartbeatTask = object : Runnable {
            override fun run() {
                reportHeartbeat(currentSlide, currentTitle, currentBody, currentKind, currentSourceUrl)
                handler.postDelayed(this, 15_000)
            }
        }
        handler.postDelayed(heartbeatTask!!, 15_000)
        scheduleTask?.let(handler::removeCallbacks)
        scheduleTask = object : Runnable {
            override fun run() {
                val current = currentSlide
                if (current != null && !isScheduled(current)) showCurrentSlide()
                handler.postDelayed(this, 15_000)
            }
        }
        handler.postDelayed(scheduleTask!!, 15_000)
    }

    private fun syncPlaylist() {
        val id = screenId ?: return
        worker.execute {
            try {
                val result = apiRequest("${baseUrl()}/rest/v1/rpc/player_playlist", "POST", JSONObject().put("input_screen_id", id).toString())
                val fresh = JSONArray(result)
                val previous = prefs.getString("playlist", "[]") ?: "[]"
                val changed = fresh.toString() != previous
                prefs.edit().putString("playlist", fresh.toString()).putString("last_sync", Instant.now().toString()).apply()
                slides = fresh
                lastSync = "Synkad ${DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault()).format(Instant.now())}"
                preloadVideos(fresh)
                if (changed || fresh.length() == 0) handler.post {
                    if (changed) index = 0
                    showCurrentSlide()
                }
            } catch (_: Exception) {
                val saved = prefs.getString("playlist", "[]") ?: "[]"
                slides = try { JSONArray(saved) } catch (_: Exception) { JSONArray() }
                val savedTime = prefs.getString("last_sync", null)
                lastSync = savedTime?.let { "Offline · senast synkad ${formatTime(it)}" } ?: "Offline · inget innehåll sparat"
                handler.post { if (slides.length() > 0) showCurrentSlide() else showMessage("Ingen anslutning", "När TV:n får nät igen synkas innehållet automatiskt.") }
            }
        }
    }

    private fun preloadVideos(items: JSONArray) {
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            if (item.optString("kind") == "video") {
                val source = item.optString("source_url")
                if (source.isNotBlank() && !source.substringBefore('?').endsWith(".m3u8", ignoreCase = true)) {
                    try { localMedia(source, download = true) } catch (_: Exception) { }
                }
            }
        }
    }

    private fun showCurrentSlide() {
        slideGeneration++
        advanceTask?.let(handler::removeCallbacks)
        clockTask?.let(handler::removeCallbacks)
        playerVideo?.stopPlayback()
        dashboardView?.stopLoading()
        dashboardView?.destroy()
        playerVideo = null
        root.removeAllViews()
        if (slides.length() == 0) {
            currentSlide = null
            currentTitle = "Klocka & datum"
            currentBody = ""
            currentKind = "clock"
            currentSourceUrl = null
            reportHeartbeat(null, "Klocka & datum", "", "clock", null)
            showIdle()
            return
        }
        val chosen = (0 until slides.length()).map { (index + it) % slides.length() }
            .firstOrNull { candidate -> slides.optJSONObject(candidate)?.let(::isScheduled) == true }
        if (chosen == null) {
            currentSlide = null
            currentTitle = "Inget publicerat just nu"
            currentBody = ""
            currentKind = null
            currentSourceUrl = null
            reportHeartbeat(null, "Inget publicerat just nu", "", null, null)
            showMessage("Inget publicerat just nu", "Nästa synk sker automatiskt.")
            advanceTask = Runnable { index = (index + 1) % slides.length(); showCurrentSlide() }
            handler.postDelayed(advanceTask!!, 30_000)
            return
        }
        index = chosen
        val item = slides.optJSONObject(index) ?: return
        currentSlide = item
        currentTitle = item.optString("title").ifBlank { "Väntar på innehåll" }
        currentBody = item.optString("body")
        currentKind = item.optString("kind").takeIf { it.isNotBlank() }
        currentSourceUrl = item.optString("source_url").takeIf { it.isNotBlank() }
        reportHeartbeat(item)
        val duration = item.optInt("duration_seconds", 15).coerceIn(5, 600) * 1000L
        when (item.optString("kind")) {
            "video" -> showVideo(item)
            "clock" -> showClock(item)
            "feed" -> showFeed(item)
            "web" -> showWeb(item)
            else -> showText(item.optString("title"), item.optString("body"))
        }
        advanceTask = Runnable { index = (index + 1) % slides.length(); showCurrentSlide() }
        handler.postDelayed(advanceTask!!, duration)
    }

    private fun showWeb(item: JSONObject) {
        val address = item.optString("source_url")
        if (!address.startsWith("https://") && !address.startsWith("http://")) {
            showMessage(item.optString("title", "Webbsida"), "Adressen måste börja med HTTPS.")
            return
        }
        val web = WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.cacheMode = WebSettings.LOAD_NO_CACHE
            settings.mediaPlaybackRequiresUserGesture = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            CookieManager.getInstance().setAcceptCookie(true)
            clearCache(true)
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
                    return !url.startsWith("https://") && !url.startsWith("http://")
                }
            }
            webChromeClient = WebChromeClient()
        }
        dashboardView = web
        root.addView(web, FrameLayout.LayoutParams(-1, -1))
        web.loadUrl(address)
    }

    private fun reportHeartbeat(item: JSONObject?) {
        reportHeartbeat(
            item,
            item?.optString("title")?.takeIf { it.isNotBlank() } ?: "Väntar på innehåll",
            item?.optString("body")?.takeIf { it.isNotBlank() } ?: "",
            item?.optString("kind")?.takeIf { it.isNotBlank() },
            item?.optString("source_url")?.takeIf { it.isNotBlank() }
        )
    }

    private fun reportHeartbeat(item: JSONObject?, title: String, body: String, kind: String?, source: String?) {
        val id = screenId ?: return
        worker.execute {
            try {
                val body = JSONObject()
                    .put("input_screen_id", id)
                    .put("input_current_slide_id", item?.optString("id")?.takeIf { it.isNotBlank() } ?: JSONObject.NULL)
                    .put("input_current_title", title)
                    .put("input_current_body", body)
                    .put("input_current_kind", kind ?: JSONObject.NULL)
                    .put("input_current_source_url", source ?: JSONObject.NULL)
                apiRequest("${baseUrl()}/rest/v1/rpc/player_heartbeat", "POST", body.toString())
            } catch (_: Exception) { }
        }
    }

    private fun isScheduled(item: JSONObject): Boolean {
        val now = Instant.now()
        val from = item.optString("active_from").takeIf { it.isNotBlank() && it != "null" }?.let { runCatching { Instant.parse(it) }.getOrNull() }
        val until = item.optString("active_until").takeIf { it.isNotBlank() && it != "null" }?.let { runCatching { Instant.parse(it) }.getOrNull() }
        if ((from != null && now.isBefore(from)) || (until != null && !now.isBefore(until))) return false

        val localNow = java.time.ZonedDateTime.now()
        val weekdays = item.optJSONArray("weekdays")
        val selectedDays = weekdays?.let { array -> (0 until array.length()).map { array.optInt(it) }.toSet() }
        val startText = item.optString("daily_start_time").takeIf { it.isNotBlank() && it != "null" }
        val endText = item.optString("daily_end_time").takeIf { it.isNotBlank() && it != "null" }
        if (startText == null || endText == null) {
            return selectedDays.isNullOrEmpty() || localNow.dayOfWeek.value in selectedDays
        }

        val start = runCatching { LocalTime.parse(startText) }.getOrNull() ?: return false
        val end = runCatching { LocalTime.parse(endText) }.getOrNull() ?: return false
        val time = localNow.toLocalTime()
        if (start <= end) {
            return (selectedDays.isNullOrEmpty() || localNow.dayOfWeek.value in selectedDays) && !time.isBefore(start) && time.isBefore(end)
        }
        // An overnight window belongs to the selected day on which it started.
        if (!time.isBefore(start)) return selectedDays.isNullOrEmpty() || localNow.dayOfWeek.value in selectedDays
        if (time.isBefore(end)) {
            val previousDay = if (localNow.dayOfWeek.value == 1) 7 else localNow.dayOfWeek.value - 1
            return selectedDays.isNullOrEmpty() || previousDay in selectedDays
        }
        return false
    }

    private fun showText(title: String, body: String) {
        val page = contentColumn()
        page.addView(label(title, 46, Color.WHITE, true))
        if (body.isNotBlank()) page.addView(label(body, 27, Color.rgb(205, 212, 226), false).apply { setPadding(0, 20, 0, 0) })
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
    }

    private fun showClock(item: JSONObject) {
        val page = contentColumn()
        val clock = label("", 84, Color.WHITE, true)
        val date = label("", 24, Color.rgb(183, 243, 106), false).apply { setPadding(0, 9, 0, 0) }
        page.addView(clock)
        page.addView(date)
        if (item.optString("title").isNotBlank()) page.addView(label(item.optString("title"), 26, Color.WHITE, true).apply { setPadding(0, 32, 0, 0) })
        if (item.optString("body").isNotBlank()) page.addView(label(item.optString("body"), 19, Color.LTGRAY, false))
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
        val tick = object : Runnable {
            override fun run() {
                val now = java.time.ZonedDateTime.now()
                clock.text = now.format(DateTimeFormatter.ofPattern("HH:mm"))
                date.text = now.format(DateTimeFormatter.ofPattern("EEEE d MMMM", java.util.Locale("sv", "SE")))
                handler.postDelayed(this, 1000)
            }
        }
        clockTask = tick
        handler.post(tick)
    }

    private fun showFeed(item: JSONObject) {
        val generation = slideGeneration
        val title = item.optString("title")
        val source = item.optString("source_url")
        showMessage(title.ifBlank { "Informationsflöde" }, "Hämtar aktuell information …")
        worker.execute {
            val text = try {
                val key = "feed_${sha256(source)}"
                val fresh = URL(source).openConnection().run {
                    connectTimeout = 8_000; readTimeout = 8_000
                    setRequestProperty("Cache-Control", "no-cache, no-store, max-age=0")
                    setRequestProperty("Pragma", "no-cache")
                    getInputStream().bufferedReader().use { it.readText() }
                }
                prefs.edit().putString(key, fresh).apply()
                renderFeed(fresh)
            } catch (_: Exception) {
                prefs.getString("feed_${sha256(source)}", null)?.let(::renderFeed) ?: "Ingen feed kunde hämtas."
            }
            handler.post {
                if (generation == slideGeneration) {
                    showText(title.ifBlank { "Informationsflöde" }, text)
                    currentTitle = title.ifBlank { "Informationsflöde" }
                    currentBody = text
                    reportHeartbeat(item, title.ifBlank { "Informationsflöde" }, text, "feed", source)
                }
            }
        }
    }

    private fun renderFeed(raw: String): String {
        return try {
            val obj = JSONObject(raw)
            listOf("message", "value", "subtitle", "text", "status", "updated_at").mapNotNull { key ->
                obj.optString(key).takeIf { it.isNotBlank() && it != "null" }
            }.joinToString("\n\n").ifBlank { obj.toString(2) }
        } catch (_: Exception) { raw.take(1600) }
    }

    private fun showVideo(item: JSONObject) {
        val source = item.optString("source_url")
        val isHls = source.substringBefore('?').endsWith(".m3u8", ignoreCase = true)
        val local = if (isHls) null else runCatching { localMedia(source, download = false) }.getOrNull()
        val uri = if (local != null && local.exists()) Uri.fromFile(local) else Uri.parse(source)
        val video = VideoView(this).apply {
            setBackgroundColor(Color.BLACK)
            setVideoURI(uri)
            setOnPreparedListener { media -> media.isLooping = true; start() }
            setOnErrorListener { _, _, _ ->
                showMessage(item.optString("title", "Video"), "Videon kunde inte spelas. Kontrollera att länken är en direkt MP4- eller HLS-adress.")
                true
            }
        }
        playerVideo = video
        root.addView(video, FrameLayout.LayoutParams(-1, -1))
    }

    private fun showIdle() {
        val timeItem = JSONObject().put("title", "").put("body", "")
        showClock(timeItem)
    }

    private fun showMessage(title: String, body: String) {
        root.removeAllViews()
        val page = contentColumn()
        page.addView(label(title, 38, Color.WHITE, true))
        page.addView(label(body, 19, Color.LTGRAY, false).apply { setPadding(0, 14, 0, 0) })
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
    }

    private fun contentColumn() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setPadding(90, 50, 90, 50)
    }

    private fun label(value: String, size: Int, color: Int, bold: Boolean) = TextView(this).apply {
        text = value
        textSize = size.toFloat()
        setTextColor(color)
        gravity = Gravity.CENTER
        typeface = if (bold) Typeface.create("sans-serif", Typeface.BOLD) else Typeface.create("sans-serif", Typeface.NORMAL)
        maxWidth = 1500
    }

    private fun apiRequest(address: String, method: String, body: String? = null): String {
        require(BuildConfig.SUPABASE_URL.startsWith("https://") && BuildConfig.SUPABASE_ANON_KEY.isNotBlank()) {
            "Lägg in Supabase-inställningarna i player-android/signage.properties och bygg appen igen."
        }
        val conn = (URL(address).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 12_000
            readTimeout = 20_000
            setRequestProperty("apikey", BuildConfig.SUPABASE_ANON_KEY)
            setRequestProperty("Authorization", "Bearer ${BuildConfig.SUPABASE_ANON_KEY}")
            setRequestProperty("Cache-Control", "no-cache, no-store, max-age=0")
            setRequestProperty("Pragma", "no-cache")
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
        }
        return try {
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            if (status !in 200..299) throw IllegalStateException("Serverfel $status: ${text.take(250)}")
            text
        } finally { conn.disconnect() }
    }

    private fun baseUrl() = BuildConfig.SUPABASE_URL.trimEnd('/')

    private fun localMedia(source: String, download: Boolean): File? {
        val filename = sha256(source) + extension(source)
        val target = File(mediaDir, filename)
        if (target.exists() && target.length() > 0) return target
        if (!download) return null
        val tmp = File(mediaDir, "$filename.part")
        val connection = (URL(source).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000; readTimeout = 30_000
            setRequestProperty("Cache-Control", "no-cache, no-store")
            if (BuildConfig.SUPABASE_ANON_KEY.isNotBlank() && source.startsWith(baseUrl())) {
                setRequestProperty("apikey", BuildConfig.SUPABASE_ANON_KEY)
                setRequestProperty("Authorization", "Bearer ${BuildConfig.SUPABASE_ANON_KEY}")
            }
        }
        try {
            connection.inputStream.use { input -> tmp.outputStream().use { output -> input.copyTo(output) } }
            if (tmp.length() > 0) tmp.renameTo(target)
        } finally { connection.disconnect(); if (tmp.exists()) tmp.delete() }
        return target.takeIf { it.exists() && it.length() > 0 }
    }

    private fun extension(source: String): String {
        val path = runCatching { Uri.parse(source).lastPathSegment.orEmpty() }.getOrDefault("")
        val ext = path.substringAfterLast('.', "").lowercase()
        return if (ext in setOf("mp4", "webm", "mov", "m3u8")) ".$ext" else ".mp4"
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun formatTime(value: String): String = runCatching {
        DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault()).format(Instant.parse(value))
    }.getOrDefault("tidigare")

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && screenId != null) {
            // Keep the signage player on screen; a long press can be used to exit from Android settings.
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        advanceTask?.let(handler::removeCallbacks)
        clockTask?.let(handler::removeCallbacks)
        refreshTask?.let(handler::removeCallbacks)
        heartbeatTask?.let(handler::removeCallbacks)
        playerVideo?.stopPlayback()
        worker.shutdownNow()
        super.onDestroy()
    }
}
