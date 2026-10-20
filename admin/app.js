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
let channels = [];
let channelPlaylists = [];
let channelSchedules = [];
let teamMembers = [];
let screenCommands = [];
let mediaLibrary = [];
let currentRole = null;
let statusTimer = null;
let screensLoadId = 0;
const selectedScreenIds = new Set();

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
    if (!sameUser || !currentRole) loadScreens();
    clearInterval(statusTimer);
    statusTimer = setInterval(refreshScreenStatus, 5000);
  } else {
    screensLoadId++;
    screens = [];
    playlists = [];
    channels = [];
    channelPlaylists = [];
    channelSchedules = [];
    teamMembers = [];
    screenCommands = [];
    mediaLibrary = [];
    selectedScreenIds.clear();
    currentRole = null;
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
  const normalizedName = name.toLocaleLowerCase('sv-SE');
  const existing = screens.find(screen => String(screen.name || '').trim().toLocaleLowerCase('sv-SE') === normalizedName);
  if (existing) {
    if (!confirm(`”${existing.name}” finns redan. Skapa en ny parkopplingskod till samma skärm och behåll dess inställningar? Välj Avbryt om du vill lägga till en annan TV och byt då namn så att profilerna går att skilja åt.`)) return;
    const { data: code, error } = await supabase.rpc('renew_screen_pairing_code', { input_screen_id: existing.id });
    if (error) return toast(error.message, true);
    $('#screenName').value = '';
    toast(`Ny parkopplingskod för ${existing.name}: ${code}`);
    await loadScreens();
    return;
  }
  const pair_code = shortCode();
  const submit = event.currentTarget.querySelector('button[type="submit"]');
  submit.disabled = true;
  try {
    const { error } = await supabase.from('screens').insert({ name, pair_code, is_active: true });
    if (error) return toast(error.message, true);
    $('#screenName').value = '';
    toast('Skärmen skapades. Ange parkopplingskoden i TV-appen.');
    await loadScreens();
  } finally {
    submit.disabled = false;
  }
});

