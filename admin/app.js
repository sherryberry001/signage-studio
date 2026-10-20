import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

const $ = (s, root = document) => root.querySelector(s);
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const authView = $('#authView');
const appView = $('#appView');
const screenList = $('#screenList');
const notice = $('#setupNotice');
let currentUser = null;
let screens = [];
let playlists = [];
let statusTimer = null;
let screensLoadId = 0;

$('#year').textContent = new Date().getFullYear();

function configured() {
  return !SUPABASE_URL.includes('YOUR-PROJECT') && !SUPABASE_ANON_KEY.includes('YOUR_');
}

function showNotice(message) {
  notice.textContent = message;
  notice.classList.remove('hidden');
}

function toast(message, isError = false) {
  const el = document.createElement('div');
  el.className = `toast${isError ? ' error' : ''}`;
  el.textContent = message;
  document.body.append(el);
  setTimeout(() => el.remove(), 3500);
}

function esc(value = '') {
  return String(value).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' })[c]);
}

function shortCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return Array.from(bytes, b => alphabet[b % alphabet.length]).join('');
}

function setSession(user) {
  const sameUser = Boolean(user && currentUser?.id === user.id);
  currentUser = user;
  authView.classList.toggle('hidden', Boolean(user));
  appView.classList.toggle('hidden', !user);
  if (user) {
    $('#userEmail').textContent = user.email || 'Admin';
    if (!sameUser) loadScreens();
    clearInterval(statusTimer);
    statusTimer = setInterval(refreshScreenStatus, 5000);
  } else {
    screensLoadId++;
    screens = [];
    screenList.replaceChildren();
    clearInterval(statusTimer);
  }
}

function checkConfig() {
  if (!configured()) {
    showNotice('Lägg in Supabase URL och anon key i admin/config.js efter att du skapat projektet. Installationsstegen finns i README.');
    $('#loginForm button').disabled = true;
  }
}

$('#loginForm').addEventListener('submit', async event => {
  event.preventDefault();
  const email = $('#email').value.trim();
  $('#authMessage').textContent = 'Skickar inloggningslänk …';
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: location.href }
  });
  $('#authMessage').textContent = error ? error.message : 'Länken är skickad. Öppna den i samma webbläsare.';
});

$('#signOut').addEventListener('click', async () => {
  await supabase.auth.signOut();
  setSession(null);
});

supabase.auth.onAuthStateChange((_event, session) => setSession(session?.user || null));
supabase.auth.getSession().then(({ data }) => setSession(data.session?.user || null));

$('#createScreenForm').addEventListener('submit', async event => {
  event.preventDefault();
  const name = $('#screenName').value.trim();
  const pair_code = shortCode();
  const { error } = await supabase.from('screens').insert({ name, pair_code, is_active: true });
  if (error) return toast(error.message, true);
  $('#screenName').value = '';
  toast('Skärmen skapades. Ange parkopplingskoden i TV-appen.');
  await loadScreens();
});

$('#createPlaylistForm').addEventListener('submit', async event => {
  event.preventDefault();
  const form = event.currentTarget;
  const name = $('#playlistName').value.trim();
  const { error } = await supabase.from('playlists').insert({ name });
  if (error) return toast(error.message, true);
  form.reset();
  toast('Spellistan skapades. Tilldela den till en eller flera skärmar.');
  await loadScreens();
});

async function loadScreens() {
  if (!currentUser) return;
  const loadId = ++screensLoadId;
  const userId = currentUser.id;
  const [{ data, error }, { data: playlistData, error: playlistError }] = await Promise.all([
    supabase.from('screens').select('*').order('created_at', { ascending: false }),
    supabase.from('playlists').select('*').order('name', { ascending: true })
  ]);
  if (loadId !== screensLoadId || currentUser?.id !== userId) return;
  if (error) return toast(error.message, true);
  if (playlistError) return toast(playlistError.message, true);
  const nextScreens = data || [];
  const nextPlaylists = playlistData || [];
  const slideResults = await Promise.all(nextScreens.map(screen =>
    supabase.from('slides').select('*')
      .eq(screen.playlist_id ? 'playlist_id' : 'screen_id', screen.playlist_id || screen.id)
      .order('sort_order', { ascending: true })
  ));
  if (loadId !== screensLoadId || currentUser?.id !== userId) return;
  screens = nextScreens;
  playlists = nextPlaylists;
  $('#emptyState').classList.toggle('hidden', screens.length > 0);
  screenList.replaceChildren(...screens.map((screen, index) => {
    const { data: slides, error: slideError } = slideResults[index];
    if (slideError) toast(slideError.message, true);
    return renderScreen(screen, slides || []);
  }));
  updateScreenSummary();
}

