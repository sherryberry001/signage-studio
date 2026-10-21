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
import android.widget.ImageView
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
    private var screenConfig = JSONObject()
    private var outsideOperatingHours = false
    private var slides = JSONArray()
    private var zoneSlides = JSONArray()
    private var index = 0
    private var zoneIndex = 0
    private var lastSync = ""
    private var playerVideo: VideoView? = null
    private var dashboardView: WebView? = null
    private var zoneRoot: FrameLayout? = null
    private var zoneVideo: VideoView? = null
    private var zoneWebView: WebView? = null
    private var refreshTask: Runnable? = null
    private var advanceTask: Runnable? = null
    private var clockTask: Runnable? = null
    private var heartbeatTask: Runnable? = null
    private var scheduleTask: Runnable? = null
    private var zoneAdvanceTask: Runnable? = null
    private var zoneClockTask: Runnable? = null
    private var zoneGeneration = 0
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
        screenConfig = runCatching { JSONObject(prefs.getString("screen_config", "{}") ?: "{}") }.getOrDefault(JSONObject())
        outsideOperatingHours = !isWithinOperatingHours(screenConfig)
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
        if (outsideOperatingHours) showOperatingHoursScreen()
        else showMessage("Ansluter till Signage Studio …", "Senast publicerade innehåll visas när det går att synka.")
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
                pollPlayerCommand()
                handler.postDelayed(this, 15_000)
            }
        }
        handler.postDelayed(heartbeatTask!!, 15_000)
        scheduleTask?.let(handler::removeCallbacks)
        scheduleTask = object : Runnable {
            override fun run() {
                val isClosed = !isWithinOperatingHours(screenConfig)
                if (isClosed != outsideOperatingHours) {
                    outsideOperatingHours = isClosed
                    if (isClosed) showOperatingHoursScreen() else showCurrentSlide()
                }
                if (outsideOperatingHours) {
                    handler.postDelayed(this, 15_000)
                    return
                }
                val current = currentSlide
                val desired = eligibleSlides()
                val currentId = current?.optString("id")
                val currentChannel = current?.optString("channel_id")?.takeUnless { it.isBlank() || it == "null" }
                val desiredChannel = desired.firstOrNull()?.optString("channel_id")?.takeUnless { it.isBlank() || it == "null" }
                val synchronizedItem = if (isSynchronizedPlayback()) synchronizedSelection(desired)?.first else null
                if (current == null || currentId.isNullOrBlank() || currentId !in desired.map { it.optString("id") } || currentChannel != desiredChannel || synchronizedItem?.optString("id")?.let { it != currentId } == true) showCurrentSlide()
                handler.postDelayed(this, 15_000)
            }
        }
        handler.postDelayed(scheduleTask!!, 15_000)
    }

    private fun syncPlaylist(onComplete: ((String?) -> Unit)? = null) {
        val id = screenId ?: run {
            onComplete?.invoke("Spelaren är inte parkopplad.")
            return
        }
        worker.execute {
            try {
                val freshConfig = runCatching {
                    JSONObject(apiRequest("${baseUrl()}/rest/v1/rpc/player_screen_config", "POST", JSONObject().put("input_screen_id", id).toString()))
                }.getOrNull()
                val result = apiRequest("${baseUrl()}/rest/v1/rpc/player_playlist", "POST", JSONObject().put("input_screen_id", id).toString())
                val fresh = JSONArray(result)
                val previous = prefs.getString("playlist", "[]") ?: "[]"
                val changed = fresh.toString() != previous
                val configChanged = freshConfig != null && freshConfig.toString() != screenConfig.toString()
                prefs.edit().putString("playlist", fresh.toString()).putString("last_sync", Instant.now().toString()).apply()
                setPlayerPlaylist(fresh)
                lastSync = "Synkad ${DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault()).format(Instant.now())}"
                preloadVideos(fresh)
                if (freshConfig != null) prefs.edit().putString("screen_config", freshConfig.toString()).apply()
                val effectiveConfig = freshConfig ?: screenConfig
                handler.post {
                    val wasClosed = outsideOperatingHours
                    screenConfig = effectiveConfig
                    outsideOperatingHours = !isWithinOperatingHours(screenConfig)
                    if (outsideOperatingHours) {
                        if (!wasClosed || changed) showOperatingHoursScreen()
                    } else if (changed || configChanged || wasClosed || fresh.length() == 0) {
                        if (changed) index = 0
                        showCurrentSlide()
                    }
                }
                onComplete?.invoke(null)
            } catch (_: Exception) {
                val saved = prefs.getString("playlist", "[]") ?: "[]"
                setPlayerPlaylist(try { JSONArray(saved) } catch (_: Exception) { JSONArray() })
                val savedTime = prefs.getString("last_sync", null)
                lastSync = savedTime?.let { "Offline · senast synkad ${formatTime(it)}" } ?: "Offline · inget innehåll sparat"
                handler.post {
                    outsideOperatingHours = !isWithinOperatingHours(screenConfig)
                    if (outsideOperatingHours) showOperatingHoursScreen()
                    else if (slides.length() > 0 || zoneSlides.length() > 0) showCurrentSlide()
                    else showMessage("Ingen anslutning", "När TV:n får nät igen synkas innehållet automatiskt.")
                }
                onComplete?.invoke("Kunde inte synka innehållet.")
            }
        }
    }

    private fun setPlayerPlaylist(items: JSONArray) {
        val main = JSONArray()
        val secondary = JSONArray()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            if (item.optString("layout_zone") == "secondary") secondary.put(item) else main.put(item)
        }
        slides = main
        zoneSlides = secondary
    }

    private fun pollPlayerCommand() {
        val id = screenId ?: return
        worker.execute {
            try {
                val result = apiRequest(
                    "${baseUrl()}/rest/v1/rpc/player_claim_command",
                    "POST",
                    JSONObject().put("input_screen_id", id).toString()
                )
                val commands = JSONArray(result)
                if (commands.length() == 0) return@execute
                val commandItem = commands.optJSONObject(0) ?: return@execute
                val commandId = commandItem.optString("command_id")
                val command = commandItem.optString("command")
                when (command) {
                    "sync_now" -> {
                        syncPlaylist { error -> completePlayerCommand(id, commandId, error) }
                        return@execute
                    }
                    "restart_player" -> {
                        completePlayerCommand(id, commandId, null)
                        handler.post { recreate() }
                        return@execute
                    }
                    else -> completePlayerCommand(id, commandId, "Okänt kommando.")
                }
            } catch (_: Exception) { }
        }
    }

    private fun completePlayerCommand(screen: String, command: String, error: String?) {
        try {
            val body = JSONObject()
                .put("input_screen_id", screen)
                .put("input_command_id", command)
                .put("input_error", error ?: JSONObject.NULL)
            apiRequest("${baseUrl()}/rest/v1/rpc/player_complete_command", "POST", body.toString())
        } catch (_: Exception) { }
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
        if (outsideOperatingHours) {
            showOperatingHoursScreen()
            return
        }
        slideGeneration++
        advanceTask?.let(handler::removeCallbacks)
        clockTask?.let(handler::removeCallbacks)
        playerVideo?.stopPlayback()
        dashboardView?.stopLoading()
        dashboardView?.destroy()
        clearSecondaryZone()
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
            applyMultiZoneLayout(zoneSlides.optJSONObject(0))
            return
        }
        val eligible = eligibleSlides()
        if (eligible.isEmpty()) {
            currentSlide = null
            currentTitle = "Inget publicerat just nu"
            currentBody = ""
            currentKind = null
            currentSourceUrl = null
            reportHeartbeat(null, "Inget publicerat just nu", "", null, null)
            showMessage("Inget publicerat just nu", "Nästa synk sker automatiskt.")
            applyMultiZoneLayout(zoneSlides.optJSONObject(0))
            advanceTask = Runnable { index = (index + 1) % slides.length(); showCurrentSlide() }
            handler.postDelayed(advanceTask!!, 30_000)
            return
        }
        val eligibleIds = eligible.map { it.optString("id") }.toSet()
        val timedSelection = if (isSynchronizedPlayback()) synchronizedSelection(eligible) else null
        val item = timedSelection?.first ?: (0 until slides.length()).map { (index + it) % slides.length() }
            .mapNotNull { slides.optJSONObject(it) }
            .firstOrNull { it.optString("id") in eligibleIds } ?: eligible[0]
        index = (0 until slides.length()).firstOrNull { slides.optJSONObject(it)?.optString("id") == item.optString("id") } ?: 0
        currentSlide = item
        currentTitle = item.optString("title").ifBlank { "Väntar på innehåll" }
        currentBody = item.optString("body")
        currentKind = item.optString("kind").takeIf { it.isNotBlank() }
        currentSourceUrl = item.optString("source_url").takeIf { it.isNotBlank() }
        reportHeartbeat(item)
        val duration = timedSelection?.second ?: item.optInt("duration_seconds", 15).coerceIn(5, 600) * 1000L
        when (item.optString("kind")) {
            "video" -> showVideo(item)
            "clock" -> showClock(item)
            "feed" -> showFeed(item)
            "web" -> showWeb(item)
            else -> showText(item.optString("title"), item.optString("body"))
        }
        applyMultiZoneLayout(item)
        advanceTask = Runnable { index = (index + 1) % slides.length(); showCurrentSlide() }
        handler.postDelayed(advanceTask!!, duration)
    }

    private fun applyMultiZoneLayout(item: JSONObject?) {
        clearSecondaryZone()
        val layoutItem = item ?: zoneSlides.optJSONObject(0)
        val layout = layoutItem?.optString("layout_type", "single") ?: "single"
        val copy = layoutItem?.optString("layout_text").orEmpty().trim()
        if (layout == "single" || item?.optBoolean("forced") == true) return
        val scheduled = eligibleZoneSlides()
        if (scheduled.isEmpty() && copy.isBlank()) return
        val primary = root.getChildAt(0) ?: return
        root.post {
            if (root.childCount == 0 || root.getChildAt(0) !== primary) return@post
            val width = root.width
            val height = root.height
            if (width <= 0 || height <= 0) return@post
            val panel = FrameLayout(this).apply { setBackgroundColor(Color.rgb(28, 37, 53)) }
            if (layout == "bottom_ticker") {
                val panelHeight = (height * .16f).toInt().coerceAtLeast(80)
                primary.layoutParams = FrameLayout.LayoutParams(-1, height - panelHeight, Gravity.TOP)
                root.addView(panel, FrameLayout.LayoutParams(-1, panelHeight, Gravity.BOTTOM))
            } else if (layout == "side_panel") {
                val primaryWidth = (width * .72f).toInt()
                primary.layoutParams = FrameLayout.LayoutParams(primaryWidth, -1, Gravity.LEFT)
                root.addView(panel, FrameLayout.LayoutParams(width - primaryWidth, -1, Gravity.RIGHT))
            }
            zoneRoot = panel
            if (scheduled.isEmpty()) showSecondaryZoneText(panel, copy, layout)
            else {
                val timedSelection = if (isSynchronizedPlayback()) synchronizedSelection(scheduled) else null
                val selected = timedSelection?.first ?: scheduled[zoneIndex.mod(scheduled.size)]
                zoneIndex = scheduled.indexOfFirst { it.optString("id") == selected.optString("id") }.coerceAtLeast(0)
                showSecondaryZoneSlide(panel, selected, layout, timedSelection?.second)
            }
        }
    }

    private fun clearSecondaryZone() {
        zoneGeneration++
        zoneAdvanceTask?.let(handler::removeCallbacks)
        zoneClockTask?.let(handler::removeCallbacks)
        zoneVideo?.stopPlayback()
        zoneWebView?.stopLoading()
        zoneWebView?.destroy()
        zoneRoot = null
        zoneVideo = null
        zoneWebView = null
    }

    private fun eligibleZoneSlides(): List<JSONObject> =
        (0 until zoneSlides.length()).mapNotNull { zoneSlides.optJSONObject(it) }.filter { isScheduled(it) }

    private fun showSecondaryZoneText(container: FrameLayout, text: String, layout: String) {
        val view = TextView(this).apply {
            this.text = text
            setTextColor(Color.WHITE)
            textSize = if (layout == "side_panel") 22f else 21f
            gravity = Gravity.CENTER
            setPadding(22, 12, 22, 12)
            if (layout == "bottom_ticker") {
                setSingleLine(true)
                ellipsize = android.text.TextUtils.TruncateAt.MARQUEE
                marqueeRepeatLimit = -1
                isSelected = true
            }
        }
        container.removeAllViews()
        container.addView(view, FrameLayout.LayoutParams(-1, -1))
    }

    private fun showSecondaryZoneSlide(container: FrameLayout, item: JSONObject, layout: String, delayOverrideMillis: Long? = null) {
        container.removeAllViews()
        val generation = zoneGeneration
        val kind = item.optString("kind")
        val title = item.optString("title").ifBlank { kind }
        when (kind) {
            "video" -> {
                val source = item.optString("source_url")
                val local = runCatching { localMedia(source, download = false) }.getOrNull()
                val video = VideoView(this).apply {
                    setBackgroundColor(Color.BLACK)
                    setVideoURI(if (local?.exists() == true) Uri.fromFile(local) else Uri.parse(source))
                    setOnPreparedListener { media -> media.isLooping = true; media.setVolume(0f, 0f); start() }
                    setOnErrorListener { _, _, _ -> showSecondaryZoneText(container, title, layout); true }
                }
                zoneVideo = video
                container.addView(video, FrameLayout.LayoutParams(-1, -1))
            }
            "web" -> {
                val address = item.optString("source_url")
                if (!address.startsWith("https://") && !address.startsWith("http://")) {
                    showSecondaryZoneText(container, "Ogiltig webbadress", layout)
                } else {
                    val web = WebView(this).apply {
                        setBackgroundColor(Color.BLACK)
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.cacheMode = WebSettings.LOAD_NO_CACHE
                        settings.mediaPlaybackRequiresUserGesture = false
                        clearCache(true)
                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(view: WebView, url: String) = !url.startsWith("https://") && !url.startsWith("http://")
                        }
                        webChromeClient = WebChromeClient()
                    }
                    zoneWebView = web
                    container.addView(web, FrameLayout.LayoutParams(-1, -1))
                    web.loadUrl(address)
                }
            }
            "feed" -> {
                showSecondaryZoneText(container, "Hämtar ${title} …", layout)
                worker.execute {
                    val source = item.optString("source_url")
                    val cachedKey = "zone_feed_${sha256(source)}"
                    val raw = try {
                        val token = Uri.parse(source).fragment?.removePrefix("token=")?.takeIf { it.isNotBlank() }
                        val connection = URL(source.substringBefore('#')).openConnection().apply {
                            connectTimeout = 8_000
                            readTimeout = 8_000
                            useCaches = false
                            setRequestProperty("Cache-Control", "no-cache, no-store, max-age=0")
                            if (token != null) setRequestProperty("x-pulse-display-token", token)
                        }
                        connection.getInputStream().bufferedReader().use { it.readText() }.also { prefs.edit().putString(cachedKey, it).apply() }
                    } catch (_: Exception) { prefs.getString(cachedKey, null) }
                    handler.post {
                        if (generation == zoneGeneration && zoneRoot === container) {
                            val payload = raw?.let { runCatching { JSONObject(it) }.getOrNull() }
                            val text = if (payload?.optString("format") == "dizparc-pulse-signage") {
                                val global = payload.optJSONObject("global") ?: JSONObject()
                                "Pulse · ${global.optString("devices_online", "0")}/${global.optString("total_devices", "0")} online · ${global.optString("critical_alerts", "0")} kritiska larm"
                            } else raw?.let(::renderFeed) ?: "Ingen anslutning till feed"
                            showSecondaryZoneText(container, text, layout)
                        }
                    }
                }
            }
            "clock" -> {
                val view = TextView(this).apply { setTextColor(Color.WHITE); textSize = 25f; gravity = Gravity.CENTER }
                container.addView(view, FrameLayout.LayoutParams(-1, -1))
                val tick = object : Runnable {
                    override fun run() {
                        val now = java.time.ZonedDateTime.now()
                        view.text = "${now.format(DateTimeFormatter.ofPattern("HH:mm"))}\n${item.optString("title")}"
                        handler.postDelayed(this, 1000)
                    }
                }
                zoneClockTask = tick
                handler.post(tick)
            }
            else -> showSecondaryZoneText(container, item.optString("body").ifBlank { title }, layout)
        }

        val schedule = object : Runnable {
            override fun run() {
                val available = eligibleZoneSlides()
                if (available.isNotEmpty() && zoneRoot === container) {
                    val timedSelection = if (isSynchronizedPlayback()) synchronizedSelection(available) else null
                    if (timedSelection != null) {
                        zoneIndex = available.indexOfFirst { it.optString("id") == timedSelection.first.optString("id") }.coerceAtLeast(0)
                        showSecondaryZoneSlide(container, timedSelection.first, layout, timedSelection.second)
                    } else {
                        zoneIndex = (zoneIndex + 1) % available.size
                        showSecondaryZoneSlide(container, available[zoneIndex], layout)
                    }
                } else if (zoneRoot === container) {
                    showSecondaryZoneText(container, item.optString("layout_text"), layout)
                }
            }
        }
        zoneAdvanceTask = schedule
        handler.postDelayed(schedule, delayOverrideMillis ?: item.optInt("duration_seconds", 15).coerceIn(5, 600) * 1000L)
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
        return isScheduled(item, "active_from", "active_until", "weekdays", "daily_start_time", "daily_end_time")
    }

    private fun isSynchronizedPlayback(): Boolean = screenConfig.optString("playback_mode") == "sync"

    /** Derive the same cyclic item and next boundary on every player using the wall clock. */
    private fun synchronizedSelection(items: List<JSONObject>): Pair<JSONObject, Long>? {
        if (items.isEmpty()) return null
        val durations = items.map { it.optInt("duration_seconds", 15).coerceIn(5, 600) * 1000L }
        val cycleMillis = durations.sum()
        if (cycleMillis <= 0L) return items.first() to 15_000L
        var offset = Math.floorMod(System.currentTimeMillis(), cycleMillis)
        items.forEachIndexed { itemIndex, item ->
            val duration = durations[itemIndex]
            if (offset < duration) return item to (duration - offset).coerceAtLeast(250L)
            offset -= duration
        }
        return items.last() to durations.last()
    }

    private fun isWithinOperatingHours(config: JSONObject): Boolean {
        val localNow = java.time.ZonedDateTime.now()
        val selected = config.optJSONArray("operating_weekdays")
        val days = selected?.let { array ->
            (0 until array.length()).mapNotNull { array.optInt(it).takeIf { day -> day in 1..7 } }.toSet()
        }.orEmpty()
        val unrestrictedDays = selected == null || days.isEmpty()
        fun isSelected(day: Int) = unrestrictedDays || day in days

        val startText = config.optString("operating_start_time").takeIf { it.isNotBlank() && it != "null" }
        val endText = config.optString("operating_end_time").takeIf { it.isNotBlank() && it != "null" }
        if (startText == null && endText == null) return isSelected(localNow.dayOfWeek.value)
        val start = runCatching { LocalTime.parse(startText) }.getOrNull() ?: return true
        val end = runCatching { LocalTime.parse(endText) }.getOrNull() ?: return true
        val now = localNow.toLocalTime()
        if (start == end) return isSelected(localNow.dayOfWeek.value)
        if (start < end) return isSelected(localNow.dayOfWeek.value) && !now.isBefore(start) && now.isBefore(end)
        if (!now.isBefore(start)) return isSelected(localNow.dayOfWeek.value)
        if (now.isBefore(end)) {
            val previousDay = if (localNow.dayOfWeek.value == 1) 7 else localNow.dayOfWeek.value - 1
            return isSelected(previousDay)
        }
        return false
    }

    private fun isScheduled(item: JSONObject, fromKey: String, untilKey: String, weekdaysKey: String, startKey: String, endKey: String): Boolean {
        val now = Instant.now()
        val from = item.optString(fromKey).takeIf { it.isNotBlank() && it != "null" }?.let { runCatching { Instant.parse(it) }.getOrNull() }
        val until = item.optString(untilKey).takeIf { it.isNotBlank() && it != "null" }?.let { runCatching { Instant.parse(it) }.getOrNull() }
        if ((from != null && now.isBefore(from)) || (until != null && !now.isBefore(until))) return false

        val localNow = java.time.ZonedDateTime.now()
        val weekdays = item.optJSONArray(weekdaysKey)
        val selectedDays = weekdays?.let { array -> (0 until array.length()).map { array.optInt(it) }.toSet() }
        val startText = item.optString(startKey).takeIf { it.isNotBlank() && it != "null" }
        val endText = item.optString(endKey).takeIf { it.isNotBlank() && it != "null" }
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

    /** Select an active channel locally so the same schedule remains usable offline. */
    private fun eligibleSlides(): List<JSONObject> {
        val all = (0 until slides.length()).mapNotNull { slides.optJSONObject(it) }
        val now = Instant.now()
        val forced = all.firstOrNull { item ->
            if (!item.optBoolean("forced")) return@firstOrNull false
            val forcedUntil = item.optString("forced_until")
                .takeIf { it.isNotBlank() && it != "null" }
                ?.let { runCatching { Instant.parse(it) }.getOrNull() }
            forcedUntil == null || now.isBefore(forcedUntil)
        }
        if (forced != null) return listOf(forced)

        val channelItems = all.filter { item ->
            item.optString("channel_id").isNotBlank() && item.optString("channel_id") != "null" &&
                isScheduled(item, "channel_active_from", "channel_active_until", "channel_weekdays", "channel_daily_start_time", "channel_daily_end_time") &&
                isScheduled(item, "channel_playlist_active_from", "channel_playlist_active_until", "channel_playlist_weekdays", "channel_playlist_daily_start_time", "channel_playlist_daily_end_time") &&
                isScheduled(item)
        }
        val activeChannel = channelItems.minWithOrNull(
            compareBy<JSONObject> { it.optInt("channel_priority", 100) }
                .thenBy { it.optInt("channel_playlist_priority", 100) }
                .thenBy { it.optInt("channel_playlist_order", 0) }
        )?.optString("channel_id")

        val selected = if (activeChannel != null) {
            channelItems.filter { it.optString("channel_id") == activeChannel }
        } else {
            all.filter { (it.isNull("channel_id") || it.optString("channel_id") == "null") && isScheduled(it) }
        }
        if (selected.isEmpty() && activeChannel != null) {
            return all.filter { (it.isNull("channel_id") || it.optString("channel_id") == "null") && isScheduled(it) }
        }
        return selected
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
            val raw = try {
                val key = "feed_${sha256(source)}"
                val displayToken = Uri.parse(source).fragment?.removePrefix("token=")?.takeIf { it.isNotBlank() }
                val fresh = URL(source.substringBefore('#')).openConnection().run {
                    connectTimeout = 8_000; readTimeout = 8_000
                    useCaches = false
                    setRequestProperty("Cache-Control", "no-cache, no-store, max-age=0")
                    setRequestProperty("Pragma", "no-cache")
                    if (displayToken != null) setRequestProperty("x-pulse-display-token", displayToken)
                    getInputStream().bufferedReader().use { it.readText() }
                }
                prefs.edit().putString(key, fresh).apply()
                fresh
            } catch (_: Exception) {
                prefs.getString("feed_${sha256(source)}", null)
            }
            handler.post {
                if (generation == slideGeneration) {
                    val payload = raw?.let { runCatching { JSONObject(it) }.getOrNull() }
                    if (payload?.optString("format") == "dizparc-pulse-signage") {
                        showPulseDashboard(item, payload)
                    } else if (payload != null && isStructuredDashboard(payload)) {
                        showStructuredDashboard(item, payload)
                    } else {
                        showText(title.ifBlank { "Informationsflöde" }, raw?.let(::renderFeed) ?: "Ingen feed kunde hämtas.")
                    }
                    currentTitle = title.ifBlank { "Informationsflöde" }
                    currentBody = when {
                        payload?.optString("format") == "dizparc-pulse-signage" -> "Pulse liveöversikt"
                        payload != null && isStructuredDashboard(payload) -> "Live-dashboard"
                        else -> raw?.let(::renderFeed).orEmpty()
                    }
                    reportHeartbeat(item, title.ifBlank { "Informationsflöde" }, currentBody, "feed", source)
                    applyMultiZoneLayout(item)
                }
            }
        }
    }

    private fun isStructuredDashboard(payload: JSONObject): Boolean =
        payload.optString("format") == "signage-dashboard-v1"
            || payload.has("metrics")
            || payload.has("items")
            || payload.has("alerts")

    private fun feedValue(item: JSONObject, vararg keys: String): String {
        for (key in keys) {
            val value = item.opt(key) ?: continue
            if (value == JSONObject.NULL) continue
            val text = value.toString().trim()
            if (text.isNotEmpty() && text != "null") return text
        }
        return ""
    }

    private fun showStructuredDashboard(item: JSONObject, payload: JSONObject) {
        root.removeAllViews()
        val background = Color.rgb(12, 18, 28)
        val panelColor = Color.rgb(26, 36, 51)
        val accent = Color.rgb(183, 243, 106)
        val white = Color.WHITE
        val muted = Color.rgb(166, 178, 196)
        val generatedAt = feedValue(payload, "updated_at", "generated_at", "timestamp")
        val age = runCatching { java.time.Duration.between(Instant.parse(generatedAt), Instant.now()).seconds.coerceAtLeast(0) }.getOrNull()
        val stale = age?.let { it > 120 } ?: false
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(36, 26, 36, 24)
            setBackgroundColor(background)
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val heading = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        heading.addView(label(feedValue(payload, "title").ifBlank { item.optString("title").ifBlank { "Live-dashboard" } }, 30, white, true).apply { gravity = Gravity.LEFT })
        val subtitle = feedValue(payload, "subtitle", "message")
        if (subtitle.isNotBlank()) heading.addView(label(subtitle, 15, muted, false).apply { gravity = Gravity.LEFT; setPadding(0, 4, 0, 0) })
        header.addView(heading, LinearLayout.LayoutParams(0, -2, 1f))
        val liveLabel = when {
            age == null -> "UPPDATERING OKÄND"
            stale -> "GAMLA DATA · ${age.div(60)} MIN"
            else -> "LIVE · ${generatedAt.take(16).replace('T', ' ')}"
        }
        header.addView(label(liveLabel, 13, if (stale) Color.rgb(255, 194, 14) else accent, true))
        page.addView(header, LinearLayout.LayoutParams(-1, 76))

        val metrics = payload.optJSONArray("metrics") ?: JSONArray()
        if (metrics.length() > 0) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, 14, 0, 20) }
            for (index in 0 until minOf(metrics.length(), 6)) {
                val metric = metrics.optJSONObject(index) ?: continue
                val card = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(16, 12, 16, 12)
                    setBackgroundColor(panelColor)
                }
                card.addView(label(feedValue(metric, "label", "title", "name").ifBlank { "MÄTVÄRDE" }.uppercase(java.util.Locale("sv", "SE")), 12, muted, true).apply { gravity = Gravity.LEFT; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
                card.addView(label(feedValue(metric, "value", "text").ifBlank { "–" }, 29, white, true).apply { gravity = Gravity.LEFT; setPadding(0, 5, 0, 0); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
                val detail = feedValue(metric, "detail", "trend", "subtitle")
                if (detail.isNotBlank()) card.addView(label(detail, 12, muted, false).apply { gravity = Gravity.LEFT; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
                row.addView(card, LinearLayout.LayoutParams(0, 104, 1f).apply { if (index < minOf(metrics.length(), 6) - 1) rightMargin = 10 })
            }
            page.addView(row, LinearLayout.LayoutParams(-1, 126))
        }

        val entries = payload.optJSONArray("items") ?: payload.optJSONArray("alerts") ?: payload.optJSONArray("rows") ?: JSONArray()
        if (entries.length() > 0) {
            val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(16, 13, 16, 13); setBackgroundColor(panelColor) }
            val listTitle = feedValue(payload, "items_title", "section_title").ifBlank { "AKTUELLT" }
            list.addView(label(listTitle.uppercase(java.util.Locale("sv", "SE")), 13, accent, true).apply { gravity = Gravity.LEFT; setPadding(0, 0, 0, 5) })
            for (index in 0 until minOf(entries.length(), 8)) {
                val entry = entries.optJSONObject(index) ?: continue
                val line = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 8, 0, 8) }
                val details = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
                details.addView(label(feedValue(entry, "title", "name", "label").ifBlank { "Post ${index + 1}" }, 17, white, true).apply { gravity = Gravity.LEFT; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
                val description = feedValue(entry, "subtitle", "description", "organization_name", "detail")
                if (description.isNotBlank()) details.addView(label(description, 13, muted, false).apply { gravity = Gravity.LEFT; setPadding(0, 2, 0, 0); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
                line.addView(details, LinearLayout.LayoutParams(0, -2, 1f))
                val status = feedValue(entry, "status", "severity", "value")
                if (status.isNotBlank()) {
                    val normalized = status.lowercase(java.util.Locale.ROOT)
                    val color = when {
                        listOf("critical", "error", "offline", "failed", "kritisk", "fel").any(normalized::contains) -> Color.rgb(255, 128, 128)
                        listOf("warning", "pending", "varning", "väntar").any(normalized::contains) -> Color.rgb(255, 194, 14)
                        listOf("online", "healthy", "ok", "success", "frisk").any(normalized::contains) -> accent
                        else -> white
                    }
                    line.addView(label(status, 14, color, true).apply { gravity = Gravity.RIGHT })
                }
                list.addView(line)
                if (index < minOf(entries.length(), 8) - 1) list.addView(View(this).apply { setBackgroundColor(Color.rgb(57, 68, 84)) }, LinearLayout.LayoutParams(-1, 1))
            }
            val scroll = android.widget.ScrollView(this).apply { isFillViewport = false; addView(list) }
            page.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        } else if (metrics.length() == 0) {
            val message = feedValue(payload, "message", "value", "text")
            page.addView(label(message.ifBlank { "Feeden är ansluten men innehåller inga mätvärden ännu." }, 21, white, false).apply {
                gravity = Gravity.CENTER
                setPadding(24, 24, 24, 24)
            }, LinearLayout.LayoutParams(-1, 0, 1f))
        }

        page.addView(label("Senast hämtad från källan · skärmen uppdaterar feeden automatiskt", 11, muted, false).apply { gravity = Gravity.LEFT }, LinearLayout.LayoutParams(-1, 32))
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
    }

    private fun showPulseDashboard(item: JSONObject, payload: JSONObject) {
        root.removeAllViews()
        val midnight = Color.rgb(20, 11, 38)
        val dawn = Color.rgb(42, 20, 80)
        val spark = Color.rgb(255, 194, 14)
        val danger = Color.rgb(255, 128, 128)
        val white = Color.WHITE
        val global = payload.optJSONObject("global") ?: JSONObject()
        val generatedAt = payload.optString("generated_at")
        val dataAgeSeconds = runCatching { java.time.Duration.between(Instant.parse(generatedAt), Instant.now()).seconds.coerceAtLeast(0) }.getOrNull()
        val stale = dataAgeSeconds == null || dataAgeSeconds > 90
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(38, 24, 38, 24)
            setBackgroundColor(midnight)
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val logo = ImageView(this).apply {
            setImageResource(R.drawable.dizparc_logo_white)
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.FIT_START
        }
        header.addView(logo, LinearLayout.LayoutParams(190, 62))
        val heading = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 0, 0, 0)
        }
        heading.addView(label("Pulse · Live operations", 24, white, true).apply { gravity = Gravity.LEFT })
        heading.addView(label("Överblick från NinjaRMM och Pulse", 14, Color.rgb(220, 214, 230), false).apply {
            gravity = Gravity.LEFT
            setPadding(0, 3, 0, 0)
        })
        header.addView(heading, LinearLayout.LayoutParams(0, -2, 1f))
        val freshness = when {
            dataAgeSeconds == null -> "DATATID OKÄND"
            stale -> "DATA ÄLDRE · ${dataAgeSeconds.div(60)} MIN"
            else -> "LIVE · ${generatedAt.take(16).replace('T', ' ')} UTC"
        }
        header.addView(label(freshness, 12, if (stale) danger else spark, true))
        page.addView(header, LinearLayout.LayoutParams(-1, 72))

        val stats = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 12, 0, 18)
        }
        val kpis = listOf(
            "KUNDER" to global.optString("total_customers", "0"),
            "ENHETER" to global.optString("total_devices", "0"),
            "ONLINE" to global.optString("devices_online", "0"),
            "KRITISKA LARM" to global.optString("critical_alerts", "0"),
            "SNITTHÄLSA" to global.optString("avg_health_score", "0")
        )
        kpis.forEach { (name, value) ->
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(18, 12, 18, 12)
                setBackgroundColor(dawn)
            }
            card.addView(label(name, 12, Color.rgb(224, 215, 240), true).apply { gravity = Gravity.LEFT })
            card.addView(label(value, 30, if (name == "KRITISKA LARM" && value.toIntOrNull()?.let { it > 0 } == true) Color.rgb(255, 194, 14) else white, true).apply {
                gravity = Gravity.LEFT
                setPadding(0, 5, 0, 0)
            })
            val params = LinearLayout.LayoutParams(0, 76, 1f).apply {
                if (name != "SNITTHÄLSA") rightMargin = 10
            }
            stats.addView(card, params)
        }
        page.addView(stats, LinearLayout.LayoutParams(-1, 108))

        val columns = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val customerColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            setBackgroundColor(dawn)
        }
        customerColumn.addView(label("KUNDHÄLSA", 14, spark, true).apply { gravity = Gravity.LEFT })
        val orgs = payload.optJSONArray("organizations") ?: JSONArray()
        for (i in 0 until minOf(orgs.length(), 8)) {
            val org = orgs.optJSONObject(i) ?: continue
            val score = org.optInt("health_score", 0)
            val line = "${org.optString("name")}  ·  $score  ·  ${org.optString("devices_online")}/${org.optString("total_devices")} online  ·  ${org.optString("critical_alerts")} larm"
            customerColumn.addView(label(line, 15, if (score < 60) spark else white, false).apply {
                gravity = Gravity.LEFT
                setPadding(0, 13, 0, 0)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            })
        }
        columns.addView(customerColumn, LinearLayout.LayoutParams(0, -1, 1.25f).apply { rightMargin = 12 })

        val alertColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            setBackgroundColor(dawn)
        }
        alertColumn.addView(label("AKTIVA LARM", 14, spark, true).apply { gravity = Gravity.LEFT })
        val alerts = payload.optJSONArray("alerts") ?: JSONArray()
        if (alerts.length() == 0) {
            alertColumn.addView(label("Inga aktiva larm", 17, Color.rgb(113, 191, 68), true).apply {
                gravity = Gravity.LEFT
                setPadding(0, 16, 0, 0)
            })
        } else {
            for (i in 0 until minOf(alerts.length(), 6)) {
                val alert = alerts.optJSONObject(i) ?: continue
                val severity = alert.optString("severity").uppercase(java.util.Locale("sv", "SE"))
                val text = "$severity  ·  ${alert.optString("organization_name")}  ·  ${alert.optString("title")}"
                alertColumn.addView(label(text, 14, white, false).apply {
                    gravity = Gravity.LEFT
                    setPadding(0, 11, 0, 0)
                    maxLines = 2
                    ellipsize = android.text.TextUtils.TruncateAt.END
                })
            }
        }
        columns.addView(alertColumn, LinearLayout.LayoutParams(0, -1, 1f))
        page.addView(columns, LinearLayout.LayoutParams(-1, 0, 1f))

        val patch = payload.optJSONObject("patch_stats") ?: JSONObject()
        val latestSync = payload.optJSONArray("sync_jobs")?.optJSONObject(0)
        val syncStatus = latestSync?.optString("status")?.takeIf { !it.isNullOrBlank() && it != "null" } ?: "Inga körningar"
        val syncTime = latestSync?.optString("completed_at")?.takeIf { !it.isNullOrBlank() && it != "null" }
            ?: latestSync?.optString("started_at")?.takeIf { !it.isNullOrBlank() && it != "null" }
        val os = payload.optJSONArray("os_breakdown") ?: JSONArray()
        val osSummary = (0 until minOf(os.length(), 4)).mapNotNull { index ->
            os.optJSONObject(index)?.let { "${it.optString("os_family")} ${it.optString("count")}" }
        }.joinToString("  ·  ")
        val footer = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val patchCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 10, 18, 10)
            setBackgroundColor(dawn)
        }
        patchCard.addView(label("PATCHSTATUS", 11, spark, true).apply { gravity = Gravity.LEFT })
        patchCard.addView(label(
            "${patch.optString("pending", "0")} väntande  ·  ${patch.optString("critical_pending", "0")} kritiska  ·  ${patch.optString("compliance_pct", "0")}% uppdaterade",
            16, white, false
        ).apply { gravity = Gravity.LEFT; setPadding(0, 5, 0, 0) })
        footer.addView(patchCard, LinearLayout.LayoutParams(0, 78, 1f).apply { rightMargin = 10 })

        val syncCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 10, 18, 10)
            setBackgroundColor(dawn)
        }
        syncCard.addView(label("SYNK & ENHETER", 11, spark, true).apply { gravity = Gravity.LEFT })
        val syncDetail = listOfNotNull(syncStatus, syncTime?.take(16)?.replace('T', ' '), osSummary.takeIf { it.isNotBlank() }).joinToString("  ·  ")
        syncCard.addView(label(syncDetail, 14, white, false).apply { gravity = Gravity.LEFT; setPadding(0, 5, 0, 0); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
        footer.addView(syncCard, LinearLayout.LayoutParams(0, 78, 1f))
        page.addView(footer, LinearLayout.LayoutParams(-1, 86).apply { topMargin = 10 })
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
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

    private fun showOperatingHoursScreen() {
        advanceTask?.let(handler::removeCallbacks)
        clockTask?.let(handler::removeCallbacks)
        playerVideo?.stopPlayback()
        dashboardView?.stopLoading()
        dashboardView?.destroy()
        clearSecondaryZone()
        playerVideo = null
        dashboardView = null
        root.removeAllViews()
        root.setBackgroundColor(Color.BLACK)
        currentSlide = null
        currentTitle = "Utanför öppettider"
        currentBody = ""
        currentKind = "sleep"
        currentSourceUrl = null
        reportHeartbeat(null, currentTitle, currentBody, currentKind, currentSourceUrl)
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
        scheduleTask?.let(handler::removeCallbacks)
        playerVideo?.stopPlayback()
        worker.shutdownNow()
        super.onDestroy()
    }
}