$('#teamRoleForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (currentRole !== 'admin') return;
  const { error } = await supabase.rpc('set_team_member', { input_email: $('#teamEmail').value.trim(), input_role: $('#teamRole').value });
  if (error) return toast(error.message, true);
  event.currentTarget.reset();
  toast('Teamrollen uppdaterades.');
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

$('#createChannelForm').addEventListener('submit', async event => {
  event.preventDefault();
  const name = $('#channelName').value.trim();
  const playlist_id = $('#channelPlaylist').value;
  const { error } = await supabase.from('channels').insert({ name, playlist_id });
  if (error) return toast(error.message, true);
  event.currentTarget.reset();
  toast('Kanalen skapades med sin första spellista. Lägg till fler spellistor och scheman nedan.');
  await loadScreens();
});

$('#channelManagementList').addEventListener('submit', async event => {
  const form = event.target.closest('.channel-playlist-form');
  if (!form) return;
  event.preventDefault();
  const values = new FormData(form);
  const schedule = scheduleValues(values);
  if (!schedule) return;
  const channel_id = form.dataset.channelId;
  const playlist_id = String(values.get('playlist_id') || '');
  if (channelPlaylists.some(item => item.channel_id === channel_id && item.playlist_id === playlist_id)) return toast('Spellistan finns redan i kanalen.', true);
  const { data: last, error: orderError } = await supabase.from('channel_playlists').select('sort_order').eq('channel_id', channel_id).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  if (orderError) return toast(orderError.message, true);
  const { error } = await supabase.from('channel_playlists').insert({ channel_id, playlist_id, sort_order: (last?.sort_order ?? -1) + 1, priority: Number(values.get('priority')) || 100, ...schedule });
  if (error) return toast(error.message, true);
  toast('Spellistan och dess visningsschema lades till i kanalen.');
  await loadScreens();
});

$('#channelManagementList').addEventListener('click', async event => {
  const button = event.target.closest('[data-channel-playlist-remove]');
  if (!button) return;
  const item = channelPlaylists.find(row => row.id === button.dataset.channelPlaylistRemove);
  if (!item) return;
  const playlist = playlists.find(row => row.id === item.playlist_id);
  if (!confirm(`Ta bort “${playlist?.name || 'spellistan'}” från den här kanalen?`)) return;
  const { error } = await supabase.from('channel_playlists').delete().eq('id', item.id);
  if (error) return toast(error.message, true);
  await loadScreens();
});

$('#mediaSearch').addEventListener('input', renderMediaLibrary);

$('#mediaLibraryForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (!['admin', 'editor'].includes(currentRole)) return;
  const form = event.currentTarget;
  const values = new FormData(form);
  const kind = String(values.get('kind'));
  let source_url = String(values.get('source_url') || '').trim();
  const file = values.get('file');
  if (file instanceof File && file.size > 0) {
    if (kind !== 'video') return toast('Filer i biblioteket stöds just nu för video.', true);
    if (file.size > 400 * 1024 * 1024) return toast('Videofilen får vara högst 400 MB.', true);
    const path = `library/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g, '_')}`;
    const { error: uploadError } = await supabase.storage.from('signage-assets').upload(path, file, { cacheControl: '0', upsert: false });
    if (uploadError) return toast(uploadError.message, true);
    source_url = supabase.storage.from('signage-assets').getPublicUrl(path).data.publicUrl;
  }
  const body = String(values.get('body') || '').trim();
  if (['web', 'feed', 'video'].includes(kind) && !/^https?:\/\//i.test(source_url)) return toast('Ange en giltig HTTP- eller HTTPS-källa.', true);
  if (kind === 'text' && !body) return toast('Skriv texten som ska sparas i biblioteket.', true);
  const tags = [...new Set(String(values.get('tags') || '').split(',').map(tag => tag.trim().toLocaleLowerCase('sv-SE')).filter(Boolean))];
  const { error } = await supabase.from('media_library').insert({ kind, title: String(values.get('title') || '').trim(), body, source_url: source_url || null, tags });
  if (error) return toast(error.message, true);
  form.reset();
  toast('Innehållet sparades i biblioteket.');
  await loadScreens();
});

async function loadScreens() {
  if (!currentUser) return;
  const loadId = ++screensLoadId;
  const userId = currentUser.id;
  const [
    { data, error },
    { data: playlistData, error: playlistError },
    { data: memberData, error: memberError },
    { data: channelData, error: channelError },
    { data: channelPlaylistData, error: channelPlaylistError },
    { data: channelScheduleData, error: channelScheduleError },
    { data: commandData, error: commandError },
    { data: mediaData, error: mediaError }
  ] = await Promise.all([
    supabase.from('screens').select('*').order('created_at', { ascending: false }),
    supabase.from('playlists').select('*').order('name', { ascending: true }),
    supabase.from('team_members').select('user_id,email,role').order('email', { ascending: true }),
    supabase.from('channels').select('*').order('name', { ascending: true }),
    supabase.from('channel_playlists').select('*').order('channel_id').order('sort_order'),
    supabase.from('screen_channel_schedules').select('*').order('priority', { ascending: true }),
    supabase.from('screen_commands').select('id,screen_id,command,status,created_at,completed_at,error_message').order('created_at', { ascending: false }).limit(100),
    supabase.from('media_library').select('*').order('updated_at', { ascending: false }).limit(300)
  ]);
  if (loadId !== screensLoadId || currentUser?.id !== userId) return;
  if (error) return toast(error.message, true);
  if (playlistError) return toast(playlistError.message, true);
  if (memberError) return toast(memberError.message, true);
  if (channelError) return toast(channelError.message, true);
  if (channelPlaylistError) return toast(channelPlaylistError.message, true);
  if (channelScheduleError) return toast(channelScheduleError.message, true);
  if (commandError) return toast(commandError.message, true);
  if (mediaError && mediaError.code !== '42P01') return toast(mediaError.message, true);
  teamMembers = memberData || [];
  currentRole = teamMembers.find(member => member.user_id === userId)?.role || null;
  updateRoleVisibility();
  if (!currentRole) {
    showNotice('Det här kontot saknar en teamroll. Be en administratör att tilldela åtkomst.');
    screens = [];
    playlists = [];
    screenList.replaceChildren();
    $('#emptyState').classList.add('hidden');
    updateScreenSummary();
    return;
  }
  notice.classList.add('hidden');
  const nextScreens = data || [];
  const nextPlaylists = playlistData || [];
  const nextChannels = channelData || [];
  const assignedChannelIds = new Set((channelScheduleData || []).map(item => item.channel_id));
  const assignedChannelPlaylistIds = [...new Set((channelPlaylistData || []).filter(item => assignedChannelIds.has(item.channel_id)).map(item => item.playlist_id))];
  const { data: channelSlideData, error: channelSlideError } = assignedChannelPlaylistIds.length
    ? await supabase.from('slides').select('*').in('playlist_id', assignedChannelPlaylistIds).order('sort_order', { ascending: true })
    : { data: [], error: null };
  if (channelSlideError) return toast(channelSlideError.message, true);
  const slideResults = await Promise.all(nextScreens.map(screen =>
    supabase.from('slides').select('*')
      .eq(screen.playlist_id ? 'playlist_id' : 'screen_id', screen.playlist_id || screen.id)
      .order('sort_order', { ascending: true })
  ));
  if (loadId !== screensLoadId || currentUser?.id !== userId) return;
  screens = nextScreens;
  playlists = nextPlaylists;
  channels = nextChannels;
  channelPlaylists = channelPlaylistData || [];
  channelSchedules = channelScheduleData || [];
  screenCommands = commandData || [];
  mediaLibrary = mediaData || [];
  updateChannelControls();
  updateChannelManagement();
  renderMediaLibrary();
  $('#emptyState').classList.toggle('hidden', screens.length > 0);
  const duplicateNames = new Map();
  screens.forEach(screen => {
    const key = String(screen.name || '').trim().toLocaleLowerCase('sv-SE');
    duplicateNames.set(key, (duplicateNames.get(key) || 0) + 1);
  });
  const cards = screens.map((screen, index) => {
    const { data: slides, error: slideError } = slideResults[index];
    if (slideError) toast(slideError.message, true);
    const screenChannelIds = new Set(channelSchedules.filter(item => item.screen_id === screen.id).map(item => item.channel_id));
    const screenChannelPlaylistIds = new Set(channelPlaylists.filter(item => screenChannelIds.has(item.channel_id)).map(item => item.playlist_id));
    const screenChannelSlides = (channelSlideData || []).filter(item => screenChannelPlaylistIds.has(item.playlist_id));
    return renderScreen(screen, slides || [], channelSchedules.filter(item => item.screen_id === screen.id), duplicateNames.get(String(screen.name || '').trim().toLocaleLowerCase('sv-SE')) || 1, screenCommands.find(command => command.screen_id === screen.id), screenChannelSlides);
  });
  const grouped = new Map();
  screens.forEach((screen, index) => {
    const key = String(screen.name || '').trim().toLocaleLowerCase('sv-SE') || `screen-${screen.id}`;
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push({ screen, card: cards[index] });
  });
  const rows = [];
  for (const entries of grouped.values()) {
    if (entries.length === 1) { rows.push(entries[0].card); continue; }
    // Keep the live/paired device as the main card; retain all other records in a collapsed group.
    entries.sort((a, b) => Number(isOnline(b.screen)) - Number(isOnline(a.screen))
      || Number(Boolean(a.screen.pair_code)) - Number(Boolean(b.screen.pair_code))
      || Number(Boolean(b.screen.activated_at)) - Number(Boolean(a.screen.activated_at))
      || new Date(b.screen.created_at || 0) - new Date(a.screen.created_at || 0));
    rows.push(entries[0].card);
    const duplicates = document.createElement('details');
    duplicates.className = 'duplicate-screen-group';
    duplicates.innerHTML = `<summary>Fler skärmprofiler för ”${esc(entries[0].screen.name || 'Skärm')}” <span>${entries.length - 1}</span></summary><div class="duplicate-screen-items"></div>`;
    const items = duplicates.querySelector('.duplicate-screen-items');
    entries.slice(1).forEach(entry => items.append(entry.card));
    rows.push(duplicates);
  }
  screenList.replaceChildren(...rows);
  selectedScreenIds.forEach(id => { if (!screens.some(screen => screen.id === id)) selectedScreenIds.delete(id); });
  $('#selectVisibleScreens').classList.toggle('hidden', !['admin', 'editor'].includes(currentRole));
  applyScreenFilters();
  updateBulkScreenActions();
  updateScreenSummary();
  renderTeamMembers();
}

function updateRoleVisibility() {
  const admin = currentRole === 'admin';
  const editor = admin || currentRole === 'editor';
  $('#createScreenForm').classList.toggle('hidden', !admin);
  $('#createPlaylistForm').classList.toggle('hidden', !editor);
  $('#createChannelForm').classList.toggle('hidden', !editor);
  $('.channel-library-bar').classList.toggle('hidden', !editor);
  $('#mediaLibraryPanel').classList.toggle('hidden', !currentRole);
  $('#mediaLibraryForm').classList.toggle('hidden', !editor);
  $('#teamPanel').classList.toggle('hidden', !admin);
}

function updateChannelControls() {
  const select = $('#channelPlaylist');
  if (select) select.innerHTML = `<option value="">Välj spellista</option>${playlists.map(item => `<option value="${esc(item.id)}">${esc(item.name)}</option>`).join('')}`;
}

function updateChannelManagement() {
  const container = $('#channelManagementList');
  if (!container) return;
  const canEdit = ['admin', 'editor'].includes(currentRole);
  container.replaceChildren(...channels.map(channel => {
    const memberships = channelPlaylists.filter(item => item.channel_id === channel.id);
    const usedIds = new Set(memberships.map(item => item.playlist_id));
    const available = playlists.filter(playlist => !usedIds.has(playlist.id));
    const card = document.createElement('article');
    card.className = 'channel-manage-card';
    card.innerHTML = `<div class="channel-manage-heading"><strong>${esc(channel.name)}</strong><span>${memberships.length} spellistor</span></div><div class="channel-playlist-items">${memberships.map(item => { const playlist = playlists.find(value => value.id === item.playlist_id); return `<div class="channel-playlist-item"><div><strong>${esc(playlist?.name || 'Okänd spellista')}</strong><span>Prioritet ${item.priority} · ordning ${item.sort_order + 1} · ${scheduleSummary(item)}</span></div><button class="button ghost small" type="button" data-channel-playlist-remove="${esc(item.id)}" ${canEdit ? '' : 'hidden'}>Ta bort</button></div>`; }).join('') || '<div class="slide-sub">Kanalen har inga spellistor.</div>'}</div>${canEdit ? `<form class="channel-playlist-form" data-channel-id="${esc(channel.id)}"><select name="playlist_id" required aria-label="Spellista att lägga till"><option value="">Lägg till spellista</option>${available.map(item => `<option value="${esc(item.id)}">${esc(item.name)}</option>`).join('')}</select><input name="priority" type="number" min="0" max="1000" value="100" aria-label="Prioritet" />${scheduleFields()}<button class="button ghost small" type="submit" ${available.length ? '' : 'disabled'}>＋ Lägg till i kanalen</button></form>` : ''}`;
    return card;
  }));
  if (!channels.length) container.innerHTML = '<div class="slide-sub">Skapa en kanal och välj dess första spellista ovan.</div>';
}

function renderMediaLibrary() {
  const list = $('#mediaLibraryList');
  if (!list) return;
  const query = ($('#mediaSearch')?.value || '').trim().toLocaleLowerCase('sv-SE');
  const results = mediaLibrary.filter(item => !query || `${item.title} ${(item.tags || []).join(' ')} ${item.kind}`.toLocaleLowerCase('sv-SE').includes(query));
  const options = `<option value="">Välj spellista</option>${playlists.map(playlist => `<option value="${esc(playlist.id)}">${esc(playlist.name)}</option>`).join('')}`;
  list.replaceChildren(...results.map(item => {
    const row = document.createElement('article');
    row.className = 'media-library-row';
    row.innerHTML = `<div class="media-library-main"><div class="media-library-detail"><strong>${esc(item.title)}</strong><span>${esc(kindLabel(item.kind))} · ${item.duration_seconds}s ${item.tags?.length ? `· ${item.tags.map(tag => `#${esc(tag)}`).join(' ')}` : ''}</span><small>${esc(item.source_url || item.body || '')}</small></div><details class="media-library-edit" ${['admin','editor'].includes(currentRole) ? '' : 'hidden'}><summary>Redigera</summary><form data-library-edit="${esc(item.id)}"><input name="title" maxlength="120" value="${esc(item.title)}" required aria-label="Namn" /><input name="source_url" type="url" value="${esc(item.source_url || '')}" placeholder="Källans URL" aria-label="Källans URL" /><textarea name="body" maxlength="1200" placeholder="Textinnehåll" aria-label="Textinnehåll">${esc(item.body || '')}</textarea><input name="tags" maxlength="200" value="${esc((item.tags || []).join(', '))}" placeholder="Taggar, separerade med komma" aria-label="Taggar" /><button class="button ghost small" type="submit">Spara ändringar</button></form></details></div><div class="media-library-actions"><select aria-label="Välj spellista för ${esc(item.title)}" data-library-playlist>${options}</select><button class="button ghost small" type="button" data-library-add="${esc(item.id)}" ${['admin','editor'].includes(currentRole) ? '' : 'disabled'}>Lägg till</button><button class="icon-button delete" type="button" aria-label="Ta bort ${esc(item.title)}" data-library-delete="${esc(item.id)}" ${currentRole === 'admin' || currentRole === 'editor' ? '' : 'hidden'}>×</button></div>`;
    return row;
  }));
  if (!results.length) list.innerHTML = '<div class="slide-sub">Inget innehåll matchar sökningen.</div>';
  list.querySelectorAll('[data-library-edit]').forEach(form => form.addEventListener('submit', async event => {
    event.preventDefault();
    const id = form.dataset.libraryEdit;
    const asset = mediaLibrary.find(item => item.id === id);
    const values = new FormData(form);
    const title = String(values.get('title') || '').trim();
    const source_url = String(values.get('source_url') || '').trim();
    const body = String(values.get('body') || '').trim();
    if (['web', 'feed', 'video'].includes(asset.kind) && !/^https?:\/\//i.test(source_url)) return toast('Ange en giltig HTTP- eller HTTPS-källa.', true);
    if (asset.kind === 'text' && !body) return toast('Textinnehållet får inte vara tomt.', true);
    const tags = [...new Set(String(values.get('tags') || '').split(',').map(tag => tag.trim().toLocaleLowerCase('sv-SE')).filter(Boolean))];
    const { error } = await supabase.from('media_library').update({ title, source_url: source_url || null, body, tags, updated_at: new Date().toISOString() }).eq('id', id);
    if (error) return toast(error.message, true);
    toast('Biblioteksposten och dess spellistereferenser uppdaterades.');
    await loadScreens();
  }));
  list.querySelectorAll('[data-library-add]').forEach(button => button.addEventListener('click', async () => {
    const row = button.closest('.media-library-row');
    const playlist_id = row.querySelector('[data-library-playlist]').value;
    if (!playlist_id) return toast('Välj en spellista först.', true);
    const asset = mediaLibrary.find(item => item.id === button.dataset.libraryAdd);
    const { data: last, error: orderError } = await supabase.from('slides').select('sort_order').eq('playlist_id', playlist_id).order('sort_order', { ascending: false }).limit(1).maybeSingle();
    if (orderError) return toast(orderError.message, true);
    const { error } = await supabase.from('slides').insert({ playlist_id, screen_id: null, library_asset_id: asset.id, kind: asset.kind, title: asset.title, body: asset.body, source_url: asset.source_url, duration_seconds: asset.duration_seconds, sort_order: (last?.sort_order ?? -1) + 1, is_active: true });
    if (error) return toast(error.message, true);
    toast(`“${asset.title}” lades till i spellistan.`);
    await loadScreens();
  }));
  list.querySelectorAll('[data-library-delete]').forEach(button => button.addEventListener('click', async () => {
    const asset = mediaLibrary.find(item => item.id === button.dataset.libraryDelete);
    if (!asset || !confirm(`Ta bort “${asset.title}” från biblioteket? Referenser i spellistor blir fristående innehåll.`)) return;
    const { error } = await supabase.from('media_library').delete().eq('id', asset.id);
    if (error) return toast(error.message, true);
    await loadScreens();
  }));
}

function renderTeamMembers() {
  const list = $('#teamList');
  if (!list) return;
  if (currentRole !== 'admin') { list.replaceChildren(); return; }
  const labels = { admin: 'Admin', editor: 'Redaktör', viewer: 'Läsbehörig' };
  list.innerHTML = teamMembers.map(member => `<div class="team-member" data-user-id="${esc(member.user_id)}"><div class="team-member-identity"><strong>${esc(member.email)}</strong><span>${labels[member.role] || esc(member.role)}</span></div><select class="member-role" aria-label="Roll för ${esc(member.email)}"><option value="editor" ${member.role === 'editor' ? 'selected' : ''}>Redaktör</option><option value="viewer" ${member.role === 'viewer' ? 'selected' : ''}>Läsbehörig</option><option value="admin" ${member.role === 'admin' ? 'selected' : ''}>Admin</option></select><button class="button ghost small save-member">Spara</button><button class="button ghost small remove-member">Ta bort</button></div>`).join('') || '<p class="team-empty">Inga teammedlemmar ännu.</p>';
  list.querySelectorAll('.save-member').forEach(button => button.addEventListener('click', async () => {
    const row = button.closest('.team-member');
    const member = teamMembers.find(item => item.user_id === row.dataset.userId);
    const { error } = await supabase.rpc('set_team_member', { input_email: member.email, input_role: row.querySelector('.member-role').value });
    if (error) return toast(error.message, true);
    toast('Teamrollen uppdaterades.'); await loadScreens();
  }));
  list.querySelectorAll('.remove-member').forEach(button => button.addEventListener('click', async () => {
    const row = button.closest('.team-member');
    const member = teamMembers.find(item => item.user_id === row.dataset.userId);
    if (!confirm(`Ta bort ${member.email} från teamet?`)) return;
    const { error } = await supabase.rpc('remove_team_member', { input_user_id: member.user_id });
    if (error) return toast(error.message, true);
    toast('Teammedlemmen togs bort.'); await loadScreens();
  }));
}

function isOnline(screen) {
  return Boolean(screen.last_seen_at && Date.now() - new Date(screen.last_seen_at).getTime() < 45_000);
}

function updateScreenSummary() {
  const online = screens.filter(isOnline).length;
  $('#screenCount').textContent = `${screens.length} ${screens.length === 1 ? 'skärm' : 'skärmar'} · ${online} online`;
}

$('#screenSearch').addEventListener('input', applyScreenFilters);
$('#screenFilter').addEventListener('change', applyScreenFilters);
$('#selectVisibleScreens').addEventListener('click', () => {
  const visibleCards = [...screenList.querySelectorAll('.screen-card:not(.hidden)')].filter(isCardVisible);
  const allSelected = visibleCards.length > 0 && visibleCards.every(card => selectedScreenIds.has(card.dataset.screenId));
  visibleCards.forEach(card => {
    if (allSelected) selectedScreenIds.delete(card.dataset.screenId);
    else selectedScreenIds.add(card.dataset.screenId);
    const checkbox = card.querySelector('.screen-select');
    if (checkbox) checkbox.checked = selectedScreenIds.has(card.dataset.screenId);
  });
  $('#selectVisibleScreens').textContent = allSelected ? 'Välj synliga' : 'Avmarkera synliga';
  updateBulkScreenActions();
});
$('#clearScreenSelection').addEventListener('click', () => {
  selectedScreenIds.clear();
  screenList.querySelectorAll('.screen-select').forEach(checkbox => { checkbox.checked = false; });
  $('#selectVisibleScreens').textContent = 'Välj synliga';
  updateBulkScreenActions();
});
document.querySelectorAll('[data-bulk-command]').forEach(button => button.addEventListener('click', () => queueBulkPlayerCommand(button.dataset.bulkCommand, button)));

function applyScreenFilters() {
  const query = $('#screenSearch').value.trim().toLocaleLowerCase('sv-SE');
  const filter = $('#screenFilter').value;
  const visible = [];
  screenList.querySelectorAll('.screen-card').forEach(card => {
    const screen = screens.find(item => item.id === card.dataset.screenId);
    const matchesName = !query || `${screen?.name || ''} ${screen?.current_title || ''}`.toLocaleLowerCase('sv-SE').includes(query);
    const matchesStatus = filter === 'all'
      || (filter === 'online' && screen && isOnline(screen))
      || (filter === 'offline' && screen && !isOnline(screen))
      || (filter === 'pairing' && Boolean(screen?.pair_code));
    const show = matchesName && matchesStatus;
    card.classList.toggle('hidden', !show);
    if (show) visible.push(card);
  });
  screenList.querySelectorAll('.duplicate-screen-group').forEach(group => {
    group.classList.toggle('hidden', !group.querySelector('.screen-card:not(.hidden)'));
  });
  $('#visibleScreenCount').textContent = `${visible.length} visade`;
  updateBulkScreenActions();
}

function isCardVisible(card) {
  if (card.classList.contains('hidden')) return false;
  const group = card.closest('.duplicate-screen-group');
  return !group || group.open;
}

function updateBulkScreenActions() {
  const canOperate = currentRole === 'admin' || currentRole === 'editor';
  const actions = $('#bulkScreenActions');
  if (!actions) return;
  actions.classList.toggle('hidden', !canOperate || selectedScreenIds.size === 0);
  $('#selectedScreenCount').textContent = `${selectedScreenIds.size} valda`;
  const visibleCards = [...screenList.querySelectorAll('.screen-card:not(.hidden)')].filter(isCardVisible);
  const allVisibleSelected = visibleCards.length > 0 && visibleCards.every(card => selectedScreenIds.has(card.dataset.screenId));
  $('#selectVisibleScreens').textContent = allVisibleSelected ? 'Avmarkera synliga' : 'Välj synliga';
}

async function queueBulkPlayerCommand(command, button) {
  const selected = screens.filter(screen => selectedScreenIds.has(screen.id));
  const active = selected.filter(screen => screen.is_active);
  if (!active.length) return toast('Markera minst en aktiv skärm.', true);
  button.disabled = true;
  let queued = 0;
  const failures = [];
  try {
    for (const screen of active) {
      const { error } = await supabase.rpc('queue_player_command', { input_screen_id: screen.id, input_command: command });
      if (error) failures.push(screen.name);
      else queued++;
    }
    const action = command === 'restart_player' ? 'omstart' : 'synk';
    toast(`${action}: ${queued} köade${selected.length > active.length ? `, ${selected.length - active.length} pausade hoppades över` : ''}${failures.length ? `, ${failures.length} misslyckades` : ''}.`, failures.length > 0);
    refreshScreenStatus();
  } finally {
    button.disabled = false;
  }
}

async function refreshScreenStatus() {
  if (!currentUser) return;
  const [{ data, error }, { data: commandData, error: commandError }] = await Promise.all([
    supabase.from('screens').select('id,last_seen_at,current_title,current_body,current_kind,current_source_url,current_slide_id,forced_slide_id'),
    supabase.from('screen_commands').select('id,screen_id,command,status,created_at,completed_at,error_message').order('created_at', { ascending: false }).limit(100)
  ]);
  if (error || commandError) return;
  screenCommands = commandData || [];
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
    const commandStatus = card.querySelector('[data-command-status]');
    if (commandStatus) commandStatus.textContent = formatCommandStatus(screenCommands.find(command => command.screen_id === screen.id));
    card.querySelectorAll('[data-slide-action="show-now"]').forEach(button => {
      button.classList.toggle('selected', button.dataset.id === screen.forced_slide_id);
      button.textContent = button.dataset.id === screen.forced_slide_id ? 'Visas nu' : 'Visa nu';
    });
    card.querySelectorAll('.channel-show-now').forEach(button => {
      button.classList.toggle('selected', button.dataset.id === screen.forced_slide_id);
      button.textContent = button.dataset.id === screen.forced_slide_id ? 'Visas nu' : 'Visa nu';
    });
  }
  applyScreenFilters();
}

function kindLabel(kind) {
  return ({ text: 'Textmeddelande', video: 'Video', clock: 'Klocka & datum', feed: 'JSON-feed', web: 'Webbsida / live dashboard', sleep: 'Utanför öppettider' })[kind] || kind || '—';
}

function formatCommandStatus(command) {
  if (!command) return 'Inga fjärrkommandon ännu.';
  const time = command.completed_at || command.created_at;
  const clock = time ? new Date(time).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit' }) : '';
  if (command.status === 'pending') return `Väntar på TV:n · ${clock}`;
  if (command.status === 'running') return `TV:n utför kommandot · ${clock}`;
  if (command.status === 'failed') return `Misslyckades · ${command.error_message || 'okänt fel'} · ${clock}`;
  const label = command.command === 'restart_player' ? 'Omstart kvitterad' : 'Synk kvitterad';
  return `${label} · ${clock}`;
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

function scheduleFields() {
  const days = [['1', 'Mån'], ['2', 'Tis'], ['3', 'Ons'], ['4', 'Tor'], ['5', 'Fre'], ['6', 'Lör'], ['7', 'Sön']];
  return `<div class="schedule-fields"><div class="weekday-picker" aria-label="Återkommande veckodagar">${days.map(([value, label]) => `<label><input type="checkbox" name="weekdays" value="${value}" /><span>${label}</span></label>`).join('')}</div><div class="inline-fields"><input class="schedule-input" name="from" type="datetime-local" aria-label="Visa från datum och tid" /><input class="schedule-input" name="until" type="datetime-local" aria-label="Visa till datum och tid" /></div><div class="inline-fields"><input class="schedule-input" name="daily_from" type="time" aria-label="Visa dagligen från" /><input class="schedule-input" name="daily_until" type="time" aria-label="Visa dagligen till" /></div><span class="schedule-help">Valda dagar och klockslag återkommer varje vecka. Lämna tomt för alltid.</span></div>`;
}

function renderScreen(screen, slides, assignedChannels = [], sameNameCount = 1, latestCommand = null, channelSlides = []) {
  const canAdmin = currentRole === 'admin';
  const canEdit = canAdmin || currentRole === 'editor';
  const card = document.createElement('article');
  card.className = 'screen-card';
  card.dataset.screenId = screen.id;
  const pending = screen.pair_code ? `<span class="pair-pill">KOD ${esc(screen.pair_code)}</span>` : '<span class="pair-pill">PARKOPPLAD</span>';
  const playlistOptions = [`<option value="">Skärmens egen spellista</option>`, ...playlists.map(playlist =>
    `<option value="${playlist.id}" ${playlist.id === screen.playlist_id ? 'selected' : ''}>${esc(playlist.name)}</option>`
  )].join('');
  const operatingDays = [[1, 'Mån'], [2, 'Tis'], [3, 'Ons'], [4, 'Tor'], [5, 'Fre'], [6, 'Lör'], [7, 'Sön']];
  const selectedOperatingDays = screen.operating_weekdays == null ? operatingDays.map(([day]) => day) : screen.operating_weekdays.map(Number);
  const channelOptions = [`<option value="">Välj kanal</option>`, ...channels.map(channel => `<option value="${esc(channel.id)}">${esc(channel.name)} · ${channelPlaylists.filter(item => item.channel_id === channel.id).length} spellistor</option>`)].join('');
  card.innerHTML = `
    <div class="screen-head">
      <div class="screen-title-wrap"><input class="screen-select ${canEdit ? '' : 'hidden'}" type="checkbox" ${selectedScreenIds.has(screen.id) ? 'checked' : ''} aria-label="Välj ${esc(screen.name)}" /><div class="screen-icon">▣</div><div><div class="screen-name">${esc(screen.name)}</div><div class="screen-meta">${screen.is_active ? 'AKTIV' : 'PAUSAD'} · ${slides.length} objekt · skapad ${screen.created_at ? new Date(screen.created_at).toLocaleDateString('sv-SE') : 'okänt datum'}${sameNameCount > 1 ? ` · möjlig dubblett (${sameNameCount} med samma namn)` : ''}</div></div></div>
      <div class="screen-actions">${pending}<button class="button ghost small renew-pairing ${canAdmin ? '' : 'hidden'}">Ny kod</button><button class="button ghost small toggle-screen ${canAdmin ? '' : 'hidden'}">${screen.is_active ? 'Pausa' : 'Aktivera'}</button><button class="button ghost small delete-screen ${canAdmin ? '' : 'hidden'}">Ta bort</button></div>
    </div>
    <div class="screen-status-row"><div class="screen-live-status ${isOnline(screen) ? 'online' : 'offline'}"><span class="status-indicator"></span><span class="status-label">${isOnline(screen) ? 'Online nu' : 'Offline'}</span><span class="last-seen">${screen.last_seen_at ? `Senast kontakt ${new Date(screen.last_seen_at).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}` : 'Spelaren har inte rapporterat ännu'}</span></div><div class="current-content ${isOnline(screen) ? '' : 'stale'}"><span class="current-content-label">VISAS JUST NU</span><strong class="current-title">${esc(isOnline(screen) ? (screen.current_title || 'Väntar på innehåll') : 'Ingen livekontakt')}</strong><span class="current-kind">${esc(isOnline(screen) ? kindLabel(screen.current_kind) : 'Skärmen är offline')}</span><div class="current-preview"></div></div></div>
    <div class="screen-body">
      <p class="pair-help">${screen.pair_code ? 'Öppna Signage Player på TV:n och skriv koden ovan. Koden kan bara användas en gång.' : 'TV:n är parkopplad. Nytt innehåll synkas automatiskt och sparas lokalt för offlinevisning.'}</p>
      <form class="screen-operating-form ${canAdmin ? '' : 'hidden'}"><div class="operating-heading"><strong>Öppettider</strong><span>TV:n visar svart utanför tiderna men fortsätter vara ansluten. Tider följer TV:ns lokala klocka.</span></div><div class="operating-days">${operatingDays.map(([day, label]) => `<label><input type="checkbox" name="operating_weekdays" value="${day}" ${selectedOperatingDays.includes(day) ? 'checked' : ''} /><span>${label}</span></label>`).join('')}</div><div class="operating-times"><label>Från<input name="operating_start_time" type="time" value="${esc(screen.operating_start_time || '')}" /></label><label>Till<input name="operating_end_time" type="time" value="${esc(screen.operating_end_time || '')}" /></label></div><button class="button ghost small" type="submit">Spara öppettider</button></form>
      <label class="screen-playback-setting ${canAdmin ? '' : 'hidden'}">Uppspelningsläge<select class="screen-playback-mode"><option value="independent" ${screen.playback_mode !== 'sync' ? 'selected' : ''}>Fristående · starta lokalt</option><option value="sync" ${screen.playback_mode === 'sync' ? 'selected' : ''}>Synkad · gemensam tidslinje</option></select><span>Synka skärmar med samma aktiva innehållssekvens och schema. TV-enheterna behöver rätt klocka.</span></label>
      <label class="playlist-assignment ${canAdmin ? '' : 'hidden'}">Spellista för den här skärmen<select class="screen-playlist">${playlistOptions}</select><span>En spellista kan delas av flera skärmar.</span></label>
      <form class="screen-layout-form ${canAdmin ? '' : 'hidden'}"><label>Skärmlayout<select name="layout_type"><option value="single" ${screen.layout_type === 'single' ? 'selected' : ''}>En zon · fullskärm</option><option value="bottom_ticker" ${screen.layout_type === 'bottom_ticker' ? 'selected' : ''}>Huvudyta + ticker längst ned</option><option value="side_panel" ${screen.layout_type === 'side_panel' ? 'selected' : ''}>Huvudyta + sidopanel</option></select></label><label>Spellista i zon 2<select name="zone_playlist_id"><option value="">Visa zontext</option>${playlists.map(playlist => `<option value="${esc(playlist.id)}" ${playlist.id === screen.zone_playlist_id ? 'selected' : ''}>${esc(playlist.name)}</option>`).join('')}</select></label><label class="layout-text-label">Zontext<input name="layout_text" maxlength="500" value="${esc(screen.layout_text || '')}" placeholder="Visas om zonspellistan saknar aktivt innehåll" /></label><button class="button ghost small" type="submit">Spara layout</button></form>
      <section class="channel-assignment ${canEdit ? '' : 'hidden'}"><div class="channel-heading"><div><strong>Kanalschema</strong><span>Aktiv kanal prioriteras framför skärmens grundspellista. Lägre prioritetstal vinner.</span></div></div><form class="channel-schedule-form"><select name="channel_id" required>${channelOptions}</select><input name="priority" type="number" min="0" max="1000" value="100" aria-label="Kanalprioritet" />${scheduleFields()}<button class="button ghost small" type="submit">＋ Schemalägg kanal</button></form><div class="channel-schedule-list">${assignedChannels.map(item => { const channel = channels.find(c => c.id === item.channel_id); return `<div class="channel-schedule-row"><div><strong>${esc(channel?.name || 'Okänd kanal')}</strong><span>Prioritet ${item.priority} · ${scheduleSummary(item)}</span></div><button class="button ghost small remove-channel-schedule" data-id="${esc(item.id)}">Ta bort</button></div>`; }).join('') || '<div class="slide-sub">Inga kanaler schemalagda för den här skärmen.</div>'}</div></section>
      <div class="player-operations ${canEdit ? '' : 'hidden'}"><div><strong>Fjärråtgärder</strong><span class="player-command-status" data-command-status>${esc(formatCommandStatus(latestCommand))}</span></div><div class="player-operation-buttons"><button class="button ghost small" data-player-command="sync_now">Synka nu</button><button class="button ghost small" data-player-command="restart_player">Starta om spelaren</button></div></div>
      <div class="playlist-control"><div><strong>Visningsläge</strong><span>${screen.forced_slide_id ? 'En post är vald manuellt.' : 'TV:n roterar innehållet i spellistan.'}</span></div><button class="button ghost small return-playlist ${screen.forced_slide_id && canEdit ? '' : 'hidden'}">Återgå till spellistan</button></div>
      <div class="playlist">${slides.map((slide, index) => renderSlide(slide, index, slides.length, canEdit)).join('') || '<div class="slide-sub">Spellistan är tom. Lägg till ett objekt nedan.</div>'}</div>
      ${channelSlides.length ? `<details class="screen-channel-content"><summary>Innehåll från skärmens kanaler · ${channelSlides.length} objekt</summary><div class="playlist">${channelSlides.map(slide => `<div class="slide-row"><div class="slide-thumb">${slide.kind === 'video' ? '▶' : slide.kind === 'feed' || slide.kind === 'web' ? '↗' : slide.kind === 'clock' ? '◷' : 'T'}</div><div><div class="slide-title">${esc(slide.title || kindLabel(slide.kind))}</div><div class="slide-sub">${esc(kindLabel(slide.kind))} · ${esc(playlists.find(item => item.id === slide.playlist_id)?.name || 'spellista')}</div></div><div class="slide-buttons"><button class="button ghost small channel-show-now" data-id="${esc(slide.id)}" ${canEdit ? '' : 'hidden'}>Visa nu</button></div></div>`).join('')}</div></details>` : ''}
      <div class="slide-add-grid ${canEdit ? '' : 'hidden'}">
        <div class="add-box"><h3>Textmeddelande</h3><form class="text-slide-form add-text"><input name="title" maxlength="80" placeholder="Rubrik" required /><textarea name="body" maxlength="1200" placeholder="Meddelande" required></textarea><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="15" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Publicera text</button></div>${scheduleFields()}</form></div>
        <div class="add-box"><h3>Video eller live-data</h3><form class="text-slide-form add-source"><select name="kind"><option value="video">Video (MP4-länk eller fil)</option><option value="feed">Live-data / JSON-feed (API)</option></select><input name="title" maxlength="80" placeholder="Namn på innehåll" required /><input name="url" type="url" placeholder="https://… eller intern API-adress" /><label class="file-label">För video kan du också välja MP4-fil <input name="file" type="file" accept="video/mp4,video/webm,video/quicktime" /></label><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="30" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till</button></div>${scheduleFields()}</form></div>
        <div class="add-box"><h3>Klocka & datum</h3><form class="text-slide-form add-clock"><input name="title" maxlength="80" placeholder="Rubrik, till exempel Välkommen" /><input name="body" maxlength="180" placeholder="Valfri underrad" /><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="20" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till klocka</button></div>${scheduleFields()}</form></div>
        <div class="add-box"><h3>Webbsida eller live-dashboard</h3><form class="text-slide-form add-web"><input name="title" maxlength="80" placeholder="Namn på sidan" required /><input name="url" type="url" placeholder="https://…" required /><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="60" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till sida</button></div>${scheduleFields()}</form></div>
      </div>
    </div>`;
  card.querySelector('.screen-select').addEventListener('change', event => {
    if (event.currentTarget.checked) selectedScreenIds.add(screen.id);
    else selectedScreenIds.delete(screen.id);
    updateBulkScreenActions();
  });
  updateCurrentPreview(card.querySelector('.current-preview'), screen, isOnline(screen));

  card.querySelector('.toggle-screen').addEventListener('click', async () => {
    const { error } = await supabase.from('screens').update({ is_active: !screen.is_active }).eq('id', screen.id);
    if (error) toast(error.message, true); else loadScreens();
  });
  card.querySelector('.renew-pairing').addEventListener('click', async () => {
    if (!confirm(`Skapa en ny kod för ”${screen.name}”? Den befintliga TV:n kopplas inte bort. Använd bara detta när du återställer eller parkopplar om spelaren.`)) return;
    const { data: code, error } = await supabase.rpc('renew_screen_pairing_code', { input_screen_id: screen.id });
    if (error) return toast(error.message, true);
    toast(`Ny parkopplingskod för ${screen.name}: ${code}`);
    await loadScreens();
  });
  card.querySelector('.screen-operating-form').addEventListener('submit', async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const values = new FormData(form);
    const start = String(values.get('operating_start_time') || '') || null;
    const end = String(values.get('operating_end_time') || '') || null;
    if (Boolean(start) !== Boolean(end)) return toast('Ange både start- och sluttid, eller lämna båda tomma.', true);
    if (start && start === end) return toast('Start- och sluttid kan inte vara samma.', true);
    const days = values.getAll('operating_weekdays').map(Number).filter(day => day >= 1 && day <= 7);
    const operating_weekdays = days.length === 7 || days.length === 0 ? null : days;
    const { error } = await supabase.from('screens').update({
      operating_weekdays,
      operating_start_time: start,
      operating_end_time: end
    }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast('Skärmens öppettider sparades.');
    await loadScreens();
  });
  card.querySelector('.screen-playback-mode').addEventListener('change', async event => {
    const playback_mode = event.currentTarget.value === 'sync' ? 'sync' : 'independent';
    const { error } = await supabase.from('screens').update({ playback_mode }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast(playback_mode === 'sync' ? 'Synkad uppspelning aktiveras på nästa synk.' : 'Fristående uppspelning aktiveras på nästa synk.');
    await loadScreens();
  });
  card.querySelector('.screen-playlist').addEventListener('change', async event => {
    const playlist_id = event.currentTarget.value || null;
    const { error } = await supabase.from('screens').update({ playlist_id, forced_slide_id: null }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast(playlist_id ? 'Spellistan tilldelades skärmen.' : 'Skärmen använder sin egen spellista.');
    await loadScreens();
  });
  card.querySelector('.screen-layout-form').addEventListener('submit', async event => {
    event.preventDefault();
    const f = new FormData(event.currentTarget);
    const layout_type = String(f.get('layout_type'));
    const layout_text = String(f.get('layout_text') || '').trim();
    const zone_playlist_id = String(f.get('zone_playlist_id') || '') || null;
    if (layout_type !== 'single' && !layout_text && !zone_playlist_id) return toast('Välj en zonspellista eller skriv zontext.', true);
    const { error } = await supabase.from('screens').update({ layout_type, layout_text, zone_playlist_id }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast('Skärmlayouten och zonspellistan sparades och synkas till TV:n.');
    await loadScreens();
  });
  card.querySelector('.channel-schedule-form').addEventListener('submit', async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const f = new FormData(form);
    const values = scheduleValues(f);
    if (!values) return;
    if (assignedChannels.some(item => item.channel_id === f.get('channel_id'))) return toast('Den här kanalen är redan tilldelad. Ändra eller ta bort det befintliga schemat.', true);
    const { error } = await supabase.from('screen_channel_schedules').insert({ screen_id: screen.id, channel_id: String(f.get('channel_id')), priority: Number(f.get('priority')) || 100, ...values });
    if (error) return toast(error.message, true);
    toast('Kanalschemat sparades. TV:n byter innehåll automatiskt.');
    await loadScreens();
  });
  card.querySelectorAll('.remove-channel-schedule').forEach(button => button.addEventListener('click', async () => {
    const { error } = await supabase.from('screen_channel_schedules').delete().eq('id', button.dataset.id);
    if (error) return toast(error.message, true);
    toast('Kanalen togs bort från skärmens schema.');
    await loadScreens();
  }));
  card.querySelectorAll('[data-player-command]').forEach(button => button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const { error } = await supabase.rpc('queue_player_command', {
        input_screen_id: screen.id,
        input_command: button.dataset.playerCommand
      });
      if (error) return toast(error.message, true);
      toast(button.dataset.playerCommand === 'restart_player'
        ? `Omstart köad för “${screen.name}”.`
        : `Synk köad för “${screen.name}”.`);
      refreshScreenStatus();
    } finally {
      button.disabled = false;
    }
  }));
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
  card.querySelectorAll('.channel-show-now').forEach(button => button.addEventListener('click', () => setForcedSlide(screen, button.dataset.id)));
  card.querySelector('.return-playlist').addEventListener('click', async () => setForcedSlide(screen, null));
  return card;
}

function scheduleSummary(item) {
  const days = item.weekdays?.length ? `dagar ${item.weekdays.join(', ')}` : 'alla dagar';
  const daily = item.daily_start_time && item.daily_end_time ? `${item.daily_start_time.slice(0,5)}–${item.daily_end_time.slice(0,5)}` : 'hela dagen';
  const range = item.active_from || item.active_until ? `${item.active_from ? new Date(item.active_from).toLocaleString('sv-SE') : 'nu'} – ${item.active_until ? new Date(item.active_until).toLocaleString('sv-SE') : 'utan slutdatum'}` : 'alltid';
  return `${days}, ${daily} · ${range}`;
}

function renderSlide(slide, index, count, canEdit) {
  const detail = slide.kind === 'text' ? (slide.body || '') : slide.kind === 'clock' ? 'Lokal tid och datum' : (slide.source_url || 'Ingen källa');
  return `<div class="slide-row"><div class="slide-thumb">${slide.kind === 'video' ? '▶' : slide.kind === 'feed' ? '↗' : slide.kind === 'web' ? '↗' : slide.kind === 'clock' ? '◷' : 'T'}</div><div><div class="slide-title">${esc(slide.title || kindLabel(slide.kind))}</div><div class="slide-sub">${esc(kindLabel(slide.kind))} · ${slide.duration_seconds}s · ${esc(detail)}</div></div><div class="slide-buttons"><button class="button ghost small show-now" data-slide-action="show-now" data-id="${slide.id}" ${canEdit ? '' : 'hidden'}>Visa nu</button><button class="icon-button" data-slide-action="up" data-id="${slide.id}" ${canEdit ? '' : 'hidden'} ${index === 0 ? 'disabled' : ''}>↑</button><button class="icon-button" data-slide-action="down" data-id="${slide.id}" ${canEdit ? '' : 'hidden'} ${index === count - 1 ? 'disabled' : ''}>↓</button><button class="icon-button delete" data-slide-action="delete" data-id="${slide.id}" ${canEdit ? '' : 'hidden'}>×</button></div></div>`;
}

async function setForcedSlide(screen, slideId) {
  const duration = slideId ? Number(prompt('Hur länge ska utskicket visas? Ange minuter (1–1440).', '10')) : null;
  if (slideId && (!Number.isInteger(duration) || duration < 1 || duration > 1440)) return;
  const { error } = await supabase.rpc('set_screen_cast', {
    input_screen_id: screen.id,
    input_slide_id: slideId,
    input_duration_minutes: duration
  });
  if (error) return toast(error.message, true);
  toast(slideId ? `Utskicket visas i ${duration} minuter och återgår sedan automatiskt.` : 'Spellistan aktiveras igen.');
  await loadScreens();
}

async function addWeb(event, screen) {
  event.preventDefault();
  const form = event.currentTarget;
  const f = new FormData(form);
  const source_url = String(f.get('url') || '').trim();
  if (!/^https?:\/\//i.test(source_url)) return toast('Ange en adress som börjar med HTTPS eller HTTP.', true);
  const schedule = scheduleValues(f);
  if (!schedule) return;
  const { error } = await supabase.from('slides').insert({ ...contentOwner(screen), kind: 'web', title: String(f.get('title') || '').trim(), source_url, duration_seconds: Number(f.get('duration')) || 60, sort_order: await nextOrder(screen), is_active: true, ...schedule });
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
  const activeFrom = String(formData.get('from') || '');
  const activeUntil = String(formData.get('until') || '');
  if (activeFrom && activeUntil && new Date(activeFrom) >= new Date(activeUntil)) {
    toast('Sluttiden måste vara senare än starttiden.', true);
    return null;
  }
  const dailyStart = String(formData.get('daily_from') || '') || null;
  const dailyEnd = String(formData.get('daily_until') || '') || null;
  if (Boolean(dailyStart) !== Boolean(dailyEnd)) {
    toast('Ange både start- och sluttid för det återkommande klockslaget.', true);
    return null;
  }
  if (dailyStart && dailyStart === dailyEnd) {
    toast('Start- och sluttiden kan inte vara samma klockslag.', true);
    return null;
  }
  return {
    active_from: toIso('from'),
    active_until: toIso('until'),
    weekdays: (() => { const days = formData.getAll('weekdays').map(Number).filter(Boolean); return days.length ? days : null; })(),
    daily_start_time: dailyStart,
    daily_end_time: dailyEnd
  };
}

async function addSlide(event, screen, kind) {
  event.preventDefault();
  const form = event.currentTarget;
  const f = new FormData(form);
  const schedule = scheduleValues(f);
  if (!schedule) return;
  const values = { ...contentOwner(screen), kind, title: String(f.get('title') || '').trim(), body: String(f.get('body') || '').trim(), duration_seconds: Number(f.get('duration')) || 15, sort_order: await nextOrder(screen), is_active: true, ...schedule };
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
  const schedule = scheduleValues(f);
  if (!schedule) return;
  if (kind === 'feed' && file instanceof File && file.size > 0) return toast('JSON-feed använder en URL. Välj en videofil bara för video.', true);
  if (file instanceof File && file.size > 0) {
    if (file.size > 400 * 1024 * 1024) return toast('Videofilen får vara högst 400 MB i den här versionen.', true);
    const path = `${screen.playlist_id || screen.id}/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g, '_')}`;
    const { error: uploadError } = await supabase.storage.from('signage-assets').upload(path, file, { cacheControl: '0', upsert: false });
    if (uploadError) return toast(uploadError.message, true);
    source_url = supabase.storage.from('signage-assets').getPublicUrl(path).data.publicUrl;
  }
  if (!source_url) return toast('Ange en videolänk, en feed-URL eller välj en videofil.', true);
  const { error } = await supabase.from('slides').insert({ ...contentOwner(screen), kind, title: String(f.get('title') || '').trim(), source_url, duration_seconds: Number(f.get('duration')) || 30, sort_order: await nextOrder(screen), is_active: true, ...schedule });
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