function isOnline(screen) {
  return Boolean(screen.last_seen_at && Date.now() - new Date(screen.last_seen_at).getTime() < 45_000);
}

function updateScreenSummary() {
  const online = screens.filter(isOnline).length;
  $('#screenCount').textContent = `${screens.length} ${screens.length === 1 ? 'skärm' : 'skärmar'} · ${online} online`;
}

async function refreshScreenStatus() {
  if (!currentUser) return;
  const { data, error } = await supabase.from('screens')
    .select('id,last_seen_at,current_title,current_body,current_kind,current_source_url,current_slide_id,forced_slide_id');
  if (error) return;
  const liveById = new Map((data || []).map(item => [item.id, item]));
  screens = screens.map(screen => ({ ...screen, ...(liveById.get(screen.id) || {}) }));
  updateScreenSummary();
  for (const screen of screens) {
    const card = screenList.querySelector(`[data-screen-id="${CSS.escape(screen.id)}"]`);
    if (!card) continue;
    const online = isOnline(screen);
    const status = card.querySelector('.screen-live-status');
    if (status) {
      status.classList.toggle('online', online);
      status.classList.toggle('offline', !online);
      status.querySelector('.status-label').textContent = online ? 'Online nu' : 'Offline';
      status.querySelector('.last-seen').textContent = screen.last_seen_at
        ? `Senast kontakt ${new Date(screen.last_seen_at).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}`
        : 'Spelaren har inte rapporterat ännu';
    }
    const current = card.querySelector('.current-content');
    if (current) {
      current.querySelector('.current-title').textContent = online ? (screen.current_title || 'Väntar på innehåll') : 'Ingen livekontakt';
      current.querySelector('.current-kind').textContent = online ? kindLabel(screen.current_kind) : 'Skärmen är offline';
      current.classList.toggle('stale', !online);
      updateCurrentPreview(current.querySelector('.current-preview'), screen, online);
    }
    const forceButton = card.querySelector('.return-playlist');
    if (forceButton) forceButton.classList.toggle('hidden', !screen.forced_slide_id);
    card.querySelectorAll('[data-slide-action="show-now"]').forEach(button => {
      button.classList.toggle('selected', button.dataset.id === screen.forced_slide_id);
      button.textContent = button.dataset.id === screen.forced_slide_id ? 'Visas nu' : 'Visa nu';
    });
  }
}

function kindLabel(kind) {
  return ({ text: 'Textmeddelande', video: 'Video', clock: 'Klocka & datum', feed: 'JSON-feed', web: 'Webbsida / live dashboard' })[kind] || kind || '—';
}

function updateCurrentPreview(container, screen, online) {
  if (!container) return;
  const key = online ? `${screen.current_kind || ''}|${screen.current_title || ''}|${screen.current_body || ''}|${screen.current_source_url || ''}` : 'offline';
  if (container.dataset.previewKey === key) return;
  container.dataset.previewKey = key;
  container.replaceChildren();
  if (!online) {
    container.textContent = 'Ingen signal från spelaren';
    return;
  }
  if (screen.current_kind === 'web' && /^https?:\/\//i.test(screen.current_source_url || '')) {
    const frame = document.createElement('iframe');
    frame.src = screen.current_source_url;
    frame.title = `Förhandsvisning: ${screen.current_title || 'webbsida'}`;
    frame.setAttribute('sandbox', 'allow-scripts allow-forms');
    frame.referrerPolicy = 'no-referrer';
    container.append(frame);
  } else if (screen.current_kind === 'video' && /^https:\/\//i.test(screen.current_source_url || '')) {
    const video = document.createElement('video');
    video.src = screen.current_source_url;
    video.muted = true;
    video.autoplay = true;
    video.loop = true;
    video.playsInline = true;
    container.append(video);
  } else {
    const text = document.createElement('div');
    text.className = 'preview-copy';
    text.textContent = screen.current_body || (screen.current_kind === 'clock' ? 'Klocka och datum' : screen.current_title || 'Väntar på innehåll');
    container.append(text);
  }
}

function renderScreen(screen, slides) {
  const card = document.createElement('article');
  card.className = 'screen-card';
  card.dataset.screenId = screen.id;
  const pending = screen.pair_code ? `<span class="pair-pill">KOD ${esc(screen.pair_code)}</span>` : '<span class="pair-pill">PARKOPPLAD</span>';
  const playlistOptions = [`<option value="">Skärmens egen spellista</option>`, ...playlists.map(playlist =>
    `<option value="${playlist.id}" ${playlist.id === screen.playlist_id ? 'selected' : ''}>${esc(playlist.name)}</option>`
  )].join('');
  card.innerHTML = `
    <div class="screen-head">
      <div class="screen-title-wrap"><div class="screen-icon">▣</div><div><div class="screen-name">${esc(screen.name)}</div><div class="screen-meta">${screen.is_active ? 'AKTIV' : 'PAUSAD'} · ${slides.length} objekt</div></div></div>
      <div class="screen-actions">${pending}<button class="button ghost small toggle-screen">${screen.is_active ? 'Pausa' : 'Aktivera'}</button><button class="button ghost small delete-screen">Ta bort</button></div>
    </div>
    <div class="screen-status-row"><div class="screen-live-status ${isOnline(screen) ? 'online' : 'offline'}"><span class="status-indicator"></span><span class="status-label">${isOnline(screen) ? 'Online nu' : 'Offline'}</span><span class="last-seen">${screen.last_seen_at ? `Senast kontakt ${new Date(screen.last_seen_at).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}` : 'Spelaren har inte rapporterat ännu'}</span></div><div class="current-content ${isOnline(screen) ? '' : 'stale'}"><span class="current-content-label">VISAS JUST NU</span><strong class="current-title">${esc(isOnline(screen) ? (screen.current_title || 'Väntar på innehåll') : 'Ingen livekontakt')}</strong><span class="current-kind">${esc(isOnline(screen) ? kindLabel(screen.current_kind) : 'Skärmen är offline')}</span><div class="current-preview"></div></div></div>
    <div class="screen-body">
      <p class="pair-help">${screen.pair_code ? 'Öppna Signage Player på TV:n och skriv koden ovan. Koden kan bara användas en gång.' : 'TV:n är parkopplad. Nytt innehåll synkas automatiskt och sparas lokalt för offlinevisning.'}</p>
      <label class="playlist-assignment">Spellista för den här skärmen<select class="screen-playlist">${playlistOptions}</select><span>En spellista kan delas av flera skärmar.</span></label>
      <div class="playlist-control"><div><strong>Visningsläge</strong><span>${screen.forced_slide_id ? 'En post är vald manuellt.' : 'TV:n roterar innehållet i spellistan.'}</span></div><button class="button ghost small return-playlist ${screen.forced_slide_id ? '' : 'hidden'}">Återgå till spellistan</button></div>
      <div class="playlist">${slides.map((slide, index) => renderSlide(slide, index, slides.length)).join('') || '<div class="slide-sub">Spellistan är tom. Lägg till ett objekt nedan.</div>'}</div>
      <div class="slide-add-grid">
        <div class="add-box"><h3>Textmeddelande</h3><form class="text-slide-form add-text"><input name="title" maxlength="80" placeholder="Rubrik" required /><textarea name="body" maxlength="1200" placeholder="Meddelande" required></textarea><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="15" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Publicera text</button></div><div class="inline-fields"><input class="schedule-input" name="from" type="datetime-local" aria-label="Visa från" /><input class="schedule-input" name="until" type="datetime-local" aria-label="Visa till" /></div></form></div>
        <div class="add-box"><h3>Video eller JSON-feed</h3><form class="text-slide-form add-source"><select name="kind"><option value="video">Video (MP4-länk eller fil)</option><option value="feed">JSON-feed</option></select><input name="title" maxlength="80" placeholder="Namn på innehåll" required /><input name="url" type="url" placeholder="https://…" /><label class="file-label">För video kan du också välja MP4-fil <input name="file" type="file" accept="video/mp4,video/webm,video/quicktime" /></label><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="30" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till</button></div><div class="inline-fields"><input class="schedule-input" name="from" type="datetime-local" aria-label="Visa från" /><input class="schedule-input" name="until" type="datetime-local" aria-label="Visa till" /></div></form></div>
        <div class="add-box"><h3>Klocka & datum</h3><form class="text-slide-form add-clock"><input name="title" maxlength="80" placeholder="Rubrik, till exempel Välkommen" /><input name="body" maxlength="180" placeholder="Valfri underrad" /><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="20" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till klocka</button></div><div class="inline-fields"><input class="schedule-input" name="from" type="datetime-local" aria-label="Visa från" /><input class="schedule-input" name="until" type="datetime-local" aria-label="Visa till" /></div></form></div>
        <div class="add-box"><h3>Webbsida eller live-dashboard</h3><form class="text-slide-form add-web"><input name="title" maxlength="80" placeholder="Namn på sidan" required /><input name="url" type="url" placeholder="https://…" required /><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="60" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till sida</button></div><div class="inline-fields"><input class="schedule-input" name="from" type="datetime-local" aria-label="Visa från" /><input class="schedule-input" name="until" type="datetime-local" aria-label="Visa till" /></div></form></div>
      </div>
    </div>`;
  updateCurrentPreview(card.querySelector('.current-preview'), screen, isOnline(screen));

  card.querySelector('.toggle-screen').addEventListener('click', async () => {
    const { error } = await supabase.from('screens').update({ is_active: !screen.is_active }).eq('id', screen.id);
    if (error) toast(error.message, true); else loadScreens();
  });
  card.querySelector('.screen-playlist').addEventListener('change', async event => {
    const playlist_id = event.currentTarget.value || null;
    const { error } = await supabase.from('screens').update({ playlist_id, forced_slide_id: null }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast(playlist_id ? 'Spellistan tilldelades skärmen.' : 'Skärmen använder sin egen spellista.');
    await loadScreens();
  });
  card.querySelector('.delete-screen').addEventListener('click', async () => {
    if (!confirm(`Ta bort skärmen “${screen.name}” och dess spellista?`)) return;
    const { error } = await supabase.from('screens').delete().eq('id', screen.id);
    if (error) toast(error.message, true); else { toast('Skärmen togs bort.'); loadScreens(); }
  });
  card.querySelector('.add-text').addEventListener('submit', event => addSlide(event, screen, 'text'));
  card.querySelector('.add-clock').addEventListener('submit', event => addSlide(event, screen, 'clock'));
  card.querySelector('.add-source').addEventListener('submit', event => addSource(event, screen, slides.length));
  card.querySelector('.add-web').addEventListener('submit', event => addWeb(event, screen));
  card.querySelectorAll('[data-slide-action]').forEach(button => button.addEventListener('click', () => slideAction(button, screen, slides)));
  card.querySelector('.return-playlist').addEventListener('click', async () => setForcedSlide(screen, null));
  return card;
}

function renderSlide(slide, index, count) {
  const detail = slide.kind === 'text' ? (slide.body || '') : slide.kind === 'clock' ? 'Lokal tid och datum' : (slide.source_url || 'Ingen källa');
  return `<div class="slide-row"><div class="slide-thumb">${slide.kind === 'video' ? '▶' : slide.kind === 'feed' ? '↗' : slide.kind === 'web' ? '↗' : slide.kind === 'clock' ? '◷' : 'T'}</div><div><div class="slide-title">${esc(slide.title || kindLabel(slide.kind))}</div><div class="slide-sub">${esc(kindLabel(slide.kind))} · ${slide.duration_seconds}s · ${esc(detail)}</div></div><div class="slide-buttons"><button class="button ghost small show-now" data-slide-action="show-now" data-id="${slide.id}">Visa nu</button><button class="icon-button" data-slide-action="up" data-id="${slide.id}" ${index === 0 ? 'disabled' : ''}>↑</button><button class="icon-button" data-slide-action="down" data-id="${slide.id}" ${index === count - 1 ? 'disabled' : ''}>↓</button><button class="icon-button delete" data-slide-action="delete" data-id="${slide.id}">×</button></div></div>`;
}

async function setForcedSlide(screen, slideId) {
  const { error } = await supabase.from('screens').update({ forced_slide_id: slideId }).eq('id', screen.id);
  if (error) return toast(error.message, true);
  toast(slideId ? 'Skärmen byter innehåll inom några sekunder.' : 'Spellistan aktiveras igen.');
  await loadScreens();
}

async function addWeb(event, screen) {
  event.preventDefault();
  const form = event.currentTarget;
  const f = new FormData(form);
  const source_url = String(f.get('url') || '').trim();
  if (!/^https?:\/\//i.test(source_url)) return toast('Ange en adress som börjar med HTTPS eller HTTP.', true);
  const { error } = await supabase.from('slides').insert({ ...contentOwner(screen), kind: 'web', title: String(f.get('title') || '').trim(), source_url, duration_seconds: Number(f.get('duration')) || 60, sort_order: await nextOrder(screen), is_active: true, ...scheduleValues(f) });
  if (error) return toast(error.message, true);
  form.reset(); toast('Webbsidan lades till i spellistan.'); await loadScreens();
}

function contentOwner(screen) {
  return screen.playlist_id ? { screen_id: null, playlist_id: screen.playlist_id } : { screen_id: screen.id, playlist_id: null };
}

async function nextOrder(screen) {
  const column = screen.playlist_id ? 'playlist_id' : 'screen_id';
  const value = screen.playlist_id || screen.id;
  const { data, error } = await supabase.from('slides').select('sort_order').eq(column, value).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  if (error) throw error;
  return (data?.sort_order ?? -1) + 1;
}

function scheduleValues(formData) {
  const toIso = key => {
    const value = String(formData.get(key) || '');
    return value ? new Date(value).toISOString() : null;
  };
  return { active_from: toIso('from'), active_until: toIso('until') };
}

async function addSlide(event, screen, kind) {
  event.preventDefault();
  const form = event.currentTarget;
  const f = new FormData(form);
  const values = { ...contentOwner(screen), kind, title: String(f.get('title') || '').trim(), body: String(f.get('body') || '').trim(), duration_seconds: Number(f.get('duration')) || 15, sort_order: await nextOrder(screen), is_active: true, ...scheduleValues(f) };
  const { error } = await supabase.from('slides').insert(values);
  if (error) return toast(error.message, true);
  form.reset(); toast('Innehållet publicerades.'); await loadScreens();
}

async function addSource(event, screen) {
  event.preventDefault();
  const form = event.currentTarget;
  const f = new FormData(form);
  const kind = String(f.get('kind'));
  let source_url = String(f.get('url') || '').trim();
  const file = f.get('file');
  if (kind === 'feed' && file instanceof File && file.size > 0) return toast('JSON-feed använder en URL. Välj en videofil bara för video.', true);
  if (file instanceof File && file.size > 0) {
    if (file.size > 400 * 1024 * 1024) return toast('Videofilen får vara högst 400 MB i den här versionen.', true);
    const path = `${screen.playlist_id || screen.id}/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g, '_')}`;
    const { error: uploadError } = await supabase.storage.from('signage-assets').upload(path, file, { cacheControl: '0', upsert: false });
    if (uploadError) return toast(uploadError.message, true);
    source_url = supabase.storage.from('signage-assets').getPublicUrl(path).data.publicUrl;
  }
  if (!source_url) return toast('Ange en videolänk, en feed-URL eller välj en videofil.', true);
  const { error } = await supabase.from('slides').insert({ ...contentOwner(screen), kind, title: String(f.get('title') || '').trim(), source_url, duration_seconds: Number(f.get('duration')) || 30, sort_order: await nextOrder(screen), is_active: true, ...scheduleValues(f) });
  if (error) return toast(error.message, true);
  form.reset(); toast('Innehållet publicerades.'); await loadScreens();
}

async function slideAction(button, screen, slides) {
  const id = button.dataset.id;
  const action = button.dataset.slideAction;
  const index = slides.findIndex(item => item.id === id);
  if (action === 'show-now') return setForcedSlide(screen, screen.forced_slide_id === id ? null : id);
  if (action === 'delete') {
    const { error } = await supabase.from('slides').delete().eq('id', id);
    if (error) return toast(error.message, true);
  } else {
    const targetIndex = action === 'up' ? index - 1 : index + 1;
    if (targetIndex < 0 || targetIndex >= slides.length) return;
    const current = slides[index], other = slides[targetIndex];
    const first = await supabase.from('slides').update({ sort_order: other.sort_order }).eq('id', current.id);
    const second = await supabase.from('slides').update({ sort_order: current.sort_order }).eq('id', other.id);
    if (first.error || second.error) return toast((first.error || second.error).message, true);
  }
  await loadScreens();
}

checkConfig();
