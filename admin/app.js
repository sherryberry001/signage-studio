import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';
import './vendor/tus.min.js';

const $ = (s, root = document) => root.querySelector(s);
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function fileUploadProgress(form) {
  let panel = form.querySelector('.file-upload-progress');
  if (!panel) {
    panel = document.createElement('div');
    panel.className = 'file-upload-progress hidden';
    panel.setAttribute('role', 'status');
    panel.setAttribute('aria-live', 'polite');
    const progress = document.createElement('progress');
    progress.max = 100;
    const message = document.createElement('span');
    panel.append(progress, message);
    form.querySelector('[name="file"]')?.closest('label')?.after(panel);
  }
  const [progress, message] = panel.children;
  return {
    update(percent, text) {
      panel.classList.remove('hidden');
      progress.value = Math.max(0, Math.min(100, percent));
      message.textContent = text;
    },
    clear() { panel.classList.add('hidden'); }
  };
}

function uploadResumeKey(file, prefix) {
  return `signage-upload:${currentUser?.id || 'session'}:${prefix}:${file.name}:${file.size}:${file.lastModified}`;
}

async function uploadSignageFile(file, { form, prefix }) {
  const TusUpload = window.tus?.Upload;
  if (!TusUpload) throw new Error('Uppladdningsklienten kunde inte laddas. Ladda om adminvyn och försök igen.');
  const { data: { session }, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) throw sessionError;
  if (!session?.access_token) throw new Error('Din inloggning har gått ut. Logga in igen innan du laddar upp.');

  const projectRef = new URL(SUPABASE_URL).hostname.split('.')[0];
  const endpoint = `https://${projectRef}.storage.supabase.co/storage/v1/upload/resumable`;
  const fileName = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
  const resumeKey = uploadResumeKey(file, prefix);
  let path = '';
  let hasStoredPath = false;
  try {
    path = sessionStorage.getItem(resumeKey) || '';
    hasStoredPath = Boolean(path);
  } catch { }
  if (!path) {
    path = `${prefix}/${crypto.randomUUID()}-${fileName}`;
    try { sessionStorage.setItem(resumeKey, path); hasStoredPath = true; } catch { }
  }

  const progress = fileUploadProgress(form);
  const submitButton = form.querySelector('button[type="submit"]');
  if (submitButton) submitButton.disabled = true;
  progress.update(0, `Förbereder ${file.name} …`);

  let latestPercent = 0;
  try {
    await new Promise((resolve, reject) => {
      const upload = new TusUpload(file, {
        endpoint,
        retryDelays: [0, 3000, 5000, 10000, 20000],
        headers: {
          authorization: `Bearer ${session.access_token}`,
          apikey: SUPABASE_ANON_KEY,
          'x-upsert': 'true'
        },
        uploadDataDuringCreation: true,
        removeFingerprintOnSuccess: true,
        chunkSize: 6 * 1024 * 1024,
        metadata: {
          bucketName: 'signage-assets',
          objectName: path,
          contentType: file.type || 'application/octet-stream',
          cacheControl: '0'
        },
        onError: reject,
        onProgress(bytesUploaded, bytesTotal) {
          const percent = bytesTotal ? (bytesUploaded / bytesTotal) * 100 : 0;
          latestPercent = percent;
          const uploaded = formatUploadSize(bytesUploaded);
          const total = formatUploadSize(bytesTotal);
          progress.update(percent, `Laddar upp ${file.name} · ${Math.floor(percent)} % · ${uploaded} av ${total}`);
        },
        onSuccess() {
          progress.update(100, `${file.name} uppladdad · sparar innehållet …`);
          resolve();
        }
      });

      upload.findPreviousUploads().then(previousUploads => {
        const previous = previousUploads.find(item => item.metadata?.objectName === path)
          || previousUploads.find(item => !hasStoredPath && item.metadata?.objectName?.startsWith(`${prefix}/`));
        if (previous) {
          if (previous.metadata?.objectName) path = previous.metadata.objectName;
          upload.resumeFromPreviousUpload(previous);
        }
        upload.start();
      }).catch(reject);
    });
    const source_url = supabase.storage.from('signage-assets').getPublicUrl(path).data.publicUrl;
    let finalized = false;
    return {
      source_url,
      finalize() {
        if (finalized) return;
        finalized = true;
        try { sessionStorage.removeItem(resumeKey); } catch { }
        progress.clear();
      }
    };
  } catch (error) {
    progress.update(latestPercent, `Uppladdningen pausades vid ${Math.floor(latestPercent)} %. Välj samma fil igen för att återuppta. ${error?.message || ''}`.trim());
    throw error;
  } finally {
    if (submitButton) submitButton.disabled = false;
  }
}

function formatUploadSize(bytes) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} kB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
let draftPreviewItems = [];
let draftPreviewIndex = 0;
let draftPreviewEmptyMessage = 'Inget innehåll i utkastet ännu.';
let draftPreviewScreen = null;
let draftPreviewBaseSlides = [];
let draftPreviewChannelSlides = [];
let draftPreviewZoneSlides = [];
let draftPreviewScreenSchedules = [];
let draftPreviewZoneItem = null;
let draftPreviewZoneItemCount = 0;
let draftPreviewZonePosition = 0;
let draftPreviewZoneText = '';
let draftPreviewAt = new Date();
let draftPreviewGeneration = 0;
const draftPreviewAbortControllers = new Set();
let draftPreviewRefreshTimer = null;
const authView = $('#authView');
const appView = $('#appView');
const screenDirectoryList = $('#screenDirectoryList');
const screenDetailContent = $('#screenDetailContent');
const notice = $('#setupNotice');
let currentUser = null;
let screens = [];
let screenGroups = [];
let screenGroupMembers = [];
let locations = [];
let locationMembers = [];
let playlists = [];
let playlistSlides = [];
let playlistVersions = [];
let playlistVersionHistoryAvailable = true;
let channels = [];
let channelPlaylists = [];
let channelSchedules = [];
let teamMembers = [];
let screenCommands = [];
let screenPublications = [];
let screenBroadcasts = [];
let screenBroadcastDelivery = [];
let screenBroadcastDeliveryAvailable = true;
let screenBroadcastHistory = [];
let screenBroadcastHistoryDelivery = [];
let screenBroadcastHistoryDeliveryAvailable = true;
let screenBroadcastHistoryLoaded = false;
let mediaLibrary = [];
let mediaFolders = [];
let mediaLibraryVersions = [];
let activityLog = [];
let playbackEvents = [];
let playbackAggregates = [];
let integrationStatuses = [];
let signageIntegrations = [];
const defaultOperationalSettings = {
  offline_alert_after_minutes: 3,
  command_alert_after_minutes: 2,
  feed_error_window_minutes: 15
};
let operationalSettings = { ...defaultOperationalSettings };
let operationalSettingsAvailable = true;
let currentRole = null;
let statusTimer = null;
let alertTimer = null;
let activityTimer = null;
let integrationTimer = null;
let channelCalendarOffset = 0;
let screensLoadId = 0;
let activityLoadId = 0;
const selectedScreenIds = new Set();
let activeWorkspace = 'screens';
let selectedScreenDetailId = null;
let screenRenderData = new Map();
const workspaceDetails = {
  screens: ['Skärmöversikt', 'Övervaka anslutning, innehåll och status för dina skärmar.'],
  'screen-detail': ['Skärminställningar', 'Hantera innehåll, schema, layout och enhetsinställningar för skärmen.'],
  content: ['Mediabibliotek', 'Hantera återanvändbart innehåll och live-data.'],
  playlists: ['Spellistor', 'Bygg och organisera spellistor för dina skärmar.'],
  channels: ['Kanaler & schema', 'Planera vad som ska visas, när det ska visas och på vilka skärmar.'],
  broadcasts: ['Utskick', 'Skapa tillfälliga meddelanden och följ spelarens kvittens.'],
  organization: ['Grupper & platser', 'Organisera skärmar i grupper och platser.'],
  integrations: ['Integrationer', 'Övervaka live-feeds som rapporteras från anslutna skärmar.'],
  proof: ['Uppspelning', 'Följ rapporterade innehållsbyten per skärm och exportera uppspelningshistorik.'],
  team: ['Team', 'Hantera personer och åtkomst till Signage Studio.'],
  activity: ['Aktivitet', 'Följ ändringar och fjärråtgärder i Signage Studio.']
};

$('#year').textContent = new Date().getFullYear();

$('#workspaceNavigation').addEventListener('click', event => {
  const button = event.target.closest('[data-workspace]');
  if (button && !button.classList.contains('hidden')) setWorkspace(button.dataset.workspace);
});

function setWorkspace(workspace) {
  if (!workspaceDetails[workspace]) return;
  if (['team', 'activity', 'organization'].includes(workspace) && currentRole !== 'admin') return;
  if (workspace === 'broadcasts' && !['admin', 'editor'].includes(currentRole)) return;
  clearInterval(activityTimer);
  activityTimer = null;
  clearInterval(integrationTimer);
  integrationTimer = null;
  activeWorkspace = workspace;
  document.querySelectorAll('[data-workspace-panel]').forEach(panel => {
    panel.classList.toggle('hidden', panel.dataset.workspacePanel !== workspace);
  });
  document.querySelectorAll('.workspace-tab').forEach(button => {
    const active = button.dataset.workspace === (workspace === 'screen-detail' ? 'screens' : workspace);
    button.classList.toggle('active', active);
    if (active) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  $('#workspaceTitle').textContent = workspaceDetails[workspace][0];
  $('#workspaceDescription').textContent = workspaceDetails[workspace][1];
  if (workspace === 'screen-detail' && selectedScreenDetailId) {
    const screen = screens.find(item => item.id === selectedScreenDetailId);
    if (screen) $('#workspaceTitle').textContent = screen.name || 'Skärminställningar';
  }
  if (workspace === 'activity') {
    loadActivityLog();
    activityTimer = setInterval(loadActivityLog, 15000);
  }
  if (workspace === 'proof') loadPlaybackEvents();
  if (workspace === 'integrations') {
    loadIntegrationCatalog();
    loadIntegrationStatus();
    integrationTimer = setInterval(loadIntegrationStatus, 30000);
  }
  if (workspace === 'broadcasts') renderBroadcastTargets();
}

$('#screenDetailBack').addEventListener('click', () => setWorkspace('screens'));

function openScreenDetails(screenId) {
  const renderData = screenRenderData.get(screenId);
  if (!renderData) return;
  selectedScreenDetailId = screenId;
  const currentScreen = screens.find(item => item.id === screenId);
  const currentRenderData = [...renderData];
  if (currentScreen) currentRenderData[0] = currentScreen;
  const card = renderScreen(...currentRenderData);
  card.classList.add('screen-detail-card');
  screenDetailContent.replaceChildren(card);
  $('#workspaceTitle').textContent = screens.find(item => item.id === screenId)?.name || 'Skärminställningar';
  setWorkspace('screen-detail');
}

setWorkspace('screens');

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

function localDateInput(date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

function localDateTimeInput(value) {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 16);
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
    if (!sameUser) {
      operationalSettings = { ...defaultOperationalSettings };
      operationalSettingsAvailable = true;
      playlistVersions = [];
      playlistVersionHistoryAvailable = true;
      screenBroadcasts = [];
      screenBroadcastDelivery = [];
      screenBroadcastDeliveryAvailable = true;
      screenBroadcastHistory = [];
      screenBroadcastHistoryDelivery = [];
      screenBroadcastHistoryDeliveryAvailable = true;
      screenBroadcastHistoryLoaded = false;
      $('#screenBroadcastHistoryDisclosure').open = false;
      $('#screenBroadcastList').replaceChildren();
      $('#screenBroadcastHistory').textContent = 'Öppna för att läsa historiken.';
    }
    $('#userEmail').textContent = user.email || 'Admin';
    if (!sameUser || !currentRole) loadScreens();
    clearInterval(statusTimer);
    statusTimer = setInterval(refreshScreenStatus, 5000);
    clearInterval(alertTimer);
    refreshOperationalAlerts();
    alertTimer = setInterval(refreshOperationalAlerts, 60000);
  } else {
    operationalSettings = { ...defaultOperationalSettings };
    operationalSettingsAvailable = true;
    screensLoadId++;
    screens = [];
    screenGroups = [];
    screenGroupMembers = [];
    locations = [];
    locationMembers = [];
    playlists = [];
    playlistSlides = [];
    playlistVersions = [];
    playlistVersionHistoryAvailable = true;
    channels = [];
    channelPlaylists = [];
    channelSchedules = [];
    teamMembers = [];
    screenCommands = [];
    screenPublications = [];
    screenBroadcasts = [];
    screenBroadcastDelivery = [];
    screenBroadcastDeliveryAvailable = true;
    screenBroadcastHistory = [];
    screenBroadcastHistoryDelivery = [];
    screenBroadcastHistoryDeliveryAvailable = true;
    screenBroadcastHistoryLoaded = false;
    $('#screenBroadcastHistoryDisclosure').open = false;
    $('#screenBroadcastList').replaceChildren();
    $('#screenBroadcastHistory').textContent = 'Öppna för att läsa historiken.';
    integrationStatuses = [];
    mediaLibrary = [];
    mediaFolders = [];
    mediaLibraryVersions = [];
    activityLog = [];
    selectedScreenIds.clear();
    currentRole = null;
    activeWorkspace = 'screens';
    selectedScreenDetailId = null;
    screenRenderData.clear();
    setWorkspace('screens');
    screenDirectoryList.replaceChildren();
    screenDetailContent.replaceChildren();
    clearInterval(statusTimer);
    clearInterval(alertTimer);
    clearInterval(activityTimer);
    activityTimer = null;
    clearInterval(integrationTimer);
    integrationTimer = null;
  }
}

function checkConfig() {
  if (!configured()) {
    showNotice('Lägg in Supabase URL och anon key i admin/config.js efter att du skapat projektet. Installationsstegen finns i README.');
    $('#loginForm button').disabled = true;
  }
}

function authRequestMessage(error) {
  const code = String(error?.code || '').toLowerCase();
  const message = String(error?.message || '').toLowerCase();
  if (error?.status === 429 || code.includes('rate_limit') || message.includes('rate limit') || message.includes('too many requests')) {
    return 'E-postgränsen för Signage Studio är nådd just nu. Använd den senaste giltiga länken du fått. Om den har gått ut, vänta tills timkvoten fyllts på från de senaste Auth-mejlen i projektet och begär sedan en ny länk en gång. Supabases inbyggda e-posttjänst tillåter två Auth-mejl per timme.';
  }
  if (['otp_expired', 'token_expired', 'email_not_confirmed'].includes(code) || message.includes('expired')) {
    return 'Inloggningslänken har gått ut eller redan använts. Begär en ny länk och öppna den i samma webbläsare.';
  }
  if (['user_not_found', 'signup_disabled'].includes(code) || message.includes('user not found')) {
    return 'Kontot finns inte i Signage Studio ännu. Be en administratör kontrollera att du är inbjuden under Team & åtkomst.';
  }
  return 'Kunde inte skicka inloggningslänken. Kontrollera e-postadressen och försök igen senare.';
}

$('#loginForm').addEventListener('submit', async event => {
  event.preventDefault();
  const button = event.currentTarget.querySelector('button[type="submit"]');
  if (button.disabled) return;
  const email = $('#email').value.trim();
  button.disabled = true;
  $('#authMessage').textContent = 'Skickar inloggningslänk …';
  try {
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: location.href, shouldCreateUser: false }
    });
    $('#authMessage').textContent = error ? authRequestMessage(error) : 'Länken är skickad. Öppna den i samma webbläsare.';
  } catch {
    $('#authMessage').textContent = 'Kunde inte nå inloggningstjänsten just nu. Kontrollera anslutningen och försök igen senare.';
  } finally {
    button.disabled = false;
  }
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
    const group_id = $('#newScreenGroup').value || null;
    const location_id = $('#newScreenLocation').value || null;
    const { error } = await supabase.from('screens').insert({ name, pair_code, group_id, location_id, is_active: true });
    if (error) {
      if (error.code === '23505' && `${error.message} ${error.details || ''}`.includes('screens_name_ci_active_idx')) {
        await loadScreens();
        return toast(`En aktiv skärm med namnet “${name}” skapades samtidigt. Den befintliga profilen har inte ändrats.`, true);
      }
      return toast(error.message, true);
    }
    $('#screenName').value = '';
    toast('Skärmen skapades. Ange parkopplingskoden i TV-appen.');
    await loadScreens();
  } finally {
    submit.disabled = false;
  }
});

$('#createScreenGroupForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (currentRole !== 'admin') return;
  const form = event.currentTarget;
  const values = new FormData(form);
  const name = String(values.get('name') || '').trim();
  const description = String(values.get('description') || '').trim();
  if (!name) return toast('Ange ett namn på gruppen.', true);
  const { error } = await supabase.from('screen_groups').insert({ name, description });
  if (error) return toast(error.message, true);
  form.reset();
  toast(`Gruppen ”${name}” skapades.`);
  await loadScreens();
});

$('#createLocationForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (currentRole !== 'admin') return;
  const form = event.currentTarget;
  const values = new FormData(form);
  const name = String(values.get('name') || '').trim();
  const description = String(values.get('description') || '').trim();
  if (!name) return toast('Ange ett namn på platsen.', true);
  const { error } = await supabase.from('locations').insert({ name, description, created_by: currentUser.id });
  if (error) return toast(error.message, true);
  form.reset();
  toast(`Platsen ”${name}” skapades.`);
  await loadScreens();
});

$('#locationList').addEventListener('submit', async event => {
  const addMemberForm = event.target.closest('[data-location-member-add]');
  if (addMemberForm) {
    event.preventDefault();
    const user_id = String(new FormData(addMemberForm).get('user_id') || '');
    if (!user_id) return toast('Välj en gruppmedlem först.', true);
    const { error } = await supabase.from('location_members').insert({ location_id: addMemberForm.dataset.locationMemberAdd, user_id });
    if (error) return toast(error.message, true);
    toast('Platsåtkomsten sparades. Medlemmen kan nu läsa skärmar och innehåll på platsen.');
    await loadScreens();
    return;
  }
  const form = event.target.closest('[data-location-edit]');
  if (!form || currentRole !== 'admin') return;
  event.preventDefault();
  const values = new FormData(form);
  const name = String(values.get('name') || '').trim();
  const description = String(values.get('description') || '').trim();
  if (!name) return toast('Platsnamnet får inte vara tomt.', true);
  const { error } = await supabase.from('locations').update({ name, description, updated_at: new Date().toISOString() }).eq('id', form.dataset.locationEdit);
  if (error) return toast(error.message, true);
  toast('Platsen uppdaterades.');
  await loadScreens();
});

$('#locationList').addEventListener('click', async event => {
  const removeMember = event.target.closest('[data-location-member-delete]');
  if (removeMember && currentRole === 'admin') {
    const member = locationMembers.find(item => item.id === removeMember.dataset.locationMemberDelete);
    if (!member) return;
    const name = teamMembers.find(item => item.user_id === member.user_id)?.email || 'medlemmen';
    if (!confirm(`Ta bort ${name} från platsen? Personen förlorar då läsåtkomsten till platsens skärmar och innehåll.`)) return;
    const { error } = await supabase.from('location_members').delete().eq('id', member.id);
    if (error) return toast(error.message, true);
    toast('Platsåtkomsten togs bort.');
    await loadScreens();
    return;
  }
  const button = event.target.closest('[data-location-delete]');
  if (!button || currentRole !== 'admin') return;
  const location = locations.find(item => item.id === button.dataset.locationDelete);
  if (!location) return;
  const members = locationMembers.filter(item => item.location_id === location.id).length;
  if (!confirm(`Ta bort platsen ”${location.name}”? ${members ? `${members} medlemmar förlorar sin platsåtkomst. ` : ''}Det går inte att ångra.`)) return;
  const { error } = await supabase.from('locations').delete().eq('id', location.id);
  if (error) return toast(error.message, true);
  toast('Platsen togs bort.');
  await loadScreens();
});

$('#screenGroupList').addEventListener('submit', async event => {
  const addMemberForm = event.target.closest('[data-screen-group-member-add]');
  if (addMemberForm) {
    event.preventDefault();
    const user_id = String(new FormData(addMemberForm).get('user_id') || '');
    if (!user_id) return toast('Välj en gruppmedlem först.', true);
    const { error } = await supabase.from('screen_group_members').insert({ group_id: addMemberForm.dataset.screenGroupMemberAdd, user_id });
    if (error) return toast(error.message, true);
    toast('Gruppåtkomsten sparades.');
    await loadScreens();
    return;
  }
  const form = event.target.closest('[data-screen-group-edit]');
  if (!form) return;
  event.preventDefault();
  const values = new FormData(form);
  const name = String(values.get('name') || '').trim();
  const description = String(values.get('description') || '').trim();
  if (!name) return toast('Gruppnamnet får inte vara tomt.', true);
  const { error } = await supabase.from('screen_groups').update({ name, description, updated_at: new Date().toISOString() }).eq('id', form.dataset.screenGroupEdit);
  if (error) return toast(error.message, true);
  toast('Skärmgruppen uppdaterades.');
  await loadScreens();
});

$('#screenGroupList').addEventListener('click', async event => {
  const removeMember = event.target.closest('[data-screen-group-member-delete]');
  if (removeMember && currentRole === 'admin') {
    const member = screenGroupMembers.find(item => item.id === removeMember.dataset.screenGroupMemberDelete);
    if (!member) return;
    const name = teamMembers.find(item => item.user_id === member.user_id)?.email || 'medlemmen';
    if (!confirm(`Ta bort ${name} från den här gruppen?`)) return;
    const { error } = await supabase.from('screen_group_members').delete().eq('id', member.id);
    if (error) return toast(error.message, true);
    toast('Gruppåtkomsten togs bort.');
    await loadScreens();
    return;
  }
  const button = event.target.closest('[data-screen-group-delete]');
  if (!button || currentRole !== 'admin') return;
  const group = screenGroups.find(item => item.id === button.dataset.screenGroupDelete);
  if (!group) return;
  const count = logicalScreens().filter(screen => screen.group_id === group.id).length;
  const effect = count ? ` ${count} skärmar flyttas till ”Ingen grupp”; innehåll och parkopplingar behålls.` : '';
  if (!confirm(`Ta bort gruppen ”${group.name}”?${effect}`)) return;
  const { error } = await supabase.from('screen_groups').delete().eq('id', group.id);
  if (error) return toast(error.message, true);
  toast('Skärmgruppen togs bort.');
  await loadScreens();
});

$('#teamRoleForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (currentRole !== 'admin') return;
  const submit = event.currentTarget.querySelector('[type="submit"]');
  submit.disabled = true;
  const { data, error } = await supabase.functions.invoke('invite-team-member', {
    body: { email: $('#teamEmail').value.trim(), role: $('#teamRole').value }
  });
  if (error) {
    let message = error.message;
    try {
      const details = await error.context?.json();
      if (details?.error) message = details.error;
    } catch { }
    submit.disabled = false;
    return toast(message, true);
  }
  event.currentTarget.reset();
  toast(data?.invited ? `Inbjudan skickad till ${data.email}.` : `${data?.email || 'Kontot'} hade redan Auth och har lagts till i teamet.`);
  try { await loadScreens(); } finally { submit.disabled = false; }
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
  const editForm = event.target.closest('[data-channel-playlist-edit]');
  if (editForm) {
    event.preventDefault();
    const values = new FormData(editForm);
    const schedule = scheduleValues(values);
    if (!schedule) return;
    const priority = schedulePriority(values);
    if (priority === null) return;
    const channel_id = editForm.dataset.channelId;
    const { error } = await supabase.from('channel_playlists')
      .update({ priority, ...schedule })
      .eq('id', editForm.dataset.channelPlaylistEdit)
      .eq('channel_id', channel_id);
    if (error) return toast(error.message, true);
    const affectedScreens = new Set(channelSchedules.filter(item => item.channel_id === channel_id).map(item => item.screen_id));
    const affectedLabel = affectedScreens.size === 1 ? '1 berörd skärm' : `${affectedScreens.size} berörda skärmar`;
    toast(`Kanalspellistans tider och prioritet sparades som utkast. Publicera ${affectedLabel} för att skicka ändringen till TV:n.`);
    await loadScreens();
    return;
  }
  const form = event.target.closest('.channel-playlist-form');
  if (!form) return;
  event.preventDefault();
  const values = new FormData(form);
  const schedule = scheduleValues(values);
  if (!schedule) return;
  const priority = schedulePriority(values);
  if (priority === null) return;
  const channel_id = form.dataset.channelId;
  const playlist_id = String(values.get('playlist_id') || '');
  if (channelPlaylists.some(item => item.channel_id === channel_id && item.playlist_id === playlist_id)) return toast('Spellistan finns redan i kanalen.', true);
  const { data: last, error: orderError } = await supabase.from('channel_playlists').select('sort_order').eq('channel_id', channel_id).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  if (orderError) return toast(orderError.message, true);
  const { error } = await supabase.from('channel_playlists').insert({ channel_id, playlist_id, sort_order: (last?.sort_order ?? -1) + 1, priority, ...schedule });
  if (error) return toast(error.message, true);
  toast('Spellistan och schemat sparades som utkast. Publicera från varje berörd skärm när du är klar.');
  await loadScreens();
});

$('#channelManagementList').addEventListener('click', async event => {
  const moveButton = event.target.closest('[data-channel-playlist-move]');
  if (moveButton && !moveButton.disabled) {
    if (!['admin', 'editor'].includes(currentRole)) return;
    const channelId = moveButton.dataset.channelId;
    const channelItems = channelPlaylists.filter(item => item.channel_id === channelId).sort((a, b) => a.sort_order - b.sort_order);
    const fromIndex = channelItems.findIndex(item => item.id === moveButton.dataset.channelPlaylistMove);
    const toIndex = fromIndex + (moveButton.dataset.direction === 'up' ? -1 : 1);
    if (fromIndex < 0 || toIndex < 0 || toIndex >= channelItems.length) return;
    [channelItems[fromIndex], channelItems[toIndex]] = [channelItems[toIndex], channelItems[fromIndex]];
    moveButton.disabled = true;
    try {
      const { error } = await supabase.rpc('reorder_channel_playlists', {
        input_channel_id: channelId,
        input_playlist_ids: channelItems.map(item => item.playlist_id)
      });
      if (error) return toast(error.message, true);
      const affectedScreens = new Set(channelSchedules.filter(item => item.channel_id === channelId).map(item => item.screen_id));
      const countLabel = affectedScreens.size === 1 ? '1 skärm' : `${affectedScreens.size} skärmar`;
      toast(`Spellistornas ordning sparades som utkast. Publicera ${countLabel} för att skicka ändringen till TV:n.`);
      await loadScreens();
    } finally {
      moveButton.disabled = false;
    }
    return;
  }
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
$('#mediaFolderFilter').addEventListener('change', renderMediaLibrary);
$('#activitySearch').addEventListener('input', renderActivityLog);
$('#activityFilter').addEventListener('change', renderActivityLog);
$('#refreshActivity').addEventListener('click', loadActivityLog);
$('#refreshPlayback').addEventListener('click', loadPlaybackEvents);
$('#playbackFrom').value = localDateInput(new Date(Date.now() - 6 * 86400000));
$('#playbackTo').value = localDateInput(new Date());
$('#playbackFrom').addEventListener('change', loadPlaybackEvents);
$('#playbackTo').addEventListener('change', loadPlaybackEvents);
$('#playbackScreen').addEventListener('change', loadPlaybackEvents);
$('#playbackSearch').addEventListener('input', () => { renderPlaybackEvents(); renderPlaybackAggregates(); });
$('#exportPlayback').addEventListener('click', exportPlaybackEvents);
$('#refreshIntegrations').addEventListener('click', loadIntegrationStatus);
$('#integrationSearch').addEventListener('input', renderIntegrationStatus);
$('#integrationFilter').addEventListener('change', renderIntegrationStatus);
$('#channelCalendarPrevious').addEventListener('click', () => { channelCalendarOffset--; renderChannelCalendar(); });
$('#channelCalendarToday').addEventListener('click', () => { channelCalendarOffset = 0; renderChannelCalendar(); });
$('#channelCalendarNext').addEventListener('click', () => { channelCalendarOffset++; renderChannelCalendar(); });
$('#channelCalendarScreen').addEventListener('change', renderChannelCalendar);
$('#createIntegration').addEventListener('click', () => openIntegrationForm());
$('#cancelIntegration').addEventListener('click', resetIntegrationForm);
$('#integrationCatalogList').addEventListener('click', event => {
  const button = event.target.closest('[data-edit-integration]');
  if (!button || currentRole !== 'admin') return;
  openIntegrationForm(signageIntegrations.find(item => item.id === button.dataset.editIntegration));
});

$('#integrationForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (currentRole !== 'admin') return;
  const form = event.currentTarget;
  const values = new FormData(form);
  const { error } = await supabase.rpc('manage_signage_integration', {
    input_integration_id: form.dataset.integrationId || null,
    input_name: String(values.get('name') || '').trim(),
    input_endpoint_url: String(values.get('endpoint_url') || '').trim(),
    input_display_token: String(values.get('display_token') || '')
  });
  if (error) return toast(error.message, true);
  toast('Pulse-anslutningen sparades.');
  resetIntegrationForm();
  await loadIntegrationCatalog();
  await loadScreens();
});

$('#mediaLibraryForm [name="kind"]').addEventListener('change', event => {
  const form = $('#mediaLibraryForm');
  const kind = event.target.value;
  const refreshSetting = form.querySelector('.feed-refresh-setting');
  refreshSetting.classList.toggle('hidden', !['feed', 'web'].includes(kind));
  refreshSetting.querySelector('span').textContent = kind === 'web' ? 'Ladda om dashboard var (sek)' : 'Hämta live-data var (sek)';
  form.querySelector('.feed-integration-setting').classList.toggle('hidden', kind !== 'feed' || signageIntegrations.length === 0);
  syncFeedIntegrationField(form);
  const fileInput = form.querySelector('[name="file"]');
  fileInput.accept = kind === 'image'
    ? 'image/jpeg,image/png,image/webp'
    : kind === 'video' ? 'video/mp4,video/webm,video/quicktime' : '';
  form.querySelector('.file-label').classList.toggle('hidden', !['image', 'video'].includes(kind));
  form.querySelector('.file-label').firstChild.textContent = kind === 'image' ? 'Bildfil (valfritt) ' : 'Videofil (valfritt) ';
});
$('#mediaLibraryForm [name="integration_id"]').addEventListener('change', event => syncFeedIntegrationField(event.currentTarget.form));
$('#mediaLibraryForm [name="kind"]').dispatchEvent(new Event('change'));

$('#mediaLibraryForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (!['admin', 'editor'].includes(currentRole)) return;
  const form = event.currentTarget;
  const values = new FormData(form);
  const kind = String(values.get('kind'));
  let source_url = String(values.get('source_url') || '').trim();
  const expiryInput = String(values.get('expires_at') || '').trim();
  const expiryDate = expiryInput ? new Date(expiryInput) : null;
  if (expiryDate && Number.isNaN(expiryDate.getTime())) return toast('Ange en giltig utgångstid.', true);
  const expires_at = expiryDate ? expiryDate.toISOString() : null;
  const integration_id = kind === 'feed' ? String(values.get('integration_id') || '') || null : null;
  const integration = signageIntegrations.find(item => item.id === integration_id);
  if (integration) source_url = integration.endpoint_url;
  let uploadedFile = null;
  const file = values.get('file');
  if (file instanceof File && file.size > 0) {
    if (!['image', 'video'].includes(kind)) return toast('Välj bild eller video för att ladda upp en fil.', true);
    const maxBytes = kind === 'image' ? 30 * 1024 * 1024 : 400 * 1024 * 1024;
    if (file.size > maxBytes) return toast(kind === 'image' ? 'Bildfilen får vara högst 30 MB.' : 'Videofilen får vara högst 400 MB.', true);
    if (kind === 'image' && !['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) return toast('Bilder ska vara JPEG, PNG eller WebP.', true);
    try {
      uploadedFile = await uploadSignageFile(file, { form, prefix: `library/${currentUser.id}` });
      source_url = uploadedFile.source_url;
    } catch (error) {
      return toast(error.message || 'Filen kunde inte laddas upp.', true);
    }
  }
  const body = String(values.get('body') || '').trim();
  if (['web', 'feed', 'image', 'video'].includes(kind) && !/^https?:\/\//i.test(source_url)) return toast('Ange en giltig HTTP- eller HTTPS-källa eller välj en fil.', true);
  if (kind === 'feed' && integration_id && !integration) return toast('Den valda Pulse-anslutningen finns inte längre. Ladda om sidan.', true);
  if (kind === 'feed' && !integration_id && /#token=/i.test(source_url)) return toast('Lägg Pulse-token i en skyddad Pulse-anslutning under Integrationer, inte i feed-URL:en.', true);
  if (kind === 'text' && !body) return toast('Skriv texten som ska sparas i biblioteket.', true);
  const tags = [...new Set(String(values.get('tags') || '').split(',').map(tag => tag.trim().toLocaleLowerCase('sv-SE')).filter(Boolean))];
  const refresh_interval_seconds = ['feed', 'web'].includes(kind) ? Number(values.get('refresh_interval_seconds') || 30) : 30;
  if (['feed', 'web'].includes(kind) && (!Number.isInteger(refresh_interval_seconds) || refresh_interval_seconds < 10 || refresh_interval_seconds > 3600)) return toast('Uppdateringsintervallet ska vara 10–3600 sekunder.', true);
  const { error } = await supabase.from('media_library').insert({ kind, title: String(values.get('title') || '').trim(), body, source_url: source_url || null, integration_id, tags, folder_id: String(values.get('folder_id') || '') || null, expires_at, refresh_interval_seconds });
  if (error) return toast(error.message, true);
  uploadedFile?.finalize();
  form.reset();
  $('#mediaLibraryForm [name="kind"]').dispatchEvent(new Event('change'));
  toast('Innehållet sparades i biblioteket.');
  await loadScreens();
});

$('#createMediaFolderForm').addEventListener('submit', async event => {
  event.preventDefault();
  if (!['admin','editor'].includes(currentRole)) return;
  const form = event.currentTarget;
  const name = String(new FormData(form).get('name') || '').trim();
  if (!name) return;
  const { error } = await supabase.from('media_folders').insert({ name, created_by: currentUser.id });
  if (error) return toast(error.message, true);
  form.reset();
  toast(`Mappen ”${name}” skapades.`);
  await loadScreens();
});

$('#renameMediaFolder').addEventListener('click', async () => {
  if (!['admin','editor'].includes(currentRole)) return;
  const folder = mediaFolders.find(item => item.id === $('#mediaFolderFilter').value);
  if (!folder) return;
  const name = prompt('Nytt mappnamn:', folder.name)?.trim();
  if (!name || name === folder.name) return;
  const { error } = await supabase.from('media_folders').update({ name, updated_at: new Date().toISOString() }).eq('id', folder.id);
  if (error) return toast(error.message, true);
  toast('Mappen döptes om.');
  await loadScreens();
});

$('#deleteMediaFolder').addEventListener('click', async () => {
  if (!['admin','editor'].includes(currentRole)) return;
  const folder = mediaFolders.find(item => item.id === $('#mediaFolderFilter').value);
  if (!folder) return;
  const count = mediaLibrary.filter(item => item.folder_id === folder.id).length;
  if (!confirm(`Ta bort mappen ”${folder.name}”? ${count} biblioteksposter flyttas till ”Utan mapp”.`)) return;
  const { error } = await supabase.from('media_folders').delete().eq('id', folder.id);
  if (error) return toast(error.message, true);
  toast('Mappen togs bort. Biblioteksposterna finns kvar utan mapp.');
  await loadScreens();
});

async function loadScreens() {
  if (!currentUser) return;
  const loadId = ++screensLoadId;
  const userId = currentUser.id;
  const [
    { data, error },
    { data: playlistData, error: playlistError },
    { data: playlistVersionData, error: playlistVersionError },
    { data: memberData, error: memberError },
    { data: channelData, error: channelError },
    { data: channelPlaylistData, error: channelPlaylistError },
    { data: channelScheduleData, error: channelScheduleError },
    { data: commandData, error: commandError },
    { data: publicationData, error: publicationError },
    { data: approvalData, error: approvalError },
    { data: mediaData, error: mediaError },
    { data: mediaFolderData, error: mediaFolderError },
    { data: mediaVersionData, error: mediaVersionError },
    { data: groupData, error: groupError },
    { data: groupMemberData, error: groupMemberError },
    { data: locationData, error: locationError },
    { data: locationMemberData, error: locationMemberError },
    { data: broadcastData, error: broadcastError },
    { data: operationalSettingsData, error: operationalSettingsError }
  ] = await Promise.all([
    supabase.from('screens').select('*').order('created_at', { ascending: false }),
    supabase.from('playlists').select('*').order('name', { ascending: true }),
    supabase.from('playlist_versions').select('id,playlist_id,version,playlist_name,created_by,created_at').order('version', { ascending: false }).limit(1000),
    supabase.from('team_members').select('user_id,email,role').order('email', { ascending: true }),
    supabase.from('channels').select('*').order('name', { ascending: true }),
    supabase.from('channel_playlists').select('*').order('channel_id').order('sort_order'),
    supabase.from('screen_channel_schedules').select('*').order('priority', { ascending: true }),
    supabase.from('screen_commands').select('id,screen_id,command,status,created_at,completed_at,error_message').order('created_at', { ascending: false }).limit(100),
    supabase.from('screen_publications').select('screen_id,revision,published_at').order('revision', { ascending: false }),
    supabase.from('screen_publication_requests').select('id,screen_id,status,requested_by,requested_at,reviewed_by,reviewed_at,review_note').order('requested_at', { ascending: false }).limit(200),
    supabase.from('media_library').select('*').order('updated_at', { ascending: false }).limit(300),
    supabase.from('media_folders').select('id,name').order('name', { ascending: true }),
    supabase.from('media_library_versions').select('id,asset_id,version,source_url,file_name,created_at').order('version', { ascending: false }).limit(1000),
    supabase.from('screen_groups').select('*').order('name', { ascending: true }),
    supabase.from('screen_group_members').select('id,group_id,user_id,created_at').order('created_at', { ascending: true }),
    supabase.from('locations').select('id,name,description,created_at').order('name', { ascending: true }),
    supabase.from('location_members').select('id,location_id,user_id,created_at').order('created_at', { ascending: true }),
    supabase.from('screen_broadcasts').select('id,slide_id,title,body,kind,source_url,duration_seconds,starts_at,ends_at,created_at,cancelled_at,screen_broadcast_targets(screen_id,superseded_at)').is('cancelled_at', null).gt('ends_at', new Date().toISOString()).order('starts_at', { ascending: true }).limit(100),
    supabase.from('team_operational_settings').select('offline_alert_after_minutes,command_alert_after_minutes,feed_error_window_minutes').eq('id', true).maybeSingle()
  ]);
  if (loadId !== screensLoadId || currentUser?.id !== userId) return;
  if (error) return toast(error.message, true);
  if (playlistError) return toast(playlistError.message, true);
  if (playlistVersionError && playlistVersionError.code !== '42P01') return toast(playlistVersionError.message, true);
  if (memberError) return toast(memberError.message, true);
  if (channelError) return toast(channelError.message, true);
  if (channelPlaylistError) return toast(channelPlaylistError.message, true);
  if (channelScheduleError) return toast(channelScheduleError.message, true);
  if (commandError) return toast(commandError.message, true);
  if (publicationError) return toast(publicationError.message, true);
  if (approvalError && approvalError.code !== '42P01') return toast(approvalError.message, true);
  if (mediaError && mediaError.code !== '42P01') return toast(mediaError.message, true);
  if (mediaFolderError) return toast(mediaFolderError.message, true);
  if (mediaVersionError) return toast(mediaVersionError.message, true);
  if (groupError) return toast(groupError.message, true);
  if (groupMemberError) return toast(groupMemberError.message, true);
  if (locationError) return toast(locationError.message, true);
  if (locationMemberError) return toast(locationMemberError.message, true);
  if (broadcastError && broadcastError.code !== '42P01') return toast(broadcastError.message, true);
  teamMembers = memberData || [];
  currentRole = teamMembers.find(member => member.user_id === userId)?.role || null;
  updateRoleVisibility();
  if (!currentRole) {
    showNotice('Det här kontot saknar en teamroll. Be en administratör att tilldela åtkomst.');
    screens = [];
    screenGroups = [];
    screenGroupMembers = [];
    locations = [];
    locationMembers = [];
    mediaFolders = [];
    mediaLibraryVersions = [];
    playlists = [];
    $('#emptyState').classList.add('hidden');
    updateScreenSummary();
    return;
  }
  if (['admin', 'editor'].includes(currentRole)) await loadIntegrationCatalog();
  else {
    signageIntegrations = [];
    populateFeedIntegrationSelects();
  }
  notice.classList.add('hidden');
  const nextScreens = data || [];
  const nextScreenGroups = groupData || [];
  const nextPlaylists = playlistData || [];
  const playlistIds = nextPlaylists.map(item => item.id);
  const { data: playlistSlideData, error: playlistSlideError } = playlistIds.length
    ? await supabase.from('slides').select('*').in('playlist_id', playlistIds).order('sort_order', { ascending: true })
    : { data: [], error: null };
  if (playlistSlideError) return toast(playlistSlideError.message, true);
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
  renderPlaybackScreenOptions();
  screenGroups = nextScreenGroups;
  screenGroupMembers = groupMemberData || [];
  locations = locationData || [];
  locationMembers = locationMemberData || [];
  playlists = nextPlaylists;
  playlistVersions = playlistVersionError ? [] : (playlistVersionData || []);
  playlistVersionHistoryAvailable = !playlistVersionError;
  playlistSlides = playlistSlideData || [];
  channels = nextChannels;
  channelPlaylists = channelPlaylistData || [];
  channelSchedules = channelScheduleData || [];
  screenCommands = commandData || [];
  screenBroadcasts = broadcastError ? [] : (broadcastData || []);
  operationalSettingsAvailable = !operationalSettingsError;
  operationalSettings = { ...defaultOperationalSettings, ...(operationalSettingsData || {}) };
  renderOperationalAlertSettings();
  await loadScreenBroadcastDelivery();
  if (loadId !== screensLoadId || currentUser?.id !== userId) return;
  screenPublications = publicationData || [];
  const latestPublications = new Map();
  const publicationHistory = new Map();
  (publicationData || []).forEach(publication => {
    if (!latestPublications.has(publication.screen_id)) latestPublications.set(publication.screen_id, publication);
    if (!publicationHistory.has(publication.screen_id)) publicationHistory.set(publication.screen_id, []);
    publicationHistory.get(publication.screen_id).push(publication);
  });
  mediaLibrary = mediaData || [];
  mediaFolders = mediaFolderData || [];
  mediaLibraryVersions = mediaVersionData || [];
  updateBroadcastAssetOptions();
  renderBroadcastTargets();
  updateChannelControls();
  updateChannelManagement();
  renderScreenGroups();
  renderLocations();
  renderScreenBroadcasts();
  renderPlaylistLibrary();
  renderMediaLibrary();
  $('#emptyState').classList.toggle('hidden', screens.length > 0);
  if (screens.length === 0 && currentRole === 'group_member') {
    $('#emptyState').innerHTML = '<div class="empty-icon">▣</div><h2>Ingen gruppåtkomst ännu</h2><p>Be en administratör lägga till dig i den skärmgrupp du ska kunna följa.</p>';
  } else {
    $('#emptyState').innerHTML = '<div class="empty-icon">▣</div><h2>Din första skärm börjar här</h2><p>Skapa en skärm, koppla TV-appen med parkopplingskoden och lägg till ditt första innehåll.</p>';
  }
  const duplicateNames = new Map();
  screens.forEach(screen => {
    const key = screenNameKey(screen);
    duplicateNames.set(key, (duplicateNames.get(key) || 0) + 1);
  });
  screenRenderData = new Map();
  screens.forEach((screen, index) => {
    const { data: slides, error: slideError } = slideResults[index];
    if (slideError) toast(slideError.message, true);
    const screenChannelIds = new Set(channelSchedules.filter(item => item.screen_id === screen.id).map(item => item.channel_id));
    const screenChannelPlaylistIds = new Set(channelPlaylists.filter(item => screenChannelIds.has(item.channel_id)).map(item => item.playlist_id));
    const screenChannelSlides = (channelSlideData || []).filter(item => screenChannelPlaylistIds.has(item.playlist_id));
    const args = [screen, slides || [], channelSchedules.filter(item => item.screen_id === screen.id), duplicateNames.get(screenNameKey(screen)) || 1, screenCommands.find(command => command.screen_id === screen.id), screenChannelSlides, latestPublications.get(screen.id), publicationHistory.get(screen.id) || [], (approvalData || []).filter(request => request.screen_id === screen.id)];
    screenRenderData.set(screen.id, args);
  });
  renderScreenDirectory();
  if (selectedScreenDetailId && activeWorkspace === 'screen-detail') {
    if (screenRenderData.has(selectedScreenDetailId)) openScreenDetails(selectedScreenDetailId);
    else { selectedScreenDetailId = null; setWorkspace('screens'); }
  }
  selectedScreenIds.forEach(id => { if (!screens.some(screen => screen.id === id)) selectedScreenIds.delete(id); });
  $('#selectVisibleScreens').classList.toggle('hidden', !['admin', 'editor'].includes(currentRole));
  applyScreenFilters();
  updateBulkScreenActions();
  refreshOperationalAlerts();
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
  $('#createPlaylistForm').closest('.playlist-library-bar').classList.toggle('role-hidden', !editor);
  $('#createScreenGroupForm').classList.toggle('hidden', !admin);
  document.querySelectorAll('.admin-only').forEach(control => control.classList.toggle('hidden', !admin));
  document.querySelectorAll('.editor-only').forEach(control => control.classList.toggle('hidden', !editor));
  document.querySelectorAll('.workspace-tab').forEach(button => {
    button.classList.toggle('hidden', (button.dataset.workspace === 'team' && !admin)
      || (button.dataset.workspace === 'activity' && !admin)
      || (button.dataset.workspace === 'organization' && !admin)
      || (button.dataset.workspace === 'broadcasts' && !editor)
      || (button.dataset.workspace !== 'screens' && !currentRole));
  });
  document.querySelectorAll('[data-workspace-nav-group]').forEach(group => {
    group.classList.toggle('hidden', ![...group.querySelectorAll('.workspace-tab')].some(button => !button.classList.contains('hidden')));
  });
  if (!currentRole || (['team', 'activity', 'organization'].includes(activeWorkspace) && !admin)
    || (activeWorkspace === 'broadcasts' && !editor)) setWorkspace('screens');
}

function updateChannelControls() {
  const select = $('#channelPlaylist');
  if (select) select.innerHTML = `<option value="">Välj spellista</option>${playlists.map(item => `<option value="${esc(item.id)}">${esc(item.name)}</option>`).join('')}`;
}

function screenGroupOptions(selectedId = '') {
  return `<option value="">Ingen grupp</option>${screenGroups.map(group => `<option value="${esc(group.id)}" ${group.id === selectedId ? 'selected' : ''}>${esc(group.name)}</option>`).join('')}`;
}

function screenLocationOptions(selectedId = '', includeNone = true) {
  return `${includeNone ? '<option value="">Ingen plats</option>' : ''}${locations.map(location => `<option value="${esc(location.id)}" ${location.id === selectedId ? 'selected' : ''}>${esc(location.name)}</option>`).join('')}`;
}

function renderLocations() {
  const admin = currentRole === 'admin';
  const locationFilter = $('#locationFilter');
  const previousFilter = locationFilter.value;
  locationFilter.innerHTML = `<option value="all">Alla platser</option><option value="unassigned">Ingen plats</option>${locations.map(location => `<option value="${esc(location.id)}">${esc(location.name)}</option>`).join('')}`;
  locationFilter.value = previousFilter === 'all' || previousFilter === 'unassigned' || locations.some(location => location.id === previousFilter) ? previousFilter : 'all';
  const locationSelect = $('#newScreenLocation');
  const previousLocation = locationSelect.value;
  locationSelect.innerHTML = screenLocationOptions(previousLocation);
  if (locations.some(location => location.id === previousLocation)) locationSelect.value = previousLocation;
  else if (locations.length) locationSelect.value = locations[0].id;
  const bulkLocation = $('#bulkScreenLocation');
  const previousBulkLocation = bulkLocation.value;
  bulkLocation.innerHTML = `<option value="__skip__">Välj plats</option><option value="">Ingen plats</option>${locations.map(location => `<option value="${esc(location.id)}">${esc(location.name)}</option>`).join('')}`;
  if (previousBulkLocation === '__skip__' || previousBulkLocation === '' || locations.some(location => location.id === previousBulkLocation)) bulkLocation.value = previousBulkLocation;
  else bulkLocation.value = '__skip__';

  const list = $('#locationList');
  list.replaceChildren(...locations.map(location => {
    const screensInLocation = logicalScreens().filter(screen => screen.location_id === location.id);
    const members = locationMembers.filter(member => member.location_id === location.id);
    const assignedUsers = new Set(members.map(member => member.user_id));
    const availableMembers = teamMembers.filter(member => member.role === 'group_member' && !assignedUsers.has(member.user_id));
    const card = document.createElement('article');
    card.className = 'location-card';
    card.innerHTML = admin
      ? `<div class="location-card-heading"><form class="location-edit-form" data-location-edit="${esc(location.id)}"><input name="name" value="${esc(location.name)}" maxlength="80" required aria-label="Platsnamn" /><input name="description" value="${esc(location.description || '')}" maxlength="240" placeholder="Beskrivning" aria-label="Platsbeskrivning" /><button class="button ghost small" type="submit">Spara</button></form><span class="location-screen-count">${screensInLocation.length} skärmar</span><button class="icon-button delete" type="button" data-location-delete="${esc(location.id)}" aria-label="Ta bort plats ${esc(location.name)}" ${screensInLocation.length ? 'disabled title="Flytta skärmarna från platsen först."' : ''}>×</button></div><div class="location-access"><strong>Platsåtkomst · ${members.length}</strong><div class="location-members">${members.map(member => `<span class="location-member">${esc(teamMembers.find(user => user.user_id === member.user_id)?.email || 'Okänd medlem')}<button class="icon-button delete" type="button" data-location-member-delete="${esc(member.id)}" aria-label="Ta bort platsåtkomst">×</button></span>`).join('') || '<span class="screen-groups-empty">Inga platsmedlemmar.</span>'}</div><form class="location-member-add" data-location-member-add="${esc(location.id)}"><select name="user_id" aria-label="Gruppmedlem att lägga till på platsen" required><option value="">Lägg till gruppmedlem</option>${availableMembers.map(member => `<option value="${esc(member.user_id)}">${esc(member.email)}</option>`).join('')}</select><button class="button ghost small" type="submit" ${availableMembers.length ? '' : 'disabled'}>Lägg till</button>${availableMembers.length ? '' : '<span class="screen-groups-empty">Skapa först en gruppmedlem under Team.</span>'}</form></div>`
      : `<div class="location-card-heading"><div><strong>${esc(location.name)}</strong><span>${esc(location.description || '')}</span></div><span class="location-screen-count">${screensInLocation.length} skärmar</span></div>`;
    return card;
  }));
  if (!locations.length) list.innerHTML = '<span class="screen-groups-empty">Skapa en plats och tilldela sedan skärmar eller gruppmedlemmar.</span>';
}

function renderScreenGroups() {
  const currentFilter = $('#groupFilter').value;
  $('#groupFilter').innerHTML = `<option value="all">Alla grupper</option><option value="ungrouped">Ingen grupp</option>${screenGroups.map(group => `<option value="${esc(group.id)}">${esc(group.name)}</option>`).join('')}`;
  $('#groupFilter').value = currentFilter === 'all' || currentFilter === 'ungrouped' || screenGroups.some(group => group.id === currentFilter) ? currentFilter : 'all';
  $('#newScreenGroup').innerHTML = screenGroupOptions();
  $('#bulkScreenGroup').innerHTML = `<option value="__skip__">Välj grupp</option>${screenGroupOptions()}`;
  const admin = currentRole === 'admin';
  const list = $('#screenGroupList');
  list.replaceChildren(...screenGroups.map(group => {
    const count = logicalScreens().filter(screen => screen.group_id === group.id).length;
    const memberships = screenGroupMembers.filter(item => item.group_id === group.id);
    const row = document.createElement('div');
    row.className = 'screen-group-item';
    const memberUsers = new Set(memberships.map(item => item.user_id));
    const availableMembers = teamMembers.filter(member => member.role === 'group_member' && !memberUsers.has(member.user_id));
    row.innerHTML = admin
      ? `<form class="screen-group-edit" data-screen-group-edit="${esc(group.id)}"><input name="name" value="${esc(group.name)}" maxlength="64" required aria-label="Gruppnamn" /><input name="description" value="${esc(group.description || '')}" maxlength="160" placeholder="Beskrivning" aria-label="Gruppbeskrivning" /><span class="screen-group-count">${count} skärmar</span><button class="button ghost small" type="submit">Spara</button><button class="icon-button delete" type="button" data-screen-group-delete="${esc(group.id)}" aria-label="Ta bort grupp ${esc(group.name)}">×</button></form><div class="screen-group-access"><strong>Gruppåtkomst · ${memberships.length}</strong><div class="screen-group-members">${memberships.map(item => `<span class="screen-group-member">${esc(teamMembers.find(member => member.user_id === item.user_id)?.email || 'Okänd medlem')}<button class="icon-button delete" type="button" data-screen-group-member-delete="${esc(item.id)}" aria-label="Ta bort gruppåtkomst">×</button></span>`).join('') || '<span class="screen-groups-empty">Inga gruppmedlemmar.</span>'}</div><form class="screen-group-member-add" data-screen-group-member-add="${esc(group.id)}"><select name="user_id" aria-label="Gruppmedlem att lägga till" required><option value="">Lägg till gruppmedlem</option>${availableMembers.map(member => `<option value="${esc(member.user_id)}">${esc(member.email)}</option>`).join('')}</select><button class="button ghost small" type="submit" ${availableMembers.length ? '' : 'disabled'}>Lägg till</button>${availableMembers.length ? '' : '<span class="screen-groups-empty">Skapa först en gruppmedlem under Team.</span>'}</form></div>`
      : `<div class="screen-group-readonly"><strong>${esc(group.name)}</strong><span>${esc(group.description || '')}</span><span class="screen-group-count">${count} skärmar</span></div>`;
    return row;
  }));
  if (!screenGroups.length) list.innerHTML = '<span class="screen-groups-empty">Inga grupper ännu. Skärmar kan fortfarande hanteras var för sig.</span>';
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
    card.innerHTML = `<div class="channel-manage-heading"><strong>${esc(channel.name)}</strong><span>${memberships.length} spellistor</span></div><div class="channel-playlist-items">${memberships.map((item, index) => { const playlist = playlists.find(value => value.id === item.playlist_id); return `<article class="channel-playlist-entry"><div class="channel-playlist-item"><div><strong>${esc(playlist?.name || 'Okänd spellista')}</strong><span>Prioritet ${item.priority} · ordning ${item.sort_order + 1} · ${scheduleSummary(item)}</span></div><div class="channel-playlist-actions"><button class="icon-button" type="button" data-channel-playlist-move="${esc(item.id)}" data-channel-id="${esc(channel.id)}" data-direction="up" aria-label="Flytta upp ${esc(playlist?.name || 'spellista')}" ${!canEdit || index === 0 ? 'disabled' : ''}>↑</button><button class="icon-button" type="button" data-channel-playlist-move="${esc(item.id)}" data-channel-id="${esc(channel.id)}" data-direction="down" aria-label="Flytta ned ${esc(playlist?.name || 'spellista')}" ${!canEdit || index === memberships.length - 1 ? 'disabled' : ''}>↓</button><button class="button ghost small" type="button" data-channel-playlist-remove="${esc(item.id)}" ${canEdit ? '' : 'hidden'}>Ta bort</button></div></div>${canEdit ? `<details class="channel-playlist-edit"><summary>Ändra tider och prioritet</summary><form data-channel-playlist-edit="${esc(item.id)}" data-channel-id="${esc(channel.id)}"><label>Prioritet<input name="priority" type="number" min="0" max="1000" value="${Number(item.priority)}" required /></label>${scheduleFields(item)}<button class="button ghost small" type="submit">Spara ändringar som utkast</button></form></details>` : ''}</article>`; }).join('') || '<div class="slide-sub">Kanalen har inga spellistor.</div>'}</div>${canEdit ? `<form class="channel-playlist-form" data-channel-id="${esc(channel.id)}"><select name="playlist_id" required aria-label="Spellista att lägga till"><option value="">Lägg till spellista</option>${available.map(item => `<option value="${esc(item.id)}">${esc(item.name)}</option>`).join('')}</select><input name="priority" type="number" min="0" max="1000" value="100" aria-label="Prioritet" />${scheduleFields()}<button class="button ghost small" type="submit" ${available.length ? '' : 'disabled'}>＋ Lägg till i kanalen</button></form>` : ''}`;
    return card;
  }));
  if (!channels.length) container.innerHTML = '<div class="slide-sub">Skapa en kanal och välj dess första spellista ovan.</div>';
  renderChannelCalendar();
}

function weekStartFor(date) {
  const start = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  start.setDate(start.getDate() - ((start.getDay() + 6) % 7));
  return start;
}

function calendarDateLabel(date, options = { day: 'numeric', month: 'short' }) {
  return new Intl.DateTimeFormat('sv-SE', options).format(date);
}

function updateChannelCalendarScreens() {
  const select = $('#channelCalendarScreen');
  if (!select) return;
  const previous = screens.find(screen => screen.id === select.value);
  const selected = previous ? logicalScreenFor(previous.id)?.id : select.value || 'all';
  const availableScreens = logicalScreens();
  select.innerHTML = `<option value="all">Alla skärmar</option>${availableScreens.map(screen => `<option value="${esc(screen.id)}">${esc(screen.name)}${screenGroups.find(group => group.id === screen.group_id) ? ` · ${esc(screenGroups.find(group => group.id === screen.group_id).name)}` : ''}</option>`).join('')}`;
  select.value = availableScreens.some(screen => screen.id === selected) ? selected : 'all';
}

function scheduleDaySegments(schedule, dayStart, weekday) {
  const startValue = schedule.daily_start_time;
  const endValue = schedule.daily_end_time;
  const selectedDays = Array.isArray(schedule.weekdays) ? schedule.weekdays.map(Number).filter(day => day >= 1 && day <= 7) : [];
  const isSelected = day => !selectedDays.length || selectedDays.includes(day);
  const toMinutes = value => {
    const [hours, minutes] = String(value).split(':').map(Number);
    return hours * 60 + minutes;
  };
  let segments;
  if (!startValue || !endValue) {
    segments = isSelected(weekday) ? [[0, 1440]] : [];
  } else {
    const start = toMinutes(startValue);
    const end = toMinutes(endValue);
    if (start === end) return [];
    if (end > start) {
      segments = isSelected(weekday) ? [[start, end]] : [];
    } else {
      const previousWeekday = weekday === 1 ? 7 : weekday - 1;
      segments = [
        ...(isSelected(previousWeekday) ? [[0, end]] : []),
        ...(isSelected(weekday) ? [[start, 1440]] : [])
      ];
    }
  }
  const clamp = (value, fallback) => {
    if (!value) return fallback;
    return Math.max(0, Math.min(1440, (new Date(value).getTime() - dayStart.getTime()) / 60000));
  };
  const activeFrom = clamp(schedule.active_from, 0);
  const activeUntil = clamp(schedule.active_until, 1440);
  return segments.map(([start, end]) => [Math.max(start, activeFrom), Math.min(end, activeUntil)])
    .filter(([start, end]) => start < end);
}

function findScheduleConflicts(entries, dayStart, weekday) {
  const conflicts = new Map();
  const byScreen = new Map();
  entries.forEach(schedule => {
    const screen = screens.find(item => item.id === schedule.screen_id);
    const key = screen ? screenProfileKey(screen) : schedule.screen_id;
    const group = byScreen.get(key) || [];
    group.push(schedule);
    byScreen.set(key, group);
  });
  byScreen.forEach(group => {
    for (let leftIndex = 0; leftIndex < group.length; leftIndex++) {
      for (let rightIndex = leftIndex + 1; rightIndex < group.length; rightIndex++) {
        const left = group[leftIndex];
        const right = group[rightIndex];
        const overlaps = scheduleDaySegments(left, dayStart, weekday).some(([leftStart, leftEnd]) =>
          scheduleDaySegments(right, dayStart, weekday).some(([rightStart, rightEnd]) => leftStart < rightEnd && rightStart < leftEnd));
        if (!overlaps) continue;
        conflicts.set(left.id, [...(conflicts.get(left.id) || []), right]);
        conflicts.set(right.id, [...(conflicts.get(right.id) || []), left]);
      }
    }
  });
  return conflicts;
}

function channelScheduleDefinitionKey(schedule) {
  return JSON.stringify([
    schedule.channel_id,
    Number(schedule.priority),
    schedule.active_from || null,
    schedule.active_until || null,
    [...(schedule.weekdays || [])].map(Number).sort((a, b) => a - b),
    schedule.daily_start_time || null,
    schedule.daily_end_time || null
  ]);
}

function duplicateLogicalChannelSchedules(schedule) {
  const screen = screens.find(item => item.id === schedule.screen_id);
  const profileKey = screen ? screenProfileKey(screen) : schedule.screen_id;
  const definitionKey = channelScheduleDefinitionKey(schedule);
  return channelSchedules.filter(item => {
    const itemScreen = screens.find(candidate => candidate.id === item.screen_id);
    return (itemScreen ? screenProfileKey(itemScreen) : item.screen_id) === profileKey
      && channelScheduleDefinitionKey(item) === definitionKey;
  });
}

function suggestChannelPriority(schedule) {
  const screen = screens.find(item => item.id === schedule.screen_id);
  const profileKey = screen ? screenProfileKey(screen) : schedule.screen_id;
  const duplicateIds = new Set(duplicateLogicalChannelSchedules(schedule).map(item => item.id));
  const used = new Set(channelSchedules.filter(item => {
    const itemScreen = screens.find(candidate => candidate.id === item.screen_id);
    return (itemScreen ? screenProfileKey(itemScreen) : item.screen_id) === profileKey
      && !duplicateIds.has(item.id);
  }).map(item => Number(item.priority)));
  const current = Number(schedule.priority);
  for (let priority = current + 1; priority <= 1000; priority++) {
    if (!used.has(priority)) return priority;
  }
  for (let priority = current - 1; priority >= 0; priority--) {
    if (!used.has(priority)) return priority;
  }
  return null;
}

function renderChannelCalendar() {
  const grid = $('#channelCalendarGrid');
  const range = $('#channelCalendarRange');
  if (!grid || !range) return;
  updateChannelCalendarScreens();
  const start = weekStartFor(new Date());
  start.setDate(start.getDate() + channelCalendarOffset * 7);
  const days = Array.from({ length: 7 }, (_, index) => {
    const day = new Date(start);
    day.setDate(start.getDate() + index);
    return day;
  });
  const end = days[6];
  const rangeOptions = { day: 'numeric', month: 'long' };
  range.textContent = `${calendarDateLabel(days[0], rangeOptions)} – ${calendarDateLabel(end, rangeOptions)} ${end.getFullYear()}`;
  const selectedScreen = $('#channelCalendarScreen').value;
  const selectedScreenIds = selectedScreen === 'all' ? null : new Set(screenProfileIds(selectedScreen));
  const visibleSchedulesByKey = new Map();
  channelSchedules.filter(schedule => !selectedScreenIds || selectedScreenIds.has(schedule.screen_id)).forEach(schedule => {
    const screen = screens.find(item => item.id === schedule.screen_id);
    const key = JSON.stringify([
      screen ? screenProfileKey(screen) : schedule.screen_id,
      schedule.channel_id,
      Number(schedule.priority),
      schedule.active_from || null,
      schedule.active_until || null,
      schedule.daily_start_time || null,
      schedule.daily_end_time || null,
      [...(schedule.weekdays || [])].map(Number).sort((a, b) => a - b)
    ]);
    if (!visibleSchedulesByKey.has(key)) visibleSchedulesByKey.set(key, schedule);
  });
  const visibleSchedules = [...visibleSchedulesByKey.values()];
  const suggestedConflictPairs = new Set();
  grid.innerHTML = days.map(day => {
    const weekday = ((day.getDay() + 6) % 7) + 1;
    const dayStart = new Date(day.getFullYear(), day.getMonth(), day.getDate());
    const entries = visibleSchedules.filter(schedule => scheduleDaySegments(schedule, dayStart, weekday).length > 0)
      .sort((a, b) => String(a.daily_start_time || '').localeCompare(String(b.daily_start_time || '')) || Number(a.priority) - Number(b.priority));
    const conflicts = findScheduleConflicts(entries, dayStart, weekday);
    const items = entries.map(schedule => {
      const screen = logicalScreenFor(schedule.screen_id) || screens.find(item => item.id === schedule.screen_id);
      const channel = channels.find(item => item.id === schedule.channel_id);
      if (!screen || !channel) return '';
      const segments = scheduleDaySegments(schedule, dayStart, weekday);
      const formatMinute = value => {
        if (value >= 1440) return '24:00';
        const minute = Math.floor(value);
        return `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;
      };
      const time = schedule.daily_start_time && schedule.daily_end_time
        ? segments.map(([segmentStart, segmentEnd]) => `${formatMinute(segmentStart)}–${formatMinute(segmentEnd)}`).join(' + ')
        : 'Hela dagen';
      const continuesFromPreviousDay = Boolean(schedule.daily_start_time && schedule.daily_end_time
        && String(schedule.daily_start_time).slice(0, 5) > String(schedule.daily_end_time).slice(0, 5)
        && segments.some(([segmentStart]) => segmentStart === 0));
      const overlaps = conflicts.get(schedule.id) || [];
      const conflictNote = overlaps.map(other => {
        const otherChannel = channels.find(item => item.id === other.channel_id);
        const priority = Number(schedule.priority);
        const otherPriority = Number(other.priority);
        const outcome = priority < otherPriority ? `prio ${priority} vinner` : priority > otherPriority ? `prio ${otherPriority} vinner` : `samma kanalprio ${priority}; TV:n använder spellistprio och ordning som utslagsregel`;
        const pairKey = [schedule.id, other.id].sort().join(':');
        let suggestion = '';
        if (priority === otherPriority && ['admin', 'editor'].includes(currentRole) && !suggestedConflictPairs.has(pairKey)) {
          suggestedConflictPairs.add(pairKey);
          const suggestedPriority = suggestChannelPriority(schedule);
          if (suggestedPriority !== null) {
            suggestion = ` <button class="button ghost small channel-priority-suggestion" type="button" data-schedule-id="${esc(schedule.id)}" data-suggested-priority="${suggestedPriority}">Sätt prio ${suggestedPriority}</button>`;
          }
        }
        return `<small class="channel-conflict-detail">⚠ Överlappar ${esc(otherChannel?.name || 'annan kanal')} · ${esc(outcome)}${suggestion}</small>`;
      }).join('');
      return `<article class="channel-calendar-event ${overlaps.length ? 'conflict' : ''}" ${overlaps.length ? 'aria-label="Schemakrock"' : ''}><strong>${esc(channel.name)}</strong><span>${esc(screen.name)}</span><small>${esc(time)}${continuesFromPreviousDay ? ' · fortsättning från föregående dag' : ''} · prio ${Number(schedule.priority)}</small>${schedule.active_from || schedule.active_until ? `<small>${schedule.active_from ? calendarDateLabel(new Date(schedule.active_from)) : 'Start utan gräns'} – ${schedule.active_until ? calendarDateLabel(new Date(schedule.active_until)) : 'utan slut'}</small>` : ''}${conflictNote ? `<div class="channel-conflict-note">${conflictNote}</div>` : ''}</article>`;
    }).join('');
    return `<section class="channel-calendar-day ${day.toDateString() === new Date().toDateString() ? 'today' : ''}"><header><strong>${calendarDateLabel(day, { weekday: 'short' })}</strong><span>${calendarDateLabel(day, { day: 'numeric', month: 'short' })}</span></header><div class="channel-calendar-events">${items || '<span class="channel-calendar-empty">Inget kanalschema</span>'}</div></section>`;
  }).join('');
}

$('#channelCalendarGrid').addEventListener('click', async event => {
  const button = event.target.closest('[data-suggested-priority]');
  if (!button || button.disabled || !['admin', 'editor'].includes(currentRole)) return;
  const schedule = channelSchedules.find(item => item.id === button.dataset.scheduleId);
  const priority = Number(button.dataset.suggestedPriority);
  if (!schedule || !Number.isInteger(priority) || priority < 0 || priority > 1000) return;
  const duplicates = duplicateLogicalChannelSchedules(schedule);
  const duplicateIds = new Set(duplicates.map(item => item.id));
  const screen = screens.find(item => item.id === schedule.screen_id);
  const profileKey = screen ? screenProfileKey(screen) : schedule.screen_id;
  const priorityTaken = channelSchedules.some(item => {
    if (duplicateIds.has(item.id) || Number(item.priority) !== priority) return false;
    const itemScreen = screens.find(candidate => candidate.id === item.screen_id);
    return (itemScreen ? screenProfileKey(itemScreen) : item.screen_id) === profileKey;
  });
  if (priorityTaken) {
    toast('Schemat ändrades sedan kalendern laddades. Uppdatera och välj en ny prioritetssuggestion.', true);
    return loadScreens();
  }
  button.disabled = true;
  const { error } = await supabase.from('screen_channel_schedules')
    .update({ priority })
    .in('id', duplicates.map(item => item.id));
  if (error) {
    button.disabled = false;
    return toast(error.message, true);
  }
  toast(`Prioritet ${priority} sparades som utkast${duplicates.length > 1 ? ` för ${duplicates.length} äldre skärmprofiler` : ''}. Publicera skärmen för att skicka schemat till TV:n.`);
  await loadScreens();
});

function renderPlaylistLibrary() {
  const container = $('#playlistManagementList');
  if (!container) return;
  const canEdit = ['admin', 'editor'].includes(currentRole);
  container.replaceChildren(...playlists.map(playlist => {
    const items = playlistSlides.filter(item => item.playlist_id === playlist.id);
    const screenCount = new Set(screens.filter(screen => screen.playlist_id === playlist.id).map(screenProfileKey)).size;
    const channelCount = channelPlaylists.filter(item => item.playlist_id === playlist.id).length;
    const card = document.createElement('article');
    card.className = 'playlist-manage-card';
    card.dataset.playlistId = playlist.id;
    card.innerHTML = `<div class="playlist-manage-heading"><div><span class="section-kicker">SPELLISTA · ${items.length} OBJEKT</span><form class="playlist-name-form" data-playlist-name="${esc(playlist.id)}"><input name="name" maxlength="80" value="${esc(playlist.name)}" aria-label="Spellistans namn" ${canEdit ? '' : 'disabled'} /><button class="button ghost small" type="submit" ${canEdit ? '' : 'disabled'}>Spara namn</button></form><span>${screenCount} skärmar · ${channelCount} kanaler använder listan</span></div><button class="button ghost small playlist-delete" type="button" data-playlist-delete="${esc(playlist.id)}" ${!canEdit || screenCount > 0 || channelCount > 0 ? 'disabled' : ''} title="${screenCount || channelCount ? 'Ta först bort listan från skärmar och kanaler.' : 'Ta bort tomma eller oanvända spellistor.'}">Ta bort</button></div><div class="playlist-manage-items">${items.map((item, index) => `<div class="playlist-manage-item" draggable="${canEdit ? 'true' : 'false'}" data-playlist-slide="${esc(item.id)}" aria-label="Flytta ${esc(item.title || kindLabel(item.kind))} i spellistan"><div class="slide-thumb">${item.kind === 'image' ? '▧' : item.kind === 'video' ? '▶' : item.kind === 'feed' || item.kind === 'web' ? '↗' : item.kind === 'clock' ? '◷' : 'T'}</div><div class="playlist-manage-copy"><strong>${esc(item.title || kindLabel(item.kind))}</strong><span>${esc(kindLabel(item.kind))} · ${item.duration_seconds}s</span></div><div class="playlist-manage-actions"><button class="icon-button" type="button" data-playlist-item-action="up" data-playlist-item-id="${esc(item.id)}" ${!canEdit || index === 0 ? 'disabled' : ''} aria-label="Flytta upp">↑</button><button class="icon-button" type="button" data-playlist-item-action="down" data-playlist-item-id="${esc(item.id)}" ${!canEdit || index === items.length - 1 ? 'disabled' : ''} aria-label="Flytta ned">↓</button><button class="icon-button delete" type="button" data-playlist-item-action="delete" data-playlist-item-id="${esc(item.id)}" ${!canEdit ? 'disabled' : ''} aria-label="Ta bort från spellistan">×</button></div></div>`).join('') || '<div class="playlist-manage-empty">Spellistan är tom. Lägg till publicerat material från biblioteket nedan.</div>'}</div>`;
    if (playlistVersionHistoryAvailable) {
      const history = playlistVersions.filter(version => version.playlist_id === playlist.id);
      const historyDetails = document.createElement('details');
      historyDetails.className = 'playlist-version-history';
      const summary = document.createElement('summary');
      summary.textContent = `Versionshistorik · ${history.length}`;
      historyDetails.append(summary);
      if (!history.length) {
        const empty = document.createElement('p');
        empty.className = 'playlist-manage-empty';
        empty.textContent = 'Ändringar i spellistan sparas här automatiskt.';
        historyDetails.append(empty);
      } else {
        const entries = document.createElement('div');
        entries.className = 'playlist-version-history-list';
        history.slice(0, 12).forEach(version => {
          const row = document.createElement('div');
          row.className = 'playlist-version-history-row';
          const label = document.createElement('span');
          label.textContent = `Version ${version.version} · ${new Date(version.created_at).toLocaleString('sv-SE')} · ${version.playlist_name}`;
          row.append(label);
          if (canEdit) {
            const restore = document.createElement('button');
            restore.type = 'button';
            restore.className = 'button ghost small';
            restore.dataset.playlistVersionRestore = version.id;
            restore.textContent = 'Skapa kopia från version';
            row.append(restore);
          }
          entries.append(row);
        });
        if (history.length > 12) {
          const note = document.createElement('p');
          note.textContent = `Visar de 12 senaste av ${history.length} versionerna.`;
          entries.append(note);
        }
        historyDetails.append(entries);
      }
      card.append(historyDetails);
    } else {
      const historyNotice = document.createElement('p');
      historyNotice.className = 'playlist-version-history-notice';
      historyNotice.textContent = 'Versionshistorik aktiveras när databasmigrationen 20261203100000_playlist_version_history.sql har körts.';
      card.append(historyNotice);
    }
    const heading = card.querySelector('.playlist-manage-heading');
    const actions = document.createElement('div');
    actions.className = 'playlist-manage-ops';
    const copy = document.createElement('button');
    copy.type = 'button';
    copy.className = 'button ghost small';
    copy.dataset.playlistDuplicate = playlist.id;
    copy.textContent = 'Kopiera';
    copy.title = 'Skapa en fristående kopia av spellistan och dess objekt.';
    copy.hidden = !canEdit;
    const remove = heading.querySelector('[data-playlist-delete]');
    actions.append(copy, remove);
    heading.append(actions);
    return card;
  }));
  if (!playlists.length) container.innerHTML = '<div class="playlist-manage-empty">Skapa en spellista för att samla innehåll och återanvända den på flera skärmar eller i kanaler.</div>';
}

async function savePlaylistOrder(playlistId, orderedIds) {
  const current = playlistSlides.filter(slide => slide.playlist_id === playlistId);
  const expected = new Set(current.map(slide => slide.id));
  if (orderedIds.length !== expected.size || new Set(orderedIds).size !== expected.size || orderedIds.some(id => !expected.has(id))) {
    toast('Spellistans ordning kunde inte sparas eftersom listan ändrades. Ladda om och försök igen.', true);
    await loadScreens();
    return false;
  }
  const { error } = await supabase.rpc('reorder_playlist_slides', {
    input_playlist_id: playlistId,
    input_slide_ids: orderedIds
  });
  if (error) {
    toast(error.message, true);
    await loadScreens();
    return false;
  }
  toast('Spellistans ordning uppdaterades.');
  await loadScreens();
  return true;
}

$('#playlistManagementList').addEventListener('dragstart', event => {
  const row = event.target.closest('.playlist-manage-item[draggable="true"]');
  if (!row || !event.dataTransfer) return;
  const card = row.closest('.playlist-manage-card');
  card.dataset.draggedSlide = row.dataset.playlistSlide;
  event.dataTransfer.effectAllowed = 'move';
  event.dataTransfer.setData('text/plain', row.dataset.playlistSlide);
  row.classList.add('dragging');
});

$('#playlistManagementList').addEventListener('dragover', event => {
  const target = event.target.closest('.playlist-manage-item');
  const card = target?.closest('.playlist-manage-card');
  const draggedId = card?.dataset.draggedSlide;
  const dragged = card && [...card.querySelectorAll('.playlist-manage-item')].find(item => item.dataset.playlistSlide === draggedId);
  if (!target || !dragged || target === dragged || target.closest('.playlist-manage-card') !== card) return;
  event.preventDefault();
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
  $('#playlistManagementList').querySelectorAll('.playlist-manage-item.drop-target').forEach(item => item.classList.remove('drop-target'));
  target.classList.add('drop-target');
  const bounds = target.getBoundingClientRect();
  const insertAfter = event.clientY >= bounds.top + bounds.height / 2;
  const reference = insertAfter ? target.nextElementSibling : target;
  if (reference !== dragged && reference !== dragged.nextElementSibling) target.parentElement.insertBefore(dragged, reference);
});

$('#playlistManagementList').addEventListener('drop', async event => {
  const card = event.target.closest('.playlist-manage-card');
  if (!card?.dataset.draggedSlide) return;
  event.preventDefault();
  const playlistId = card.dataset.playlistId;
  const orderedIds = [...card.querySelectorAll('.playlist-manage-item')].map(item => item.dataset.playlistSlide);
  delete card.dataset.draggedSlide;
  $('#playlistManagementList').querySelectorAll('.playlist-manage-item').forEach(item => item.classList.remove('dragging', 'drop-target'));
  await savePlaylistOrder(playlistId, orderedIds);
});

$('#playlistManagementList').addEventListener('dragend', event => {
  const card = event.target.closest('.playlist-manage-card');
  const cancelled = Boolean(card?.dataset.draggedSlide);
  if (card) delete card.dataset.draggedSlide;
  $('#playlistManagementList').querySelectorAll('.playlist-manage-item').forEach(item => item.classList.remove('dragging', 'drop-target'));
  if (cancelled) renderPlaylistLibrary();
});

$('#playlistManagementList').addEventListener('submit', async event => {
  const form = event.target.closest('[data-playlist-name]');
  if (!form) return;
  event.preventDefault();
  const name = String(new FormData(form).get('name') || '').trim();
  if (!name) return toast('Ange ett namn på spellistan.', true);
  const { error } = await supabase.from('playlists').update({ name, updated_at: new Date().toISOString() }).eq('id', form.dataset.playlistName);
  if (error) return toast(error.message, true);
  toast('Spellistans namn uppdaterades.');
  await loadScreens();
});

$('#playlistManagementList').addEventListener('click', async event => {
  const versionRestore = event.target.closest('[data-playlist-version-restore]');
  if (versionRestore && !versionRestore.disabled) {
    const version = playlistVersions.find(item => item.id === versionRestore.dataset.playlistVersionRestore);
    if (!version || !['admin','editor'].includes(currentRole)) return;
    const suggestedName = `${version.playlist_name.slice(0, 61)} – version ${version.version}`;
    const name = prompt(`Namn på den nya spellistan från version ${version.version}:`, suggestedName)?.trim();
    if (!name) return;
    if (name.length > 80) return toast('Spellistans namn får vara högst 80 tecken.', true);
    versionRestore.disabled = true;
    try {
      const { error } = await supabase.rpc('create_playlist_from_version', {
        input_version_id: version.id,
        input_name: name
      });
      if (error) return toast(error.message, true);
      toast(`En fristående spellista skapades från version ${version.version}. Befintliga skärmar och publicerat innehåll ändrades inte.`);
      await loadScreens();
    } finally {
      versionRestore.disabled = false;
    }
    return;
  }
  const duplicatePlaylist = event.target.closest('[data-playlist-duplicate]');
  if (duplicatePlaylist && !duplicatePlaylist.disabled) {
    const source = playlists.find(item => item.id === duplicatePlaylist.dataset.playlistDuplicate);
    if (!source || !['admin','editor'].includes(currentRole)) return;
    const suggestedName = `${source.name.slice(0, 72)} – kopia`;
    const name = prompt(`Namn på kopian av ”${source.name}”:`, suggestedName)?.trim();
    if (!name) return;
    if (name.length > 80) return toast('Spellistans namn får vara högst 80 tecken.', true);
    duplicatePlaylist.disabled = true;
    try {
      const { error } = await supabase.rpc('duplicate_playlist_with_content', {
        input_playlist_id: source.id,
        input_name: name
      });
      if (error) return toast(error.message, true);
      toast(`Spellistan ”${source.name}” kopierades som ”${name}”. Kopian är fristående och inte tilldelad någon skärm eller kanal.`);
      await loadScreens();
    } finally {
      duplicatePlaylist.disabled = false;
    }
    return;
  }
  const deletePlaylist = event.target.closest('[data-playlist-delete]');
  if (deletePlaylist && !deletePlaylist.disabled) {
    const playlist = playlists.find(item => item.id === deletePlaylist.dataset.playlistDelete);
    if (!playlist || !confirm(`Ta bort den oanvända spellistan ”${playlist.name}”?`)) return;
    const { error } = await supabase.from('playlists').delete().eq('id', playlist.id);
    if (error) return toast(error.message, true);
    toast('Spellistan togs bort.');
    await loadScreens();
    return;
  }
  const button = event.target.closest('[data-playlist-item-action]');
  if (!button || button.disabled) return;
  const itemId = button.dataset.playlistItemId;
  const action = button.dataset.playlistItemAction;
  const item = playlistSlides.find(slide => slide.id === itemId);
  if (!item) return;
  if (action === 'delete') {
    if (!confirm(`Ta bort ”${item.title || kindLabel(item.kind)}” från spellistan? Innehållsposten i biblioteket behålls.`)) return;
    const { error } = await supabase.from('slides').delete().eq('id', item.id);
    if (error) return toast(error.message, true);
    toast('Objektet togs bort från spellistan.');
    await loadScreens();
    return;
  }
  const siblings = playlistSlides.filter(slide => slide.playlist_id === item.playlist_id);
  const index = siblings.findIndex(slide => slide.id === item.id);
  const targetIndex = index + (action === 'up' ? -1 : 1);
  if (targetIndex < 0 || targetIndex >= siblings.length) return;
  const reordered = [...siblings];
  const [moved] = reordered.splice(index, 1);
  reordered.splice(targetIndex, 0, moved);
  await savePlaylistOrder(item.playlist_id, reordered.map(slide => slide.id));
});

function mediaFolderOptions(selectedId = '') {
  return `<option value="">Utan mapp</option>${mediaFolders.map(folder => `<option value="${esc(folder.id)}" ${folder.id === selectedId ? 'selected' : ''}>${esc(folder.name)}</option>`).join('')}`;
}

function mediaLibraryPreview(item) {
  if (['image', 'video'].includes(item.kind) && /^https?:\/\//i.test(item.source_url || '')) {
    const media = item.kind === 'image'
      ? `<img data-media-preview src="${esc(item.source_url)}" alt="Förhandsvisning av ${esc(item.title)}" loading="lazy" referrerpolicy="no-referrer" />`
      : `<video data-media-preview controls preload="metadata" playsinline aria-label="Förhandsvisning av ${esc(item.title)}"><source src="${esc(item.source_url)}" /></video>`;
    return `<details class="media-library-preview"><summary>Förhandsvisa ${item.kind === 'image' ? 'bild' : 'video'}</summary><div class="media-library-preview-stage">${media}<small data-media-preview-note>Hämtar mediaförhandsvisning …</small></div></details>`;
  }
  if (item.kind === 'text') {
    return `<details class="media-library-preview"><summary>Förhandsvisa text</summary><div class="media-library-text-preview">${esc(item.body || 'Textinnehållet är tomt.')}</div></details>`;
  }
  if (item.kind === 'web' && /^https?:\/\//i.test(item.source_url || '')) {
    return `<details class="media-library-preview"><summary>Kontrollera webblänk</summary><div class="media-library-link-preview"><span>Öppna källan separat. Vissa webbplatser blockerar inbäddning på skärmar.</span><a href="${esc(item.source_url)}" target="_blank" rel="noopener noreferrer">Öppna webbsidan ↗</a></div></details>`;
  }
  if (item.kind === 'feed') {
    return `<details class="media-library-preview"><summary>Förhandsvisning av live-data</summary><div class="media-library-link-preview"><span>Liveförhandsvisningen hämtar data på serversidan när innehållet ligger i ett skärm- eller kanalutkast. Skyddade anslutningsuppgifter skickas inte till webbläsaren.</span></div></details>`;
  }
  return '';
}

function renderMediaLibrary() {
  const list = $('#mediaLibraryList');
  if (!list) return;
  const query = ($('#mediaSearch')?.value || '').trim().toLocaleLowerCase('sv-SE');
  const folderFilter = $('#mediaFolderFilter');
  const previousFolder = folderFilter.value || 'all';
  folderFilter.innerHTML = `<option value="all">Alla mappar</option><option value="unfiled">Utan mapp</option>${mediaFolders.map(folder => `<option value="${esc(folder.id)}">${esc(folder.name)}</option>`).join('')}`;
  folderFilter.value = previousFolder === 'all' || previousFolder === 'unfiled' || mediaFolders.some(folder => folder.id === previousFolder) ? previousFolder : 'all';
  const newAssetFolder = $('#newMediaFolder');
  const previousNewFolder = newAssetFolder.value;
  newAssetFolder.innerHTML = mediaFolderOptions(previousNewFolder);
  newAssetFolder.value = mediaFolders.some(folder => folder.id === previousNewFolder) ? previousNewFolder
    : mediaFolders.some(folder => folder.id === folderFilter.value) ? folderFilter.value : '';
  const selectedFolder = folderFilter.value;
  const activeFolder = mediaFolders.find(folder => folder.id === selectedFolder);
  $('#renameMediaFolder').disabled = !activeFolder;
  $('#deleteMediaFolder').disabled = !activeFolder;
  const results = mediaLibrary.filter(item => {
    const folderName = mediaFolders.find(folder => folder.id === item.folder_id)?.name || '';
    const matchesFolder = selectedFolder === 'all'
      || (selectedFolder === 'unfiled' && !item.folder_id)
      || item.folder_id === selectedFolder;
    return matchesFolder && (!query || `${item.title} ${(item.tags || []).join(' ')} ${item.kind} ${folderName}`.toLocaleLowerCase('sv-SE').includes(query));
  });
  const options = `<option value="">Välj spellista</option>${playlists.map(playlist => `<option value="${esc(playlist.id)}">${esc(playlist.name)}</option>`).join('')}`;
  list.replaceChildren(...results.map(item => {
    const row = document.createElement('article');
    row.className = 'media-library-row';
    const integration = signageIntegrations.find(value => value.id === item.integration_id);
    const sourceLabel = integration ? `Skyddad Pulse · ${integration.name}` : item.source_url || item.body || '';
    const expired = Boolean(item.expires_at && new Date(item.expires_at).getTime() <= Date.now());
    const expiryLabel = item.expires_at ? `${expired ? 'Utgången' : 'Visas till'} ${new Date(item.expires_at).toLocaleString('sv-SE')}` : 'Ingen utgångstid';
    const folderName = mediaFolders.find(folder => folder.id === item.folder_id)?.name || 'Utan mapp';
    const fileVersions = mediaLibraryVersions.filter(version => version.asset_id === item.id);
    const hasFileHistory = ['image','video'].includes(item.kind) && fileVersions.length > 0;
    const versionHistory = hasFileHistory
      ? `<details class="media-file-history"><summary>Filhistorik · ${fileVersions.length} versioner</summary><div class="media-file-version-list">${fileVersions.map(version => `<div class="media-file-version"><span><strong>Version ${esc(version.version)}${version.source_url === item.source_url ? ' · nuvarande fil' : ''}</strong><small>${esc(version.file_name || 'Mediafil')} · ${esc(new Date(version.created_at).toLocaleString('sv-SE'))}</small></span>${version.source_url !== item.source_url && ['admin','editor'].includes(currentRole) ? `<button class="button ghost small" type="button" data-library-version-restore="${esc(version.id)}" data-library-version-asset="${esc(item.id)}">Återställ</button>` : ''}</div>`).join('')}</div></details>`
      : '';
    const fileAccept = item.kind === 'image' ? 'image/jpeg,image/png,image/webp' : 'video/mp4,video/webm,video/quicktime';
    row.innerHTML = `<div class="media-library-main"><div class="media-library-detail"><strong>${esc(item.title)}</strong><span>${esc(kindLabel(item.kind))} · ${item.duration_seconds}s${['feed','web'].includes(item.kind) ? ` · uppdateras var ${item.refresh_interval_seconds || 30}s` : ''} · ${esc(folderName)} · ${esc(expiryLabel)} ${item.tags?.length ? `· ${item.tags.map(tag => `#${esc(tag)}`).join(' ')}` : ''}</span><small>${esc(sourceLabel)}</small></div>${mediaLibraryPreview(item)}<details class="media-library-edit" ${['admin','editor'].includes(currentRole) ? '' : 'hidden'}><summary>Redigera</summary><form data-library-edit="${esc(item.id)}"><input name="title" maxlength="120" value="${esc(item.title)}" required aria-label="Namn" /><select name="folder_id" aria-label="Mapp">${mediaFolderOptions(item.folder_id || '')}</select><input name="source_url" type="url" value="${esc(item.source_url || '')}" placeholder="Källans URL" aria-label="Källans URL" /><label class="library-integration-setting ${item.kind === 'feed' ? '' : 'hidden'}">Pulse-anslutning<select name="integration_id" data-selected-integration="${esc(item.integration_id || '')}"><option value="">Vanlig JSON-feed</option></select></label><textarea name="body" maxlength="1200" placeholder="Textinnehåll" aria-label="Textinnehåll">${esc(item.body || '')}</textarea><input name="tags" maxlength="200" value="${esc((item.tags || []).join(', '))}" placeholder="Taggar, separerade med komma" aria-label="Taggar" /><label class="media-expiry-field">Utgångstid (valfritt)<input name="expires_at" type="datetime-local" value="${esc(localDateTimeInput(item.expires_at))}" /><small>Poster slutar visas efter tiden även från TV:ns offlinecache.</small></label>${['image','video'].includes(item.kind) ? `<label class="file-label">Ersätt ${item.kind === 'image' ? 'bild' : 'video'} (valfritt) <input name="file" type="file" accept="${fileAccept}" /></label>` : ''}${['feed','web'].includes(item.kind) ? `<label class="feed-refresh-setting"><span>${item.kind === 'web' ? 'Ladda om dashboard var (sek)' : 'Hämta live-data var (sek)'}</span><input name="refresh_interval_seconds" type="number" min="10" max="3600" value="${item.refresh_interval_seconds || 30}" required /><small>Den native TV-spelaren uppdaterar innehållet enligt intervallet.</small></label>` : ''}${versionHistory}<button class="button ghost small" type="submit">Spara ändringar</button></form></details></div><div class="media-library-actions"><select aria-label="Välj spellista för ${esc(item.title)}" data-library-playlist>${options}</select><button class="button ghost small" type="button" data-library-add="${esc(item.id)}" ${['admin','editor'].includes(currentRole) && !expired ? '' : 'disabled'}>${expired ? 'Utgången' : 'Lägg till'}</button><button class="icon-button delete" type="button" aria-label="Ta bort ${esc(item.title)}" data-library-delete="${esc(item.id)}" ${currentRole === 'admin' || currentRole === 'editor' ? '' : 'hidden'}>×</button></div>`;
    return row;
  }));
  list.querySelectorAll('[data-media-preview]').forEach(media => {
    const note = media.closest('.media-library-preview-stage')?.querySelector('[data-media-preview-note]');
    const failed = () => { if (note) note.textContent = 'Webbläsaren kunde inte läsa förhandsvisningen. Kontrollera källan och prova på en testskärm.'; };
    media.addEventListener('error', failed, { once: true });
    if (media instanceof HTMLImageElement) {
      media.addEventListener('load', () => {
        if (!note) return;
        const pixels = media.naturalWidth * media.naturalHeight;
        note.textContent = `${media.naturalWidth} × ${media.naturalHeight} px${pixels > 20_000_000 ? ' · mycket hög upplösning kan belasta TV-minnet' : ''} · förhandsvisning i webbläsaren`;
      }, { once: true });
    } else if (media instanceof HTMLVideoElement) {
      media.addEventListener('loadedmetadata', () => {
        if (!note) return;
        const duration = Number.isFinite(media.duration) ? `${Math.round(media.duration)} sek` : 'okänd längd';
        note.textContent = `${media.videoWidth} × ${media.videoHeight} px · ${duration} · browseravkodning bekräftad, TV-uppspelning verifieras separat`;
      }, { once: true });
    }
  });
  populateFeedIntegrationSelects();
  list.querySelectorAll('[data-library-edit] [name="integration_id"]').forEach(select => {
    select.addEventListener('change', () => syncFeedIntegrationField(select.form));
    syncFeedIntegrationField(select.form);
  });
  if (!results.length) list.innerHTML = '<div class="slide-sub">Inget innehåll matchar sökningen.</div>';
  list.querySelectorAll('[data-library-edit]').forEach(form => form.addEventListener('submit', async event => {
    event.preventDefault();
    const id = form.dataset.libraryEdit;
    const asset = mediaLibrary.find(item => item.id === id);
    if (!asset) return;
    const values = new FormData(form);
    const title = String(values.get('title') || '').trim();
    let source_url = String(values.get('source_url') || '').trim();
    const integration_id = asset.kind === 'feed' ? String(values.get('integration_id') || '') || null : null;
    const integration = signageIntegrations.find(item => item.id === integration_id);
    if (integration) source_url = integration.endpoint_url;
    const body = String(values.get('body') || '').trim();
    const expiryInput = String(values.get('expires_at') || '').trim();
    const expiryDate = expiryInput ? new Date(expiryInput) : null;
    if (expiryDate && Number.isNaN(expiryDate.getTime())) return toast('Ange en giltig utgångstid.', true);
    const expires_at = expiryDate ? expiryDate.toISOString() : null;
    if (['web', 'feed', 'image', 'video'].includes(asset.kind) && !/^https?:\/\//i.test(source_url)) return toast('Ange en giltig HTTP- eller HTTPS-källa.', true);
    if (asset.kind === 'text' && !body) return toast('Textinnehållet får inte vara tomt.', true);
    const tags = [...new Set(String(values.get('tags') || '').split(',').map(tag => tag.trim().toLocaleLowerCase('sv-SE')).filter(Boolean))];
    const refresh_interval_seconds = ['feed', 'web'].includes(asset.kind) ? Number(values.get('refresh_interval_seconds')) : asset.refresh_interval_seconds || 30;
    if (['feed', 'web'].includes(asset.kind) && (!Number.isInteger(refresh_interval_seconds) || refresh_interval_seconds < 10 || refresh_interval_seconds > 3600)) return toast('Uppdateringsintervallet ska vara 10–3600 sekunder.', true);
    if (integration_id && !integration) return toast('Den valda Pulse-anslutningen finns inte längre. Ladda om sidan.', true);
    if (asset.kind === 'feed' && !integration_id && /#token=/i.test(source_url)) return toast('Lägg Pulse-token i en skyddad Pulse-anslutning under Integrationer, inte i feed-URL:en.', true);
    const folder_id = String(values.get('folder_id') || '') || null;
    const file = values.get('file');
    let uploadedFile = null;
    if (file instanceof File && file.size > 0) {
      const maxBytes = asset.kind === 'image' ? 30 * 1024 * 1024 : 400 * 1024 * 1024;
      const allowedTypes = asset.kind === 'image' ? ['image/jpeg', 'image/png', 'image/webp'] : ['video/mp4', 'video/webm', 'video/quicktime'];
      if (!['image', 'video'].includes(asset.kind)) return toast('Endast bilder och videor kan ersättas med en uppladdad fil.', true);
      if (file.size > maxBytes) return toast(asset.kind === 'image' ? 'Bildfilen får vara högst 30 MB.' : 'Videofilen får vara högst 400 MB.', true);
      if (!allowedTypes.includes(file.type)) return toast(asset.kind === 'image' ? 'Bilder ska vara JPEG, PNG eller WebP.' : 'Videor ska vara MP4, WebM eller QuickTime.', true);
      try {
        uploadedFile = await uploadSignageFile(file, { form, prefix: `library/${currentUser.id}/${asset.id}` });
        source_url = uploadedFile.source_url;
      } catch (error) {
        return toast(error.message || 'Filen kunde inte laddas upp.', true);
      }
    }
    const { error } = await supabase.from('media_library').update({ title, source_url: source_url || null, integration_id, body, tags, folder_id, expires_at, refresh_interval_seconds, updated_at: new Date().toISOString() }).eq('id', id);
    if (error) return toast(error.message, true);
    uploadedFile?.finalize();
    toast('Biblioteksposten och dess spellistereferenser uppdaterades.');
    await loadScreens();
  }));
  list.querySelectorAll('[data-library-version-restore]').forEach(button => button.addEventListener('click', async () => {
    if (!['admin','editor'].includes(currentRole)) return;
    const version = mediaLibraryVersions.find(item => item.id === button.dataset.libraryVersionRestore);
    const asset = mediaLibrary.find(item => item.id === button.dataset.libraryVersionAsset);
    if (!version || !asset || version.asset_id !== asset.id) return toast('Filversionen kunde inte hittas. Ladda om biblioteket.', true);
    if (!confirm(`Återställ version ${version.version} av ”${asset.title}”? Detta blir den nya aktiva filen och läggs till i versionshistoriken.`)) return;
    const { error } = await supabase.from('media_library').update({ source_url: version.source_url, updated_at: new Date().toISOString() }).eq('id', asset.id);
    if (error) return toast(error.message, true);
    toast(`Version ${version.version} återställdes.`);
    await loadScreens();
  }));
  list.querySelectorAll('[data-library-add]').forEach(button => button.addEventListener('click', async () => {
    const row = button.closest('.media-library-row');
    const playlist_id = row.querySelector('[data-library-playlist]').value;
    if (!playlist_id) return toast('Välj en spellista först.', true);
    const asset = mediaLibrary.find(item => item.id === button.dataset.libraryAdd);
    if (asset?.expires_at && new Date(asset.expires_at).getTime() <= Date.now()) return toast('Den här biblioteksposten har gått ut. Ändra utgångstiden innan du lägger till den.', true);
    const { data: last, error: orderError } = await supabase.from('slides').select('sort_order').eq('playlist_id', playlist_id).order('sort_order', { ascending: false }).limit(1).maybeSingle();
    if (orderError) return toast(orderError.message, true);
    const { error } = await supabase.from('slides').insert({ playlist_id, screen_id: null, library_asset_id: asset.id, integration_id: asset.integration_id, kind: asset.kind, title: asset.title, body: asset.body, source_url: asset.source_url, duration_seconds: asset.duration_seconds, refresh_interval_seconds: asset.refresh_interval_seconds || 30, expires_at: asset.expires_at, sort_order: (last?.sort_order ?? -1) + 1, is_active: true });
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
  const labels = { admin: 'Admin', editor: 'Redaktör · alla skärmar', viewer: 'Läsbehörig · alla skärmar', group_member: 'Gruppmedlem · begränsad gruppåtkomst' };
  list.innerHTML = teamMembers.map(member => `<div class="team-member" data-user-id="${esc(member.user_id)}"><div class="team-member-identity"><strong>${esc(member.email)}</strong><span>${labels[member.role] || esc(member.role)}</span></div><select class="member-role" aria-label="Roll för ${esc(member.email)}"><option value="editor" ${member.role === 'editor' ? 'selected' : ''}>Redaktör · alla skärmar</option><option value="viewer" ${member.role === 'viewer' ? 'selected' : ''}>Läsbehörig · alla skärmar</option><option value="group_member" ${member.role === 'group_member' ? 'selected' : ''}>Gruppmedlem · valda grupper</option><option value="admin" ${member.role === 'admin' ? 'selected' : ''}>Admin</option></select><button class="button ghost small save-member">Spara</button><button class="button ghost small send-team-link" type="button">Skicka inloggningslänk</button><button class="button ghost small remove-member">Ta bort</button></div>`).join('') || '<p class="team-empty">Inga teammedlemmar ännu.</p>';
  list.querySelectorAll('.send-team-link').forEach(button => button.addEventListener('click', async () => {
    if (button.disabled) return;
    const row = button.closest('.team-member');
    const member = teamMembers.find(item => item.user_id === row?.dataset.userId);
    if (!member?.email) return toast('Medlemmen saknar e-postadress.', true);
    button.disabled = true;
    button.textContent = 'Skickar …';
    let cooldownMs = 60_000;
    try {
      const { error } = await supabase.auth.signInWithOtp({
        email: member.email,
        options: { emailRedirectTo: location.href, shouldCreateUser: false }
      });
      if (error) {
        const code = String(error.code || '').toLowerCase();
        const message = String(error.message || '').toLowerCase();
        if (error.status === 429 || code.includes('rate_limit') || message.includes('rate limit') || message.includes('too many requests')) {
          cooldownMs = 60 * 60_000;
        }
        return toast(authRequestMessage(error), true);
      }
      toast(`Inloggningslänk skickad till ${member.email}.`);
    } catch {
      toast('Kunde inte nå inloggningstjänsten just nu. Försök igen senare.', true);
    } finally {
      const retryAt = Date.now() + cooldownMs;
      const updateCooldown = () => {
        if (!button.isConnected) return;
        const secondsLeft = Math.ceil((retryAt - Date.now()) / 1000);
        if (secondsLeft <= 0) {
          button.disabled = false;
          button.textContent = 'Skicka inloggningslänk';
          button.title = '';
          return;
        }
        button.disabled = true;
        button.textContent = secondsLeft > 90 ? `Vänta ${Math.ceil(secondsLeft / 60)} min` : `Vänta ${secondsLeft} s`;
        button.title = 'Supabase tillåter inte upprepade mejl till samma mottagare direkt efter varandra.';
        setTimeout(updateCooldown, secondsLeft > 90 ? 60_000 : 1000);
      };
      updateCooldown();
    }
  }));
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

const activityEntityGroups = {
  team: new Set(['team_members', 'screen_group_members']),
  channels: new Set(['channels', 'channel_playlists', 'screen_channel_schedules'])
};
const activityEntityLabels = {
  screens: 'Skärm', slides: 'Innehåll', playlists: 'Spellista', media_library: 'Biblioteksinnehåll',
  channels: 'Kanal', channel_playlists: 'Kanalspellista', screen_channel_schedules: 'Kanalschema',
  screen_groups: 'Skärmgrupp', screen_group_members: 'Gruppåtkomst', team_members: 'Teamroll',
  screen_commands: 'Spelarkommando'
};
const activityActionLabels = { INSERT: 'skapades', UPDATE: 'uppdaterades', DELETE: 'togs bort' };
const activityFieldLabels = {
  name: 'namn', title: 'rubrik', body: 'text', source_url: 'källa', duration_seconds: 'visningstid',
  refresh_interval_seconds: 'uppdateringsintervall', sort_order: 'ordning', is_active: 'aktiv status',
  playlist_id: 'spellista', screen_id: 'skärm', group_id: 'grupp', user_id: 'medlem', role: 'roll',
  priority: 'prioritet', active_from: 'starttid', active_until: 'sluttid', weekdays: 'veckodagar',
  daily_start_time: 'daglig start', daily_end_time: 'dagligt slut', tags: 'taggar', command: 'kommando',
  forced_slide_id: 'tvingat innehåll', layout_type: 'layout', layout_text: 'layouttext',
  operating_start_time: 'öppettid', operating_end_time: 'stängningstid', playback_mode: 'uppspelningsläge',
  autostart_enabled: 'autostart', description: 'beskrivning', email: 'e-post'
};

function activityMatchesGroup(item, group) {
  if (group === 'all') return true;
  if (group === 'team' || group === 'channels') return activityEntityGroups[group].has(item.entity_type);
  if (group === 'screens') return ['screens', 'screen_groups'].includes(item.entity_type);
  if (group === 'slides') return ['slides', 'media_library'].includes(item.entity_type);
  if (group === 'playlists') return item.entity_type === 'playlists';
  return item.entity_type === group;
}

function renderActivityLog() {
  const list = $('#activityList');
  if (!list) return;
  const query = ($('#activitySearch')?.value || '').trim().toLocaleLowerCase('sv-SE');
  const group = $('#activityFilter')?.value || 'all';
  const rows = activityLog.filter(item => activityMatchesGroup(item, group)
    && (!query || `${item.actor_email} ${item.entity_label} ${item.entity_type} ${(item.changed_fields || []).join(' ')}`.toLocaleLowerCase('sv-SE').includes(query)));
  if (!activityLog.length) {
    list.innerHTML = '<div class="activity-empty">Inga registrerade händelser ännu. Nya ändringar visas här automatiskt.</div>';
    return;
  }
  if (!rows.length) {
    list.innerHTML = '<div class="activity-empty">Inget matchar filtret.</div>';
    return;
  }
  const date = value => new Intl.DateTimeFormat('sv-SE', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value));
  list.innerHTML = `<div class="activity-table" role="table" aria-label="Senaste organisationsaktiviteten"><div class="activity-table-head" role="row"><span>Tid</span><span>Person</span><span>Händelse</span><span>Ändrade fält</span></div>${rows.map(item => {
    const entity = activityEntityLabels[item.entity_type] || item.entity_type;
    const action = activityActionLabels[item.action] || item.action;
    const fields = (item.changed_fields || []).map(field => activityFieldLabels[field] || field.replaceAll('_', ' '));
    const detail = fields.length ? fields.join(', ') : item.action === 'INSERT' ? 'Ny post' : item.action === 'DELETE' ? 'Post borttagen' : '—';
    return `<div class="activity-row" role="row"><time datetime="${esc(item.created_at)}">${esc(date(item.created_at))}</time><span>${esc(item.actor_email || 'System/automatiserat')}</span><span><strong>${esc(entity)} ${esc(action)}</strong><small>${esc(item.entity_label)}</small></span><span>${esc(detail)}</span></div>`;
  }).join('')}</div>`;
}

async function loadActivityLog() {
  if (currentRole !== 'admin') return;
  const requestId = ++activityLoadId;
  const { data, error } = await supabase.from('activity_log')
    .select('id,actor_email,action,entity_type,entity_label,changed_fields,created_at')
    .order('created_at', { ascending: false }).order('id', { ascending: false }).limit(100);
  if (requestId !== activityLoadId || currentRole !== 'admin') return;
  if (error) return toast(error.message, true);
  activityLog = data || [];
  renderActivityLog();
}

function renderPlaybackScreenOptions() {
  const select = $('#playbackScreen');
  if (!select) return;
  const previousScreen = screens.find(screen => screen.id === select.value);
  const previous = previousScreen ? logicalScreenFor(previousScreen.id)?.id : select.value || 'all';
  const availableScreens = logicalScreens();
  select.innerHTML = `<option value="all">Alla TV-apparater</option>${availableScreens.map(screen => `<option value="${esc(screen.id)}">${esc(screen.name)}</option>`).join('')}`;
  select.value = availableScreens.some(screen => screen.id === previous) ? previous : 'all';
}

function filteredPlaybackEvents() {
  const search = ($('#playbackSearch')?.value || '').trim().toLocaleLowerCase('sv-SE');
  return playbackEvents.filter(event => !search || `${event.screen_name} ${event.content_title} ${event.content_kind || ''}`.toLocaleLowerCase('sv-SE').includes(search));
}

function renderPlaybackEvents() {
  const list = $('#playbackList');
  if (!list) return;
  const rows = filteredPlaybackEvents();
  const screenCount = new Set(rows.map(event => String(event.screen_name || event.screen_id || '').trim().toLocaleLowerCase('sv-SE'))).size;
  const completedMs = rows.reduce((total, event) => total + (event.ended_at ? Math.max(0, new Date(event.ended_at) - new Date(event.started_at)) : 0), 0);
  $('#playbackSummary').innerHTML = `<span><strong>${rows.length}</strong> händelser i listan</span><span><strong>${screenCount}</strong> skärmar i listan</span><span><strong>${Math.round(completedMs / 60000)}</strong> min registrerad tid i listan</span>`;
  if (!rows.length) {
    list.innerHTML = `<div class="activity-empty">${playbackEvents.length ? 'Inget matchar filtren.' : 'Ingen uppspelningshistorik under perioden. Spelaren rapporterar första posten när den byter innehåll.'}</div>`;
    return;
  }
  const date = value => new Intl.DateTimeFormat('sv-SE', { dateStyle: 'medium', timeStyle: 'medium' }).format(new Date(value));
  const duration = event => {
    if (!event.ended_at) return 'Pågår';
    const seconds = Math.max(0, Math.round((new Date(event.ended_at) - new Date(event.started_at)) / 1000));
    return seconds >= 3600 ? `${Math.floor(seconds / 3600)} h ${Math.floor(seconds % 3600 / 60)} min` : `${Math.floor(seconds / 60)} min ${seconds % 60} sek`;
  };
  list.innerHTML = `<div class="activity-table playback-table" role="table" aria-label="Uppspelningshistorik"><div class="activity-table-head" role="row"><span>Tid</span><span>Skärm</span><span>Innehåll</span><span>Rapporterad visning</span></div>${rows.map(event => `<div class="activity-row" role="row"><time datetime="${esc(event.started_at)}">${esc(date(event.started_at))}</time><span>${esc(event.screen_name)}</span><span><strong>${esc(event.content_title)}</strong><small>${esc(event.content_kind || 'innehåll')}</small></span><span>${esc(duration(event))}</span></div>`).join('')}</div>`;
}

function renderPlaybackAggregates() {
  const list = $('#playbackAggregate');
  if (!list) return;
  const search = ($('#playbackSearch')?.value || '').trim().toLocaleLowerCase('sv-SE');
  const rows = playbackAggregates.filter(item => !search
    || `${item.content_title} ${item.content_kind || ''}`.toLocaleLowerCase('sv-SE').includes(search));
  if (!rows.length) {
    list.innerHTML = `<div class="activity-empty">${playbackAggregates.length ? 'Inget innehåll matchar sökningen.' : 'Ingen avslutad visningsperiod i det valda intervallet.'}</div>`;
    return;
  }
  const formatDuration = value => {
    const minutes = Math.floor(Number(value || 0) / 60);
    return minutes >= 60 ? `${Math.floor(minutes / 60)} h ${minutes % 60} min` : `${minutes} min`;
  };
  list.innerHTML = `<div class="activity-table playback-aggregate-table" role="table" aria-label="Sammanräknad rapporterad visning per innehåll"><div class="activity-table-head" role="row"><span>Innehåll</span><span>Typ</span><span>Skärmar</span><span>Perioder</span><span>Rapporterad tid</span></div>${rows.map(item => `<div class="activity-row" role="row"><strong>${esc(item.content_title)}</strong><span>${esc(item.content_kind || 'innehåll')}</span><span>${Number(item.screen_count) || 0}</span><span>${Number(item.playback_count) || 0}</span><strong>${formatDuration(item.reported_seconds)}</strong></div>`).join('')}</div>`;
}

async function loadPlaybackEvents() {
  if (!currentRole) return;
  const from = $('#playbackFrom').value;
  const to = $('#playbackTo').value;
  if (!from || !to || from > to) return toast('Välj ett giltigt datumintervall.', true);
  const start = new Date(`${from}T00:00:00`).toISOString();
  const end = new Date(new Date(`${to}T00:00:00`).getTime() + 86400000).toISOString();
  let query = supabase.from('playback_events')
    .select('id,screen_id,screen_name,content_title,content_kind,started_at,ended_at')
    .gte('started_at', start).lt('started_at', end)
    .order('started_at', { ascending: false }).order('id', { ascending: false }).limit(1000);
  const screenId = $('#playbackScreen').value;
  const profileIds = screenId === 'all' ? [] : screenProfileIds(screenId);
  if (profileIds.length) query = query.in('screen_id', profileIds);
  const [historyResult, aggregateResults] = await Promise.all([
    query,
    Promise.all((profileIds.length ? profileIds : [null]).map(input_screen_id => supabase.rpc('team_playback_summary', {
      input_from: start,
      input_to: end,
      input_screen_id
    })))
  ]);
  if (historyResult.error) return toast(historyResult.error.message, true);
  const aggregateError = aggregateResults.find(result => result.error)?.error;
  if (aggregateError) return toast(aggregateError.message, true);
  playbackEvents = historyResult.data || [];
  if (profileIds.length <= 1) playbackAggregates = aggregateResults[0]?.data || [];
  else {
    const grouped = new Map();
    aggregateResults.flatMap(result => result.data || []).forEach(item => {
      const key = `${item.slide_id || ''}:${item.content_title}:${item.content_kind || ''}`;
      const current = grouped.get(key) || { ...item, screen_count: 1, playback_count: 0, reported_seconds: 0 };
      current.playback_count += Number(item.playback_count) || 0;
      current.reported_seconds += Number(item.reported_seconds) || 0;
      grouped.set(key, current);
    });
    playbackAggregates = [...grouped.values()].sort((a, b) => Number(b.reported_seconds) - Number(a.reported_seconds));
  }
  renderPlaybackEvents();
  renderPlaybackAggregates();
}

function exportPlaybackEvents() {
  const rows = filteredPlaybackEvents();
  if (!rows.length) return toast('Det finns inga rader att exportera.', true);
  const quote = value => `"${String(value ?? '').replaceAll('"', '""')}"`;
  const csv = [['Tid', 'Skärm', 'Innehåll', 'Typ', 'Visning slut'], ...rows.map(event => [event.started_at, event.screen_name, event.content_title, event.content_kind, event.ended_at || 'Pågår'])]
    .map(row => row.map(quote).join(',')).join('\r\n');
  const url = URL.createObjectURL(new Blob(['\ufeff', csv], { type: 'text/csv;charset=utf-8' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = `uppspelning-${localDateInput(new Date())}.csv`;
  link.click();
  URL.revokeObjectURL(url);
}

function renderIntegrationStatus() {
  const list = $('#integrationList');
  if (!list) return;
  const query = ($('#integrationSearch').value || '').trim().toLocaleLowerCase('sv-SE');
  const filter = $('#integrationFilter').value;
  const rows = integrationStatuses.filter(item => {
    const matchesStatus = filter === 'all' || (filter === 'ok' ? item.status === 'ok' : item.status !== 'ok');
    const matchesSearch = !query || `${item.feed_title} ${item.screen_name} ${item.source_host}`.toLocaleLowerCase('sv-SE').includes(query);
    return matchesStatus && matchesSearch;
  });
  const healthy = integrationStatuses.filter(item => item.status === 'ok').length;
  $('#integrationSummary').innerHTML = `<span><strong>${integrationStatuses.length}</strong> feedanslutningar</span><span><strong>${healthy}</strong> senaste hämtning lyckades</span><span><strong>${integrationStatuses.length - healthy}</strong> fel vid senaste hämtning</span>`;
  if (!integrationStatuses.length) {
    list.innerHTML = '<div class="activity-empty">Inga skärmar har rapporterat en feed ännu. Status visas här när spelaren hämtar en JSON-feed eller Pulse-panel.</div>';
    return;
  }
  if (!rows.length) {
    list.innerHTML = '<div class="activity-empty">Inget matchar sökningen eller statusfiltret.</div>';
    return;
  }
  const formatDate = value => value ? new Intl.DateTimeFormat('sv-SE', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value)) : 'Aldrig';
  const errorLabel = item => {
    if (item.status === 'http_error') return `HTTP-fel${item.last_http_status ? ` ${item.last_http_status}` : ''}`;
    if (item.status === 'invalid_json') return 'Svaret är inte giltig JSON';
    if (item.last_error_code === 'integration_unavailable') return 'Skyddad integration kunde inte hämtas';
    if (item.status === 'network_error') return 'Nätverksfel';
    return 'Ingen felrapport';
  };
  list.innerHTML = rows.map(item => `<article class="integration-card"><div class="integration-card-main"><div class="integration-status-dot ${item.status === 'ok' ? 'ok' : 'error'}"></div><div class="integration-card-copy"><strong>${esc(item.feed_title)}</strong><span>${esc(item.screen_name)} · ${esc(item.source_host || 'Källvärd okänd')}</span><small>${item.status === 'ok' ? 'Senaste hämtning lyckades' : esc(errorLabel(item))} · försök ${esc(formatDate(item.last_attempt_at))}</small><small>Senaste lyckade hämtning · ${esc(formatDate(item.last_success_at))}</small></div></div><span class="integration-status-pill ${item.status === 'ok' ? 'ok' : 'error'}">${item.status === 'ok' ? 'Fungerar' : 'Fel'}</span></article>`).join('');
}

async function loadIntegrationCatalog() {
  if (!['admin', 'editor'].includes(currentRole)) return;
  const { data, error } = await supabase.rpc('team_list_signage_integrations');
  if (error) {
    toast(`Kunde inte läsa integrationskatalogen: ${error.message}`, true);
    return;
  }
  signageIntegrations = data || [];
  renderIntegrationCatalog();
  populateFeedIntegrationSelects();
  renderMediaLibrary();
}

function renderIntegrationCatalog() {
  const list = $('#integrationCatalogList');
  if (!list) return;
  list.innerHTML = signageIntegrations.map(item => `<article class="integration-catalog-card"><div><strong>${esc(item.name)}</strong><span>Dizparc Pulse · ${esc(item.endpoint_url)}</span></div><button class="button ghost small admin-only" type="button" data-edit-integration="${esc(item.id)}">Redigera</button></article>`).join('')
    || '<div class="activity-empty">Inga skyddade Pulse-anslutningar ännu.</div>';
  list.querySelectorAll('.admin-only').forEach(control => control.classList.toggle('hidden', currentRole !== 'admin'));
}

function populateFeedIntegrationSelects() {
  document.querySelectorAll('select[name="integration_id"]').forEach(select => {
    const selected = select.value || select.dataset.selectedIntegration || '';
    select.innerHTML = `<option value="">Vanlig JSON-feed</option>${signageIntegrations.map(item => `<option value="${esc(item.id)}">Pulse · ${esc(item.name)}</option>`).join('')}`;
    select.value = signageIntegrations.some(item => item.id === selected) ? selected : '';
    delete select.dataset.selectedIntegration;
  });
  const mainForm = $('#mediaLibraryForm');
  if (mainForm) mainForm.querySelector('.feed-integration-setting').classList.toggle('hidden', mainForm.elements.kind.value !== 'feed' || signageIntegrations.length === 0);
}

function syncFeedIntegrationField(form) {
  if (!form) return;
  const select = form.querySelector('[name="integration_id"]');
  const source = form.querySelector('[name="source_url"], [name="url"]');
  if (!select || !source) return;
  const integration = signageIntegrations.find(item => item.id === select.value);
  if (integration) {
    source.value = integration.endpoint_url;
    source.readOnly = true;
  } else {
    source.readOnly = false;
  }
}

function resetIntegrationForm() {
  const form = $('#integrationForm');
  form.reset();
  delete form.dataset.integrationId;
  form.classList.add('hidden');
  form.querySelector('[name="display_token"]').required = true;
  form.querySelector('[name="display_token"]').placeholder = 'Pulse display-token (minst 32 tecken)';
}

function openIntegrationForm(integration = null) {
  if (currentRole !== 'admin') return;
  const form = $('#integrationForm');
  form.reset();
  form.classList.remove('hidden');
  form.dataset.integrationId = integration?.id || '';
  form.elements.name.value = integration?.name || '';
  form.elements.endpoint_url.value = integration?.endpoint_url || '';
  form.elements.display_token.required = !integration;
  form.elements.display_token.placeholder = integration ? 'Ny token (lämna tomt för att behålla)' : 'Pulse display-token (minst 32 tecken)';
  form.elements.name.focus();
}

async function loadIntegrationStatus() {
  if (!currentRole) return;
  const { data, error } = await supabase.from('screen_feed_status')
    .select('screen_id,slide_id,screen_name,feed_title,source_host,status,last_attempt_at,last_success_at,last_http_status,last_error_code')
    .order('last_attempt_at', { ascending: false }).limit(300);
  if (error) return toast(error.message, true);
  integrationStatuses = data || [];
  renderIntegrationStatus();
}

function isOnline(screen) {
  return Boolean(screen.last_seen_at && Date.now() - new Date(screen.last_seen_at).getTime() < 45_000);
}

function screenProfileKey(screen) {
  const identity = String(screen?.device_identity || '').trim();
  return identity ? `device:${identity}` : `profile:${screen?.id || 'unknown'}`;
}

function screenNameKey(screen) {
  return String(screen?.name || '').trim().toLocaleLowerCase('sv-SE') || `screen-${screen?.id || 'unknown'}`;
}

function compareScreenProfiles(left, right) {
  return Number(Boolean(right.is_active)) - Number(Boolean(left.is_active))
    || Number(isOnline(right)) - Number(isOnline(left))
    || Number(Boolean(right.device_identity)) - Number(Boolean(left.device_identity))
    || Number(Boolean(left.pair_code)) - Number(Boolean(right.pair_code))
    || Number(Boolean(right.activated_at)) - Number(Boolean(left.activated_at))
    || new Date(right.created_at || 0) - new Date(left.created_at || 0);
}

function screenProfileGroups(source = screens) {
  const groups = new Map();
  source.forEach(screen => {
    const key = screenProfileKey(screen);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(screen);
  });
  return [...groups.values()];
}

function logicalScreens(source = screens) {
  return screenProfileGroups(source).map(group => [...group].sort(compareScreenProfiles)[0]);
}

function screenProfileIds(screenId) {
  const selected = screens.find(screen => screen.id === screenId);
  if (!selected) return [];
  return screens.filter(screen => screenProfileKey(screen) === screenProfileKey(selected)).map(screen => screen.id);
}

function selectedLogicalScreens() {
  const selectedKeys = new Set(screens.filter(screen => selectedScreenIds.has(screen.id)).map(screenProfileKey));
  return logicalScreens().filter(screen => selectedKeys.has(screenProfileKey(screen)));
}

function logicalScreenFor(screenId) {
  const selected = screens.find(screen => screen.id === screenId);
  if (!selected) return null;
  return logicalScreens().find(screen => screenProfileKey(screen) === screenProfileKey(selected)) || selected;
}

function formatAlertAge(value) {
  if (!value) return 'aldrig ansluten';
  const minutes = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 60000));
  if (minutes < 1) return 'nyss';
  if (minutes < 60) return `${minutes} min sedan`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours} tim sedan`;
  return `${Math.floor(hours / 24)} dagar sedan`;
}

function renderOperationalAlertSettings() {
  const form = $('#operationalAlertSettingsForm');
  if (!form) return;
  Object.keys(defaultOperationalSettings).forEach(key => {
    form.elements[key].value = operationalSettings[key];
  });
  const save = form.querySelector('button[type="submit"]');
  if (save) save.disabled = currentRole !== 'admin' || !operationalSettingsAvailable;
  const status = $('#operationalAlertSettingsStatus');
  if (status) status.textContent = operationalSettingsAvailable
    ? 'Skärmens live-status blir offline efter utebliven heartbeat. Den här gränsen styr när varningen visas.'
    : 'Inställningarna kunde inte läsas. Sparning är avstängd tills anslutningen återställs.';
}

async function saveOperationalAlertSettings(event) {
  event.preventDefault();
  if (currentRole !== 'admin') return;
  const form = event.currentTarget;
  const values = Object.fromEntries(Object.keys(defaultOperationalSettings).map(key => [key, Number(form.elements[key].value)]));
  const ranges = {
    offline_alert_after_minutes: [1, 60],
    command_alert_after_minutes: [1, 30],
    feed_error_window_minutes: [5, 240]
  };
  for (const [key, [min, max]] of Object.entries(ranges)) {
    if (!Number.isInteger(values[key]) || values[key] < min || values[key] > max) {
      return toast(`Välj ett värde mellan ${min} och ${max} minuter.`, true);
    }
  }
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    const { data, error } = await supabase.from('team_operational_settings')
      .update({ ...values, updated_at: new Date().toISOString(), updated_by: currentUser.id })
      .eq('id', true)
      .select('offline_alert_after_minutes,command_alert_after_minutes,feed_error_window_minutes')
      .single();
    if (error) return toast(error.message, true);
    operationalSettings = { ...defaultOperationalSettings, ...data };
    operationalSettingsAvailable = true;
    renderOperationalAlertSettings();
    renderOperationalAlerts();
    toast('Driftvarningarnas gränser sparades för teamet.');
  } finally {
    button.disabled = false;
  }
}

function collectOperationalAlerts() {
  const now = Date.now();
  const alerts = [];
  const offlineThresholdMs = Number(operationalSettings.offline_alert_after_minutes || defaultOperationalSettings.offline_alert_after_minutes) * 60000;
  const commandThresholdMs = Number(operationalSettings.command_alert_after_minutes || defaultOperationalSettings.command_alert_after_minutes) * 60000;
  const feedErrorWindowMs = Number(operationalSettings.feed_error_window_minutes || defaultOperationalSettings.feed_error_window_minutes) * 60000;
  const latestCommands = new Map();
  screenCommands.forEach(command => {
    if (!latestCommands.has(command.screen_id)) latestCommands.set(command.screen_id, command);
  });
  logicalScreens().filter(screen => screen.is_active).forEach(screen => {
    const lastContact = screen.last_seen_at || screen.created_at;
    const offlineForMs = lastContact ? now - new Date(lastContact).getTime() : Number.POSITIVE_INFINITY;
    if (!isOnline(screen) && offlineForMs >= offlineThresholdMs) {
      const longOffline = offlineForMs >= offlineThresholdMs * 4;
      alerts.push({
        kind: 'screen', severity: longOffline ? 0 : 1, screen,
        title: screen.last_seen_at ? 'Skärmen är offline' : 'Skärmen har aldrig anslutit',
        detail: screen.last_seen_at
          ? `Senaste kontakt ${formatAlertAge(screen.last_seen_at)} · gräns ${operationalSettings.offline_alert_after_minutes} min`
          : `Ingen första kontakt · varning efter ${operationalSettings.offline_alert_after_minutes} min från skapandet`
      });
    }
    const command = latestCommands.get(screen.id);
    const commandTime = new Date(command?.completed_at || command?.created_at || 0).getTime();
    if (command && command.status === 'failed' && now - commandTime < 86400000) {
      alerts.push({ kind: 'screen', severity: 1, screen, title: 'Fjärråtgärd misslyckades', detail: `${command.command === 'restart_player' ? 'Omstart' : 'Synk'} · ${command.error_message || 'spelaren rapporterade ett fel'}` });
    } else if (command && ['pending', 'running'].includes(command.status) && isOnline(screen) && now - new Date(command.created_at).getTime() > commandThresholdMs) {
      alerts.push({ kind: 'screen', severity: 1, screen, title: 'Fjärråtgärden väntar', detail: `${command.command === 'restart_player' ? 'Omstart' : 'Synk'} har inte kvitterats på över ${operationalSettings.command_alert_after_minutes} min.` });
    }
  });
  const recentFeedErrors = integrationStatuses.filter(item => item.status !== 'ok'
    && item.last_attempt_at && now - new Date(item.last_attempt_at).getTime() < feedErrorWindowMs);
  const seenFeedAlerts = new Set();
  recentFeedErrors.forEach(feed => {
    const screen = screens.find(item => item.id === feed.screen_id);
    if (!screen?.is_active) return;
    const alertKey = `${screenProfileKey(screen)}:${feed.slide_id || feed.feed_title}`;
    if (seenFeedAlerts.has(alertKey)) return;
    seenFeedAlerts.add(alertKey);
    const reason = feed.status === 'http_error' ? `HTTP-fel${feed.last_http_status ? ` ${feed.last_http_status}` : ''}`
      : feed.status === 'invalid_json' ? 'Svaret är inte giltig JSON' : 'Nätverksfel vid hämtning';
    alerts.push({ kind: 'feed', severity: 2, screen, title: 'Live-data har fel', detail: `${feed.feed_title} · ${reason}` });
  });
  return alerts.sort((a, b) => a.severity - b.severity || String(a.screen.name).localeCompare(String(b.screen.name), 'sv-SE'));
}

function renderOperationalAlerts() {
  const container = $('#operationalAlerts');
  if (!container) return;
  const alerts = collectOperationalAlerts();
  const contents = alerts.length
    ? `<div class="operational-alert-heading"><div><strong>Driftvarningar</strong><span>${alerts.length} kräver uppmärksamhet · offlinevarning efter ${operationalSettings.offline_alert_after_minutes} min</span></div><span class="operational-alert-count">${alerts.length}</span></div><div class="operational-alert-list">${alerts.map(alert => `<button class="operational-alert severity-${alert.severity}" type="button" data-alert-kind="${alert.kind}" data-alert-screen="${esc(alert.screen.id)}"><span class="operational-alert-mark">${alert.kind === 'feed' ? '↗' : alert.severity === 0 ? '!' : '↻'}</span><span class="operational-alert-copy"><strong>${esc(alert.screen.name || 'Skärm')} · ${esc(alert.title)}</strong><small>${esc(alert.detail)}</small></span><span class="operational-alert-action">${alert.kind === 'feed' ? 'Visa feed' : 'Öppna skärm'} →</span></button>`).join('')}</div>`
    : `<div class="operational-alert-heading healthy"><div><strong>Inga aktiva driftvarningar</strong><span>Skärmar, fjärråtgärder och nylig live-data ser bra ut · offlinevarning efter ${operationalSettings.offline_alert_after_minutes} min.</span></div><span class="operational-alert-count">✓</span></div>`;
  if (container.innerHTML !== contents) container.innerHTML = contents;
}

async function refreshOperationalAlerts() {
  if (!currentUser) return;
  const userId = currentUser.id;
  const { data, error } = await supabase.from('screen_feed_status')
    .select('screen_id,slide_id,screen_name,feed_title,source_host,status,last_attempt_at,last_success_at,last_http_status,last_error_code')
    .order('last_attempt_at', { ascending: false }).limit(300);
  if (!error && currentUser?.id === userId) integrationStatuses = data || [];
  renderOperationalAlerts();
}

$('#operationalAlerts').addEventListener('click', event => {
  const button = event.target.closest('[data-alert-screen]');
  if (!button) return;
  const screenId = button.dataset.alertScreen;
  if (button.dataset.alertKind === 'feed') {
    const screen = screens.find(item => item.id === screenId);
    setWorkspace('integrations');
    $('#integrationSearch').value = screen?.name || '';
    renderIntegrationStatus();
    return;
  }
  openScreenDetails(screenId);
});

function updateScreenSummary() {
  const devices = logicalScreens();
  const online = devices.filter(isOnline).length;
  const hiddenProfiles = screens.length - devices.length;
  $('#screenCount').textContent = `${devices.length} ${devices.length === 1 ? 'TV' : 'TV-apparater'} · ${online} online${hiddenProfiles ? ` · ${hiddenProfiles} äldre profiler dolda` : ''}`;
  renderOperationalAlerts();
  renderScreenDirectory();
}

function renderScreenDirectory() {
  if (!screenDirectoryList) return;
  const devices = logicalScreens();
  const cardsMarkup = devices.map(screen => {
    const online = isOnline(screen);
    const publication = screenRenderData.get(screen.id)?.[6] || null;
    const publishedRevision = Number(publication?.revision || 0);
    const appliedRevision = screen.applied_revision == null ? null : Number(screen.applied_revision);
    const deliveryState = !publication ? 'unpublished'
      : appliedRevision == null || appliedRevision < publishedRevision ? 'pending' : 'synced';
    const deliveryLabel = !publication ? 'Ej publicerad'
      : deliveryState === 'pending' ? (appliedRevision == null ? `Väntar på kvittens för v${publishedRevision}` : `Väntar på v${publishedRevision} · TV v${appliedRevision}`)
      : `Synkad v${appliedRevision}`;
    const group = screenGroups.find(item => item.id === screen.group_id)?.name;
    const location = locations.find(item => item.id === screen.location_id)?.name;
    const current = online ? (screen.current_title || 'Väntar på innehåll') : 'Ingen livekontakt';
    const currentKind = online ? kindLabel(screen.current_kind) : 'Offline';
    const selected = screenProfileIds(screen.id).some(id => selectedScreenIds.has(id));
    const duplicateCount = screenProfileGroups().find(entries => entries.some(item => item.id === screen.id))?.length || 1;
    const sameNameCount = screens.filter(item => screenNameKey(item) === screenNameKey(screen)).length;
    return `<article class="screen-directory-card" data-screen-id="${esc(screen.id)}" data-screen-name="${esc(screen.name || '')}" data-screen-current="${esc(screen.current_title || '')}" data-screen-status="${online ? 'online' : screen.pair_code ? 'pairing' : 'offline'}" data-screen-publish="${deliveryState}" data-screen-group="${esc(screen.group_id || '')}" data-screen-location="${esc(screen.location_id || '')}">
      <label class="screen-directory-select"><input class="screen-directory-checkbox" type="checkbox" ${selected ? 'checked' : ''} ${['admin', 'editor'].includes(currentRole) ? '' : 'disabled'} aria-label="Välj ${esc(screen.name)}" /></label>
      <button class="screen-directory-open" type="button" data-open-screen="${esc(screen.id)}" aria-label="Öppna inställningar för ${esc(screen.name)}">
        <span class="screen-directory-icon">▣</span><span class="screen-directory-main"><strong>${esc(screen.name || 'Namnlös skärm')}</strong><small>${esc([location, group].filter(Boolean).join(' · ') || 'Ingen plats eller grupp')}${duplicateCount > 1 ? ` · ${duplicateCount - 1} profil${duplicateCount > 2 ? 'er' : ''} med samma TV-ID dolda` : ''}${sameNameCount > 1 ? ` · ${sameNameCount} profiler med samma namn` : ''}</small></span>
        <span class="screen-directory-now"><small>VISAS JUST NU</small><strong>${esc(current)}</strong><small>${esc(currentKind)}</small><small class="screen-directory-delivery ${deliveryState}">PUBLICERING · ${esc(deliveryLabel)}</small></span>
        <span class="screen-directory-status ${online ? 'online' : 'offline'}"><i></i>${online ? 'Online' : screen.pair_code ? 'Parkoppling' : 'Offline'}</span><span class="screen-directory-arrow">→</span>
      </button>
    </article>`;
  }).join('') || '<div class="screen-directory-empty">Inga tillgängliga skärmar ännu.</div>';
  const markup = `${cardsMarkup}<div class="screen-directory-empty screen-directory-no-results hidden">Inga skärmar matchar de valda filtren.</div>`;
  if (screenDirectoryList.innerHTML !== markup) {
    screenDirectoryList.innerHTML = markup;
    applyScreenFilters();
  }
}

screenDirectoryList.addEventListener('click', event => {
  const checkbox = event.target.closest('.screen-directory-checkbox');
  if (checkbox) {
    const card = checkbox.closest('[data-screen-id]');
    const ids = screenProfileIds(card.dataset.screenId);
    ids.forEach(id => checkbox.checked ? selectedScreenIds.add(id) : selectedScreenIds.delete(id));
    updateBulkScreenActions();
    renderScreenDirectory();
    applyScreenFilters();
    return;
  }
  const openButton = event.target.closest('[data-open-screen]');
  if (openButton) openScreenDetails(openButton.dataset.openScreen);
});

$('#screenSearch').addEventListener('input', applyScreenFilters);
$('#screenFilter').addEventListener('change', applyScreenFilters);
$('#publicationFilter').addEventListener('change', applyScreenFilters);
$('#locationFilter').addEventListener('change', applyScreenFilters);
$('#groupFilter').addEventListener('change', applyScreenFilters);
$('#selectVisibleScreens').addEventListener('click', () => {
  const visibleCards = [...screenDirectoryList.querySelectorAll('.screen-directory-card:not(.hidden)')];
  const visibleIds = visibleCards.flatMap(card => screenProfileIds(card.dataset.screenId));
  const allSelected = visibleIds.length > 0 && visibleIds.every(id => selectedScreenIds.has(id));
  visibleIds.forEach(id => allSelected ? selectedScreenIds.delete(id) : selectedScreenIds.add(id));
  renderScreenDirectory();
  applyScreenFilters();
  $('#selectVisibleScreens').textContent = allSelected ? 'Välj synliga' : 'Avmarkera synliga';
  updateBulkScreenActions();
});
$('#clearScreenSelection').addEventListener('click', () => {
  selectedScreenIds.clear();
  renderScreenDirectory();
  applyScreenFilters();
  $('#selectVisibleScreens').textContent = 'Välj synliga';
  updateBulkScreenActions();
});
document.querySelectorAll('[data-bulk-command]').forEach(button => button.addEventListener('click', () => queueBulkPlayerCommand(button.dataset.bulkCommand, button)));
$('#publishSelectedScreens').addEventListener('click', publishSelectedScreens);
$('#screenBroadcastForm').addEventListener('submit', sendScreenBroadcast);
$('#screenBroadcastForm [name="asset_id"]').addEventListener('change', updateBroadcastTextRequirement);
$('#screenBroadcastList').addEventListener('click', cancelScreenBroadcastFromList);
$('#operationalAlertSettingsForm').addEventListener('submit', saveOperationalAlertSettings);
$('#screenBroadcastHistoryDisclosure').addEventListener('toggle', event => {
  if (event.currentTarget.open && !screenBroadcastHistoryLoaded) loadScreenBroadcastHistory();
});
$('#refreshScreenBroadcastHistory').addEventListener('click', loadScreenBroadcastHistory);
$('#assignSelectedGroup').addEventListener('click', assignSelectedScreensToGroup);
$('#assignSelectedLocation').addEventListener('click', assignSelectedScreensToLocation);

function applyScreenFilters() {
  const query = $('#screenSearch').value.trim().toLocaleLowerCase('sv-SE');
  const filter = $('#screenFilter').value;
  const publicationFilter = $('#publicationFilter').value;
  const selectedLocation = $('#locationFilter').value;
  const selectedGroup = $('#groupFilter').value;
  const visible = [];
  screenDirectoryList.querySelectorAll('.screen-directory-card').forEach(card => {
    const screen = screens.find(item => item.id === card.dataset.screenId);
    const matchesName = !query || `${screen?.name || ''} ${screen?.current_title || ''}`.toLocaleLowerCase('sv-SE').includes(query);
    const matchesStatus = filter === 'all'
      || (filter === 'online' && screen && isOnline(screen))
      || (filter === 'offline' && screen && !isOnline(screen))
      || (filter === 'pairing' && Boolean(screen?.pair_code));
    const matchesPublication = publicationFilter === 'all'
      || card.dataset.screenPublish === publicationFilter;
    const matchesGroup = selectedGroup === 'all'
      || (selectedGroup === 'ungrouped' && !screen?.group_id)
      || (screen?.group_id === selectedGroup);
    const matchesLocation = selectedLocation === 'all'
      || (selectedLocation === 'unassigned' && !screen?.location_id)
      || screen?.location_id === selectedLocation;
    const show = matchesName && matchesStatus && matchesPublication && matchesGroup && matchesLocation;
    card.classList.toggle('hidden', !show);
    if (show) visible.push(card);
  });
  $('#visibleScreenCount').textContent = `${visible.length} TV-apparater visade`;
  const noMatches = screenDirectoryList.querySelector('.screen-directory-no-results');
  if (noMatches) noMatches.classList.toggle('hidden', visible.length > 0 || screens.length === 0);
  updateBulkScreenActions();
}

async function assignSelectedScreensToGroup() {
  if (currentRole !== 'admin' || selectedScreenIds.size === 0) return;
  const value = $('#bulkScreenGroup').value;
  if (value === '__skip__') return toast('Välj en grupp eller ”Ingen grupp”.', true);
  const group_id = value || null;
  const targets = selectedLogicalScreens();
  const button = $('#assignSelectedGroup');
  button.disabled = true;
  const failures = [];
  try {
    for (const screen of targets) {
      const { error } = await supabase.from('screens').update({ group_id }).eq('id', screen.id);
      if (error) failures.push(screen.name);
    }
    const groupName = screenGroups.find(group => group.id === group_id)?.name || 'Ingen grupp';
    toast(`${targets.length - failures.length} skärmar flyttades till ”${groupName}”.${failures.length ? ` Misslyckades: ${failures.join(', ')}.` : ''}`, failures.length > 0);
    await loadScreens();
  } finally {
    button.disabled = false;
  }
}

async function assignSelectedScreensToLocation() {
  if (currentRole !== 'admin' || selectedScreenIds.size === 0) return;
  const value = $('#bulkScreenLocation').value;
  if (value === '__skip__') return toast('Välj en plats eller ”Ingen plats”.', true);
  const location_id = value || null;
  const targets = selectedLogicalScreens();
  const button = $('#assignSelectedLocation');
  button.disabled = true;
  const failures = [];
  try {
    for (const screen of targets) {
      const { error } = await supabase.from('screens').update({ location_id }).eq('id', screen.id);
      if (error) failures.push(screen.name);
    }
    const locationName = locations.find(location => location.id === location_id)?.name || 'Ingen plats';
    toast(`${targets.length - failures.length} skärmar flyttades till ”${locationName}”.${failures.length ? ` Misslyckades: ${failures.join(', ')}.` : ''}`, failures.length > 0);
  } finally {
    button.disabled = false;
  }
  await loadScreens();
}

function updateBulkScreenActions() {
  const canOperate = currentRole === 'admin' || currentRole === 'editor';
  const actions = $('#bulkScreenActions');
  if (!actions) return;
  actions.classList.toggle('hidden', !canOperate || selectedScreenIds.size === 0);
  $('#selectedScreenCount').textContent = `${selectedLogicalScreens().length} TV-apparater valda`;
  const visibleCards = [...screenDirectoryList.querySelectorAll('.screen-directory-card:not(.hidden)')];
  const visibleIds = visibleCards.flatMap(card => screenProfileIds(card.dataset.screenId));
  const allVisibleSelected = visibleIds.length > 0 && visibleIds.every(id => selectedScreenIds.has(id));
  $('#selectVisibleScreens').textContent = allVisibleSelected ? 'Avmarkera synliga' : 'Välj synliga';
}

async function queueBulkPlayerCommand(command, button) {
  const selected = selectedLogicalScreens();
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

async function publishSelectedScreens() {
  if (!['admin', 'editor'].includes(currentRole) || selectedScreenIds.size === 0) return;
  const selected = selectedLogicalScreens();
  const active = selected.filter(screen => screen.is_active);
  if (!active.length) return toast('Markera minst en aktiv skärm.', true);
  const action = currentRole === 'admin' ? 'publicera utkast på' : 'skicka utkast till admin för';
  if (!confirm(`Vill du ${action} ${active.length} aktiva skärmar? Varje skärm behandlas separat och tidigare innehåll ligger kvar om en publicering misslyckas.`)) return;

  const button = $('#publishSelectedScreens');
  button.disabled = true;
  button.textContent = currentRole === 'admin' ? 'Publicerar…' : 'Skickar…';
  const failures = [];
  let completed = 0;
  try {
    for (const screen of active) {
      const rpc = currentRole === 'admin' ? 'publish_screen_content' : 'request_screen_publication';
      const { error } = await supabase.rpc(rpc, { input_screen_id: screen.id });
      if (error) failures.push(`${screen.name}: ${error.message}`);
      else completed++;
    }
    const paused = selected.length - active.length;
    const summary = currentRole === 'admin'
      ? `${completed} av ${active.length} utkast publicerade; synk har köats`
      : `${completed} av ${active.length} utkast skickade till admin`;
    const details = [paused ? `${paused} pausade skärmar hoppades över` : '', failures.length ? `Misslyckades: ${failures.join('; ')}` : ''].filter(Boolean).join('. ');
    toast(`${summary}.${details ? ` ${details}.` : ''}`, failures.length > 0);
  } finally {
    button.disabled = false;
    button.textContent = 'Publicera valda utkast';
  }
  await loadScreens();
}

function renderScreenBroadcasts() {
  const list = $('#screenBroadcastList');
  if (!list) return;
  const now = Date.now();
  const active = screenBroadcasts.filter(item => !item.cancelled_at
    && new Date(item.ends_at).getTime() > now
    && (item.screen_broadcast_targets || []).some(target => !target.superseded_at || new Date(target.superseded_at).getTime() > now));
  if (!active.length) {
    list.innerHTML = '<span class="screen-groups-empty">Inga planerade eller aktiva tillfälliga utskick.</span>';
    return;
  }
  const receiptsByTarget = new Map(screenBroadcastDelivery.map(receipt => [`${receipt.broadcast_id}:${receipt.screen_id}`, receipt]));
  list.replaceChildren(...active.map(item => {
    const targetIds = (item.screen_broadcast_targets || []).filter(target => !target.superseded_at || new Date(target.superseded_at).getTime() > now).map(target => target.screen_id);
    const targets = targetIds.map(id => ({
      screen: screens.find(screen => screen.id === id),
      receipt: receiptsByTarget.get(`${item.id}:${id}`)
    })).filter(target => target.screen);
    const confirmedCount = targets.filter(({ screen, receipt }) => receipt?.first_shown_at
      || (isOnline(screen) && screen.current_slide_id === item.slide_id)).length;
    const showingCount = targets.filter(({ screen }) => isOnline(screen)
      && screen.current_slide_id === item.slide_id).length;
    const row = document.createElement('article');
    row.className = 'screen-broadcast-row';
    const detail = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = item.title;
    const meta = document.createElement('small');
    const startsAt = new Date(item.starts_at);
    const startsLater = startsAt.getTime() > now;
    const kind = item.kind === 'image' ? 'Bild' : item.kind === 'video' ? 'Video' : 'Text';
    const endsAt = new Date(item.ends_at);
    meta.textContent = `${kind} · ${targets.length} skärmar · ${startsLater ? `planerat ${startsAt.toLocaleString('sv-SE')}–${endsAt.toLocaleString('sv-SE')}` : `aktivt till ${endsAt.toLocaleString('sv-SE')}`} · ${showingCount} visar nu · ${screenBroadcastDeliveryAvailable ? `${confirmedCount} har visat` : 'visningskvittens otillgänglig'}${item.body ? ` · ${item.body}` : ''}`;
    detail.append(title, meta);
    const delivery = document.createElement('details');
    delivery.className = 'broadcast-delivery';
    const deliverySummary = document.createElement('summary');
    deliverySummary.textContent = 'Visa status per skärm';
    const deliveryItems = document.createElement('div');
    deliveryItems.className = 'broadcast-delivery-items';
    targets.forEach(({ screen, receipt }) => {
      const current = isOnline(screen) && screen.current_slide_id === item.slide_id;
      const status = startsLater ? 'Planerad'
        : current ? 'Visas nu'
        : receipt?.first_shown_at ? `Visad ${new Date(receipt.first_shown_at).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit' })}`
        : !screenBroadcastDeliveryAvailable ? 'Kvittens otillgänglig'
        : isOnline(screen) ? 'Online · väntar på visning'
        : 'Offline · ej bekräftat';
      const targetRow = document.createElement('div');
      targetRow.className = 'broadcast-delivery-item';
      const name = document.createElement('strong');
      name.textContent = screen.name;
      const state = document.createElement('span');
      state.textContent = status;
      targetRow.append(name, state);
      deliveryItems.append(targetRow);
    });
    delivery.append(deliverySummary, deliveryItems);
    detail.append(delivery);
    row.append(detail);
    if (['admin', 'editor'].includes(currentRole)) {
      const cancel = document.createElement('button');
      cancel.type = 'button';
      cancel.className = 'button ghost small';
      cancel.dataset.broadcastCancel = item.id;
      cancel.textContent = startsLater ? 'Avbryt planerat' : 'Avbryt';
      row.append(cancel);
    }
    return row;
  }));
}

async function loadScreenBroadcastDelivery() {
  const ids = screenBroadcasts.map(item => item.id);
  if (!ids.length) {
    screenBroadcastDelivery = [];
    screenBroadcastDeliveryAvailable = true;
    return;
  }
  const { data, error } = await supabase.rpc('team_broadcast_delivery_summary', { input_broadcast_ids: ids });
  screenBroadcastDeliveryAvailable = !error;
  if (!error) screenBroadcastDelivery = data || [];
}

async function loadScreenBroadcastHistory() {
  const list = $('#screenBroadcastHistory');
  if (!list) return;
  list.textContent = 'Läser utskickshistorik …';
  const now = new Date();
  const since = new Date(now.getTime() - 30 * 86400_000).toISOString();
  const until = now.toISOString();
  const { data, error } = await supabase.from('screen_broadcasts')
    .select('id,slide_id,title,body,kind,starts_at,ends_at,created_at,cancelled_at,screen_broadcast_targets(screen_id,superseded_at)')
    .gte('created_at', since)
    .or(`cancelled_at.not.is.null,ends_at.lt.${until}`)
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) {
    screenBroadcastHistoryLoaded = false;
    list.textContent = `Kunde inte läsa historiken: ${error.message}`;
    return;
  }
  screenBroadcastHistory = data || [];
  if (!screenBroadcastHistory.length) {
    screenBroadcastHistoryDelivery = [];
    screenBroadcastHistoryDeliveryAvailable = true;
    screenBroadcastHistoryLoaded = true;
    renderScreenBroadcastHistory();
    return;
  }
  const receiptResult = await supabase.rpc('team_broadcast_delivery_summary', {
    input_broadcast_ids: screenBroadcastHistory.map(item => item.id)
  });
  screenBroadcastHistoryDeliveryAvailable = !receiptResult.error;
  if (!receiptResult.error) screenBroadcastHistoryDelivery = receiptResult.data || [];
  screenBroadcastHistoryLoaded = true;
  renderScreenBroadcastHistory();
}

function renderScreenBroadcastHistory() {
  const list = $('#screenBroadcastHistory');
  if (!list) return;
  if (!screenBroadcastHistory.length) {
    list.innerHTML = '<span class="screen-groups-empty">Inga avslutade eller avbrutna utskick under de senaste 30 dagarna.</span>';
    return;
  }
  const receiptsByTarget = new Map(screenBroadcastHistoryDelivery.map(receipt => [`${receipt.broadcast_id}:${receipt.screen_id}`, receipt]));
  list.replaceChildren(...screenBroadcastHistory.map(item => {
    const targets = (item.screen_broadcast_targets || []).map(target => ({
      screen: screens.find(screen => screen.id === target.screen_id),
      target,
      receipt: receiptsByTarget.get(`${item.id}:${target.screen_id}`)
    })).filter(entry => entry.screen);
    const shown = targets.filter(({ receipt }) => receipt?.first_shown_at).length;
    const row = document.createElement('article');
    row.className = 'screen-broadcast-row broadcast-history-row';
    const detail = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = item.title;
    const meta = document.createElement('small');
    const kind = item.kind === 'image' ? 'Bild' : item.kind === 'video' ? 'Video' : 'Text';
    const state = item.cancelled_at ? `Avbrutet ${new Date(item.cancelled_at).toLocaleString('sv-SE')}` : 'Avslutat';
    meta.textContent = `${kind} · ${state} · ${shown}/${targets.length} skärmar rapporterade visning · ${new Date(item.starts_at).toLocaleString('sv-SE')}`;
    detail.append(title, meta);
    const delivery = document.createElement('details');
    delivery.className = 'broadcast-delivery';
    const summary = document.createElement('summary');
    summary.textContent = 'Visa historik per skärm';
    const items = document.createElement('div');
    items.className = 'broadcast-delivery-items';
    targets.forEach(({ screen, target, receipt }) => {
      const status = receipt?.first_shown_at
        ? `Visad ${new Date(receipt.first_shown_at).toLocaleString('sv-SE')}${receipt.playback_count > 1 ? ` · ${receipt.playback_count} perioder` : ''}`
        : !screenBroadcastHistoryDeliveryAvailable ? 'Kvittens otillgänglig'
        : target.superseded_at && new Date(target.superseded_at) <= new Date(item.starts_at) ? 'Ersatt före start'
        : 'Ingen visningskvittens';
      const targetRow = document.createElement('div');
      targetRow.className = 'broadcast-delivery-item';
      const name = document.createElement('strong');
      name.textContent = screen.name;
      const stateLabel = document.createElement('span');
      stateLabel.textContent = status;
      targetRow.append(name, stateLabel);
      items.append(targetRow);
    });
    delivery.append(summary, items);
    detail.append(delivery);
    row.append(detail);
    return row;
  }));
}

function updateBroadcastAssetOptions() {
  const select = $('#screenBroadcastForm [name="asset_id"]');
  if (!select) return;
  const selected = select.value;
  const options = mediaLibrary.filter(asset => ['image','video'].includes(asset.kind)
    && asset.source_url
    && (!asset.expires_at || new Date(asset.expires_at).getTime() > Date.now()));
  select.innerHTML = `<option value="">Endast text</option>${options.map(asset => `<option value="${esc(asset.id)}">${asset.kind === 'image' ? 'Bild' : 'Video'} · ${esc(asset.title)}</option>`).join('')}`;
  if (options.some(asset => asset.id === selected)) select.value = selected;
  updateBroadcastTextRequirement();
}

function updateBroadcastTargetCount() {
  const list = $('#broadcastTargetList');
  const count = $('#broadcastTargetCount');
  if (!list || !count) return;
  const selected = list.querySelectorAll('input[name="broadcast_screen_id"]:checked').length;
  const visible = [...list.querySelectorAll('.broadcast-target-option')].filter(label => !label.classList.contains('hidden')).length;
  count.textContent = `${selected} valda · ${visible} av ${list.querySelectorAll('.broadcast-target-option').length} visas`;
}

function updateBroadcastTargetFilter() {
  const list = $('#broadcastTargetList');
  if (!list) return;
  const query = ($('#broadcastTargetSearch')?.value || '').trim().toLocaleLowerCase('sv-SE');
  const locationId = $('#broadcastTargetLocation')?.value || 'all';
  const groupId = $('#broadcastTargetGroup')?.value || 'all';
  list.querySelectorAll('.broadcast-target-option').forEach(label => {
    const nameMatches = !query || label.dataset.screenName.includes(query);
    const locationMatches = locationId === 'all' || label.dataset.locationId === locationId;
    const groupMatches = groupId === 'all' || label.dataset.groupId === groupId;
    label.classList.toggle('hidden', !(nameMatches && locationMatches && groupMatches));
  });
  updateBroadcastTargetCount();
}

function renderBroadcastTargets() {
  const list = $('#broadcastTargetList');
  if (!list) return;
  const searchValue = $('#broadcastTargetSearch')?.value || '';
  const locationValue = $('#broadcastTargetLocation')?.value || 'all';
  const groupValue = $('#broadcastTargetGroup')?.value || 'all';
  const priorSelection = new Set([...list.querySelectorAll('input[name="broadcast_screen_id"]:checked')].map(input => input.value));
  const hasInitialized = list.dataset.initialized === 'true';
  const initialSelection = new Set(selectedLogicalScreens().map(screen => screen.id));
  const logical = logicalScreens();
  const locationSelect = $('#broadcastTargetLocation');
  const groupSelect = $('#broadcastTargetGroup');
  locationSelect.innerHTML = `<option value="all">Alla platser</option>${locations.map(location => `<option value="${esc(location.id)}">${esc(location.name)}</option>`).join('')}<option value="unassigned">Ingen plats</option>`;
  groupSelect.innerHTML = `<option value="all">Alla grupper</option>${screenGroups.map(group => `<option value="${esc(group.id)}">${esc(group.name)}</option>`).join('')}<option value="ungrouped">Ingen grupp</option>`;
  if ([...locationSelect.options].some(option => option.value === locationValue)) locationSelect.value = locationValue;
  if ([...groupSelect.options].some(option => option.value === groupValue)) groupSelect.value = groupValue;
  $('#broadcastTargetSearch').value = searchValue;
  list.replaceChildren();
  if (!logical.length) {
    list.innerHTML = '<div class="broadcast-target-empty">Inga skärmar finns ännu.</div>';
    list.dataset.initialized = 'true';
    updateBroadcastTargetFilter();
    return;
  }
  const groupNames = new Map(screenGroups.map(group => [group.id, group.name]));
  const locationNames = new Map(locations.map(location => [location.id, location.name]));
  logical.forEach(screen => {
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.name = 'broadcast_screen_id';
    checkbox.value = screen.id;
    checkbox.checked = hasInitialized ? priorSelection.has(screen.id) : initialSelection.has(screen.id);
    const label = document.createElement('label');
    label.className = 'broadcast-target-option';
    label.dataset.screenName = String(screen.name || '').toLocaleLowerCase('sv-SE');
    label.dataset.locationId = screen.location_id || 'unassigned';
    label.dataset.groupId = screen.group_id || 'ungrouped';
    label.append(checkbox);
    const copy = document.createElement('span');
    copy.className = 'broadcast-target-copy';
    const name = document.createElement('strong');
    name.textContent = screen.name || 'Namnlös skärm';
    const details = document.createElement('small');
    const metadata = [locationNames.get(screen.location_id), groupNames.get(screen.group_id)].filter(Boolean);
    metadata.push(screen.is_active && screen.activated_at ? 'Aktiv' : 'Inaktiv');
    details.textContent = metadata.join(' · ');
    copy.append(name, details);
    const state = document.createElement('span');
    state.className = `broadcast-target-status ${isOnline(screen) ? 'online' : 'offline'}`;
    state.textContent = isOnline(screen) ? 'Online' : 'Offline';
    label.append(copy, state);
    list.append(label);
  });
  list.dataset.initialized = 'true';
  updateBroadcastTargetFilter();
}

$('#screenBroadcastForm').addEventListener('click', event => {
  const button = event.target.closest('[data-broadcast-target-action]');
  if (!button) return;
  const checkboxes = [...$('#broadcastTargetList').querySelectorAll('input[name="broadcast_screen_id"]')];
  if (button.dataset.broadcastTargetAction === 'all') {
    checkboxes.forEach(input => {
      if (!input.closest('.broadcast-target-option').classList.contains('hidden')) input.checked = true;
    });
  }
  if (button.dataset.broadcastTargetAction === 'none') checkboxes.forEach(input => { input.checked = false; });
  if (button.dataset.broadcastTargetAction === 'selected') {
    const selectedIds = new Set(selectedLogicalScreens().map(screen => screen.id));
    checkboxes.forEach(input => { input.checked = selectedIds.has(input.value); });
  }
  updateBroadcastTargetCount();
});
$('#screenBroadcastForm').addEventListener('change', event => {
  if (event.target.matches('#broadcastTargetLocation, #broadcastTargetGroup')) updateBroadcastTargetFilter();
  if (event.target.matches('input[name="broadcast_screen_id"]')) updateBroadcastTargetCount();
});
$('#screenBroadcastForm').addEventListener('input', event => {
  if (event.target.matches('#broadcastTargetSearch')) updateBroadcastTargetFilter();
});

document.addEventListener('click', event => {
  if (!event.target.closest('[data-open-broadcast]')) return;
  renderBroadcastTargets();
  setWorkspace('broadcasts');
  $('#screenBroadcastComposer').open = true;
  $('#screenBroadcastComposer').scrollIntoView({ behavior: 'smooth', block: 'start' });
});

function updateBroadcastTextRequirement() {
  const form = $('#screenBroadcastForm');
  if (!form) return;
  const hasAsset = Boolean(form.elements.asset_id.value);
  form.elements.body.required = !hasAsset;
  form.elements.body.placeholder = hasAsset ? 'Valfri textbeskrivning' : 'Meddelande till skärmarna';
}

function supportsScheduledBroadcasts(playerVersion) {
  const [major, minor] = String(playerVersion || '').split('.').map(Number);
  return Number.isFinite(major) && Number.isFinite(minor) && (major > 1 || (major === 1 && minor >= 19));
}

async function sendScreenBroadcast(event) {
  event.preventDefault();
  if (!['admin', 'editor'].includes(currentRole)) return;
  const form = event.currentTarget;
  const selectedIds = new Set([...form.querySelectorAll('input[name="broadcast_screen_id"]:checked')].map(input => input.value));
  const selected = logicalScreens().filter(screen => selectedIds.has(screen.id));
  const active = selected.filter(screen => screen.is_active && screen.activated_at);
  if (!selected.length) return toast('Välj minst en skärm som mottagare.', true);
  if (!active.length) return toast('Välj minst en parkopplad, aktiv skärm.', true);
  if (active.length > 100) return toast('Ett utskick kan gå till högst 100 skärmar åt gången.', true);
  const title = form.elements.title.value.trim();
  const body = form.elements.body.value.trim();
  const assetId = form.elements.asset_id.value || null;
  const duration = Number(form.elements.duration.value);
  const displayDuration = Number(form.elements.duration_seconds.value);
  const startAt = form.elements.start_at.value ? new Date(form.elements.start_at.value) : new Date();
  if (!title || (!body && !assetId)) return toast('Ange en rubrik och ett meddelande eller välj media.', true);
  if (!Number.isInteger(duration) || duration < 1 || duration > 1440) return toast('Välj en giltig visningstid.', true);
  if (!Number.isInteger(displayDuration) || displayDuration < 5 || displayDuration > 600) return toast('Välj en giltig visningstid för bild/video.', true);
  if (Number.isNaN(startAt.getTime()) || startAt < new Date(Date.now() - 120_000) || startAt > new Date(Date.now() + 90 * 86400_000)) return toast('Starttiden måste vara nu eller inom 90 dagar.', true);
  const skipped = selected.length - active.length;
  const skippedLabel = skipped ? ` ${skipped} pausade eller opairade skärmar hoppas över.` : '';
  const scheduled = startAt.getTime() > Date.now() + 5_000;
  const oldPlayers = scheduled ? active.filter(screen => !supportsScheduledBroadcasts(screen.player_version)) : [];
  const startLabel = scheduled ? `Starta ${startAt.toLocaleString('sv-SE')}` : 'Skicka direkt';
  const compatibilityNote = oldPlayers.length ? ` ${oldPlayers.length} skärmar med äldre spelare behöver vara online vid start.` : '';
  if (!confirm(`${startLabel}: ${assetId ? 'visa valt media' : 'visa meddelandet'} ”${title}” på ${active.length} aktiva skärmar i ${duration} minuter?${compatibilityNote}${skippedLabel}`)) return;
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    const { error } = await supabase.rpc('create_screen_broadcast', {
      input_screen_ids: active.map(screen => screen.id),
      input_title: title,
      input_body: body,
      input_duration_minutes: duration,
      input_start_at: startAt.toISOString(),
      input_asset_id: assetId,
      input_duration_seconds: displayDuration
    });
    if (error) return toast(error.message, true);
    form.reset();
    form.elements.duration.value = '10';
    form.elements.duration_seconds.value = '60';
    updateBroadcastTextRequirement();
    updateBroadcastTargetFilter();
    $('#screenBroadcastComposer').open = false;
    toast(scheduled
      ? `Utskicket är planerat till ${startAt.toLocaleString('sv-SE')} på ${active.length} skärmar.`
      : `Utskicket startade på ${active.length} skärmar och avslutas automatiskt efter ${duration} minuter.`);
    await loadScreens();
  } finally {
    button.disabled = false;
  }
}

async function cancelScreenBroadcastFromList(event) {
  const button = event.target.closest('[data-broadcast-cancel]');
  if (!button || !['admin', 'editor'].includes(currentRole)) return;
  const broadcast = screenBroadcasts.find(item => item.id === button.dataset.broadcastCancel);
  if (!broadcast) return;
  const startsLater = new Date(broadcast.starts_at).getTime() > Date.now();
  if (!confirm(startsLater
    ? `Avbryt det planerade utskicket ”${broadcast.title}”? Skärmar som redan har laddat ned schemat och är offline kan fortfarande visa det tills de ansluter igen eller den ursprungliga sluttiden nås.`
    : `Avbryt ”${broadcast.title}” nu? Anslutna skärmar återgår vid nästa synk. Offline-skärmar kan fortsätta visa den cachade versionen tills de ansluter igen eller den ursprungliga sluttiden nås.`)) return;
  button.disabled = true;
  const { data: targetCount, error } = await supabase.rpc('cancel_screen_broadcast', { input_broadcast_id: broadcast.id });
  if (error) {
    button.disabled = false;
    return toast(error.message, true);
  }
  toast(`${startsLater ? 'Det planerade utskicket avbröts' : 'Utskicket avbröts'}. Synk köad för ${targetCount} skärmar.`);
  await loadScreens();
}

async function refreshScreenStatus() {
  if (!currentUser) return;
  const [
    { data, error },
    { data: commandData, error: commandError },
    { data: broadcastData, error: broadcastError }
  ] = await Promise.all([
    supabase.from('screens').select('id,last_seen_at,preview_updated_at,current_title,current_body,current_kind,current_source_url,current_slide_id,forced_slide_id,player_version,device_model,android_version,display_size,network_type,device_updated_at,applied_revision,applied_revision_at'),
    supabase.from('screen_commands').select('id,screen_id,command,status,created_at,completed_at,error_message').order('created_at', { ascending: false }).limit(100),
    supabase.from('screen_broadcasts').select('id,slide_id,title,body,kind,source_url,duration_seconds,starts_at,ends_at,created_at,cancelled_at,screen_broadcast_targets(screen_id,superseded_at)').is('cancelled_at', null).gt('ends_at', new Date().toISOString()).order('starts_at', { ascending: true }).limit(100)
  ]);
  if (error || commandError) return;
  if (!broadcastError) screenBroadcasts = broadcastData || [];
  await loadScreenBroadcastDelivery();
  screenCommands = commandData || [];
  const liveWithPreviews = await Promise.all((data || []).map(async screen => {
    if (!screen.preview_updated_at || !isOnline(screen)) return screen;
    const previous = screens.find(item => item.id === screen.id);
    if (previous?.preview_updated_at === screen.preview_updated_at
      && (previous.preview_url_expires_at || 0) > Date.now() + 10_000) {
      return { ...screen, preview_url: previous.preview_url || null, preview_url_expires_at: previous.preview_url_expires_at };
    }
    const path = `screens/${screen.id}/current.jpg`;
    const { data: preview } = await supabase.storage.from('signage-previews').createSignedUrl(path, 300);
    return {
      ...screen,
      preview_url: preview?.signedUrl || null,
      preview_url_expires_at: Date.now() + (preview?.signedUrl ? 300_000 : 30_000)
    };
  }));
  const liveById = new Map(liveWithPreviews.map(item => [item.id, item]));
  screens = screens.map(screen => ({ ...screen, ...(liveById.get(screen.id) || {}) }));
  updateScreenSummary();
  renderScreenBroadcasts();
  for (const screen of screens) {
    const online = isOnline(screen);
    const cards = screenDetailContent.querySelectorAll(`[data-screen-id="${CSS.escape(screen.id)}"]`);
    cards.forEach(card => {
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
    const diagnostics = card.querySelector('.device-diagnostics');
    if (diagnostics) diagnostics.innerHTML = renderDeviceDiagnostics(screen);
    const publicationState = card.querySelector('.screen-publication-state');
    if (publicationState) {
      const publication = screenPublications.find(item => item.screen_id === screen.id);
      publicationState.textContent = `Senast publicerad ${publication ? `version ${publication.revision} · ${new Date(publication.published_at).toLocaleString('sv-SE')}` : 'inte ännu'} · ${publicationDeliverySummary(screen, publication)} · ändringar ligger som utkast tills du publicerar.`;
    }
    const forceButton = card.querySelector('.return-playlist');
    if (forceButton) forceButton.classList.toggle('hidden', !screen.forced_slide_id);
    const commandStatus = card.querySelector('[data-command-status]');
    if (commandStatus) commandStatus.textContent = formatCommandStatus(screenCommands.find(command => command.screen_id === screen.id));
    const previewButton = card.querySelector('[data-player-command="capture_preview"]');
    if (previewButton) previewButton.disabled = !online;
    card.querySelectorAll('[data-slide-action="show-now"]').forEach(button => {
      button.classList.toggle('selected', button.dataset.id === screen.forced_slide_id);
      button.textContent = button.dataset.id === screen.forced_slide_id ? 'Visas nu' : 'Visa nu';
    });
    card.querySelectorAll('.channel-show-now').forEach(button => {
      button.classList.toggle('selected', button.dataset.id === screen.forced_slide_id);
      button.textContent = button.dataset.id === screen.forced_slide_id ? 'Visas nu' : 'Visa nu';
    });
    });
  }
  applyScreenFilters();
}

function kindLabel(kind) {
  return ({ text: 'Textmeddelande', image: 'Bild', video: 'Video', clock: 'Klocka & datum', feed: 'JSON-feed', web: 'Webbsida / live dashboard', sleep: 'Utanför öppettider', paused: 'Pausad' })[kind] || kind || '—';
}

function openDraftPreview(screen, slides, channelSlides, assignedChannels, zoneSlides) {
  const dialog = $('#draftPreviewDialog');
  draftPreviewScreen = screen;
  draftPreviewBaseSlides = slides;
  draftPreviewChannelSlides = channelSlides;
  draftPreviewZoneSlides = zoneSlides;
  draftPreviewScreenSchedules = assignedChannels;
  draftPreviewAt = new Date();
  $('#draftPreviewAt').value = localDateTimeInput(draftPreviewAt.toISOString());
  refreshDraftPreviewForTime();
  draftPreviewIndex = 0;
  $('#draftPreviewTitle').textContent = screen.name;
  if (!dialog.open) dialog.showModal();
}

function previewWeekday(date) {
  return date.getDay() === 0 ? 7 : date.getDay();
}

function isPreviewScheduleActive(schedule, date) {
  if (schedule.active_from && date.getTime() < new Date(schedule.active_from).getTime()) return false;
  if (schedule.active_until && date.getTime() >= new Date(schedule.active_until).getTime()) return false;
  const selectedDays = (schedule.weekdays || []).map(Number);
  const weekday = previewWeekday(date);
  const isSelected = day => selectedDays.length === 0 || selectedDays.includes(day);
  const start = String(schedule.daily_start_time || '').slice(0, 5);
  const end = String(schedule.daily_end_time || '').slice(0, 5);
  if (!start || !end) return isSelected(weekday);
  const time = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
  if (start <= end) return isSelected(weekday) && time >= start && time < end;
  if (time >= start) return isSelected(weekday);
  if (time < end) return isSelected(weekday === 1 ? 7 : weekday - 1);
  return false;
}

function isPreviewItemActive(item, date) {
  if (item.is_active === false) return false;
  if (item.expires_at && date.getTime() >= new Date(item.expires_at).getTime()) return false;
  return isPreviewScheduleActive(item, date);
}

function isWithinPreviewOperatingHours(screen, date) {
  const selectedDays = (screen.operating_weekdays || []).map(Number);
  const weekday = previewWeekday(date);
  const isSelected = day => selectedDays.length === 0 || selectedDays.includes(day);
  const start = String(screen.operating_start_time || '').slice(0, 5);
  const end = String(screen.operating_end_time || '').slice(0, 5);
  if (!start && !end) return isSelected(weekday);
  if (!start || !end) return true;
  const time = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
  if (start === end) return isSelected(weekday);
  if (start < end) return isSelected(weekday) && time >= start && time < end;
  if (time >= start) return isSelected(weekday);
  if (time < end) return isSelected(weekday === 1 ? 7 : weekday - 1);
  return false;
}

function synchronizedPreviewItem(items, date) {
  if (!items.length) return null;
  const durations = items.map(item => Math.max(5, Math.min(600, Number(item.duration_seconds) || 15)) * 1000);
  const cycleDuration = durations.reduce((total, duration) => total + duration, 0);
  let offset = ((date.getTime() % cycleDuration) + cycleDuration) % cycleDuration;
  for (let index = 0; index < items.length; index++) {
    if (offset < durations[index]) return items[index];
    offset -= durations[index];
  }
  return items.at(-1) || null;
}

function refreshDraftPreviewForTime() {
  const input = $('#draftPreviewAt');
  const selectedTime = input.value ? new Date(input.value) : null;
  if (!selectedTime || Number.isNaN(selectedTime.getTime())) {
    return toast('Välj en giltig tid för förhandsvisningen.', true);
  }
  draftPreviewAt = selectedTime;
  draftPreviewIndex = 0;
  draftPreviewZoneItem = null;
  draftPreviewZoneItemCount = 0;
  draftPreviewZonePosition = 0;
  draftPreviewZoneText = '';
  if (!draftPreviewScreen?.is_active) {
    draftPreviewItems = [];
    draftPreviewEmptyMessage = 'Skärmen är pausad. Utkastet kan granskas, men spelaren visar inget innehåll förrän skärmen aktiveras.';
    renderDraftPreviewItem();
    return;
  }
  if (!isWithinPreviewOperatingHours(draftPreviewScreen, draftPreviewAt)) {
    draftPreviewItems = [];
    draftPreviewEmptyMessage = 'Skärmen ska visa svart utanför sina öppettider.';
    renderDraftPreviewItem();
    return;
  }

  const activeChannelItems = [];
  draftPreviewScreenSchedules.filter(schedule => isPreviewScheduleActive(schedule, draftPreviewAt)).forEach(schedule => {
    const channel = channels.find(item => item.id === schedule.channel_id);
    channelPlaylists.filter(item => item.channel_id === schedule.channel_id && isPreviewScheduleActive(item, draftPreviewAt))
      .forEach(membership => {
        const playlist = playlists.find(item => item.id === membership.playlist_id);
        draftPreviewChannelSlides.filter(item => item.playlist_id === membership.playlist_id && isPreviewItemActive(item, draftPreviewAt))
          .forEach(item => activeChannelItems.push({
            ...item,
            channelId: schedule.channel_id,
            channelPriority: Number(schedule.priority ?? 100),
            playlistPriority: Number(membership.priority ?? 100),
            playlistOrder: Number(membership.sort_order ?? 0),
            previewSource: `Kanal · ${channel?.name || 'Okänd kanal'} · ${playlist?.name || 'spellista'}`
          }));
      });
  });

  if (activeChannelItems.length) {
    activeChannelItems.sort((left, right) => left.channelPriority - right.channelPriority
      || left.playlistPriority - right.playlistPriority
      || left.playlistOrder - right.playlistOrder
      || Number(left.sort_order || 0) - Number(right.sort_order || 0)
      || new Date(left.created_at || 0) - new Date(right.created_at || 0));
    const selectedChannelId = activeChannelItems[0].channelId;
    draftPreviewItems = activeChannelItems.filter(item => item.channelId === selectedChannelId);
  } else {
    draftPreviewItems = draftPreviewBaseSlides
      .filter(item => isPreviewItemActive(item, draftPreviewAt))
      .map(item => ({ ...item, previewSource: 'Skärmens grundspellista' }));
  }
  if (draftPreviewScreen.playback_mode === 'random') {
    for (let i = draftPreviewItems.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [draftPreviewItems[i], draftPreviewItems[j]] = [draftPreviewItems[j], draftPreviewItems[i]];
    }
  }
  const forcedCastActive = draftPreviewScreen.forced_slide_id
    && (!draftPreviewScreen.forced_until || draftPreviewAt.getTime() < new Date(draftPreviewScreen.forced_until).getTime());
  if (draftPreviewScreen.layout_type !== 'single' && !forcedCastActive) {
    const zoneSlides = draftPreviewZoneSlides.filter(item => isPreviewItemActive(item, draftPreviewAt))
      .sort((left, right) => Number(left.sort_order || 0) - Number(right.sort_order || 0)
        || new Date(left.created_at || 0) - new Date(right.created_at || 0));
    draftPreviewZoneItemCount = zoneSlides.length;
    draftPreviewZoneItem = draftPreviewScreen.playback_mode === 'sync'
      ? synchronizedPreviewItem(zoneSlides, draftPreviewAt)
      : draftPreviewScreen.playback_mode === 'random'
        ? zoneSlides[Math.floor(Math.random() * zoneSlides.length)] || null
        : zoneSlides[0] || null;
    draftPreviewZonePosition = Math.max(0, zoneSlides.findIndex(item => item.id === draftPreviewZoneItem?.id));
    if (!draftPreviewZoneItem) draftPreviewZoneText = String(draftPreviewScreen.layout_text || '').trim();
  }
  draftPreviewEmptyMessage = 'Inget utkast är schemalagt att visas vid den valda tiden.';
  renderDraftPreviewItem();
}

function renderDraftPreviewItem() {
  const stage = $('[data-preview-stage]');
  const position = $('[data-preview-position]');
  const previous = $('[data-preview-prev]');
  const next = $('[data-preview-next]');
  const refresh = $('[data-preview-refresh]');
  const previewTimeLabel = new Intl.DateTimeFormat('sv-SE', { dateStyle: 'short', timeStyle: 'short' }).format(draftPreviewAt);
  clearInterval(draftPreviewRefreshTimer);
  draftPreviewRefreshTimer = null;
  draftPreviewAbortControllers.forEach(controller => controller.abort());
  draftPreviewAbortControllers.clear();
  const generation = ++draftPreviewGeneration;
  const item = draftPreviewItems[draftPreviewIndex];
  stage.replaceChildren();
  if (!item) {
    const empty = document.createElement('div');
    empty.className = 'draft-preview-empty draft-preview-primary';
    empty.textContent = draftPreviewEmptyMessage;
    const composition = createDraftPreviewComposition(empty, generation);
    stage.append(composition);
    position.textContent = `0 objekt · ${previewTimeLabel}`;
    previous.disabled = true;
    next.disabled = true;
    refresh.disabled = !['feed','web'].includes(draftPreviewZoneItem?.kind);
    return;
  }

  const frame = document.createElement('article');
  frame.className = `draft-preview-frame preview-${item.kind || 'unknown'}`;
  frame.classList.add('draft-preview-primary');
  const badge = document.createElement('span');
  badge.className = 'draft-preview-source';
  badge.textContent = item.previewSource;
  frame.append(badge);
  if (item.kind === 'image' && /^https?:\/\//i.test(item.source_url || '')) {
    const media = document.createElement('img');
    media.src = item.source_url;
    media.alt = item.title || 'Förhandsvisad bild';
    frame.append(media);
  } else if (item.kind === 'video' && /^https?:\/\//i.test(item.source_url || '')) {
    const media = document.createElement('video');
    media.src = item.source_url;
    media.controls = true;
    media.playsInline = true;
    frame.append(media);
  } else if (item.kind === 'web') {
    const url = safePreviewUrl(item.source_url);
    if (!url) {
      addPreviewMessage(frame, 'Webbsidan saknar en giltig HTTP- eller HTTPS-adress.');
    } else {
      const iframe = document.createElement('iframe');
      iframe.className = 'draft-preview-web';
      iframe.src = url.href;
      iframe.title = item.title || 'Live-dashboard';
      iframe.referrerPolicy = 'no-referrer';
      iframe.loading = 'eager';
      iframe.setAttribute('sandbox', url.origin === location.origin
        ? 'allow-scripts allow-forms allow-popups'
        : 'allow-scripts allow-forms allow-popups allow-same-origin');
      iframe.addEventListener('load', () => {
        if (generation !== draftPreviewGeneration) return;
        const status = frame.querySelector('[data-preview-live-status]');
        if (status) status.textContent = 'Webbsidan har laddats. Om den blockerar inbäddning kan du öppna källan separat.';
      }, { once: true });
      frame.append(iframe);
      const open = document.createElement('a');
      open.className = 'draft-preview-open-link';
      open.href = url.href;
      open.target = '_blank';
      open.rel = 'noopener noreferrer';
      open.textContent = 'Öppna i ny flik ↗';
      frame.append(open);
      addPreviewMessage(frame, 'Laddar live-webbsida…');
    }
  } else if (item.kind === 'feed') {
    addPreviewMessage(frame, 'Hämtar aktuella data från feeden…');
    startDraftFeedPreview(item, frame, generation);
    const intervalSeconds = Math.max(10, Math.min(3600, Number(item.refresh_interval_seconds) || 30));
    draftPreviewRefreshTimer = setInterval(() => {
      if (generation === draftPreviewGeneration && $('#draftPreviewDialog').open) {
        startDraftFeedPreview(item, frame, generation);
      }
    }, intervalSeconds * 1000);
  } else {
    const content = document.createElement('div');
    content.className = 'draft-preview-copy';
    const title = document.createElement('h3');
    title.textContent = item.title || kindLabel(item.kind);
    content.append(title);
    const body = document.createElement('p');
    if (item.kind === 'text') body.textContent = item.body || '';
    else if (item.kind === 'clock') body.textContent = `${item.body || ''}${item.body ? ' · ' : ''}${new Intl.DateTimeFormat('sv-SE', { dateStyle: 'full', timeStyle: 'short' }).format(draftPreviewAt)}`;
    else body.textContent = item.body || 'Förhandsvisning av utkast';
    content.append(body);
    frame.append(content);
  }
  const caption = document.createElement('span');
  caption.className = 'draft-preview-caption';
  caption.textContent = `${kindLabel(item.kind)} · ${Number(item.duration_seconds) || 0} sekunder`;
  frame.append(caption);
  stage.append(createDraftPreviewComposition(frame, generation));
  position.textContent = `${draftPreviewIndex + 1} av ${draftPreviewItems.length}${draftPreviewScreen?.playback_mode === 'random' ? ' · slumpad ordning' : ''} · ${previewTimeLabel}`;
  previous.disabled = draftPreviewIndex === 0;
  next.disabled = draftPreviewIndex >= draftPreviewItems.length - 1;
  refresh.disabled = !['feed','web'].includes(item.kind) && !['feed','web'].includes(draftPreviewZoneItem?.kind);
}

function createDraftPreviewComposition(primary, generation) {
  const layout = draftPreviewScreen?.layout_type || 'single';
  const showZone = layout !== 'single' && Boolean(draftPreviewZoneItem || draftPreviewZoneText);
  const composition = document.createElement('div');
  composition.className = `draft-preview-composition layout-${showZone ? layout : 'single'}`;
  const splitPercent = Math.min(85, Math.max(55, Number(draftPreviewScreen?.layout_split_percent) || 72));
  const tickerPercent = Math.min(25, Math.max(10, Number(draftPreviewScreen?.layout_ticker_percent) || 16));
  if (showZone && layout === 'side_panel') composition.style.gridTemplateColumns = `minmax(0,${splitPercent}fr) minmax(0,${100 - splitPercent}fr)`;
  if (showZone && layout === 'bottom_ticker') composition.style.gridTemplateRows = `minmax(0,${100 - tickerPercent}fr) minmax(0,${tickerPercent}fr)`;
  composition.append(primary);
  if (!showZone) return composition;

  const zone = document.createElement('aside');
  zone.className = 'draft-preview-zone';
  const zoneLabel = document.createElement('span');
  zoneLabel.className = 'draft-preview-zone-label';
  if (draftPreviewZoneItem) {
    zoneLabel.textContent = `Zon 2 · ${draftPreviewZoneItem.title || kindLabel(draftPreviewZoneItem.kind)} · ${draftPreviewZonePosition + 1}/${draftPreviewZoneItemCount}`;
    zone.append(zoneLabel);
    if (draftPreviewZoneItem.kind === 'image' && /^https?:\/\//i.test(draftPreviewZoneItem.source_url || '')) {
      const image = document.createElement('img');
      image.src = draftPreviewZoneItem.source_url;
      image.alt = draftPreviewZoneItem.title || 'Förhandsvisning av zonbild';
      image.addEventListener('error', () => addPreviewMessage(zone, 'Webbläsaren kunde inte läsa zonbilden.'), { once: true });
      zone.append(image);
    } else if (draftPreviewZoneItem.kind === 'video' && /^https?:\/\//i.test(draftPreviewZoneItem.source_url || '')) {
      const video = document.createElement('video');
      video.src = draftPreviewZoneItem.source_url;
      video.controls = true;
      video.playsInline = true;
      video.preload = 'metadata';
      zone.append(video);
    } else if (draftPreviewZoneItem.kind === 'web') {
      const url = safePreviewUrl(draftPreviewZoneItem.source_url);
      if (!url) addPreviewMessage(zone, 'Zonens webbadress är ogiltig.');
      else {
        const frame = document.createElement('iframe');
        frame.className = 'draft-preview-zone-web';
        frame.src = url.href;
        frame.title = draftPreviewZoneItem.title || 'Webbinnehåll i zon';
        frame.referrerPolicy = 'no-referrer';
        frame.setAttribute('sandbox', 'allow-scripts allow-forms allow-popups allow-same-origin');
        zone.append(frame);
      }
    } else if (draftPreviewZoneItem.kind === 'feed') {
      addPreviewMessage(zone, 'Hämtar live-data till zonen…');
      startDraftFeedPreview(draftPreviewZoneItem, zone, generation);
    } else {
      const copy = document.createElement('div');
      copy.className = 'draft-preview-zone-copy';
      if (draftPreviewZoneItem.kind === 'clock') {
        copy.textContent = `${new Intl.DateTimeFormat('sv-SE', { timeStyle: 'short' }).format(draftPreviewAt)}\n${draftPreviewZoneItem.title || ''}`;
      } else copy.textContent = draftPreviewZoneItem.body || draftPreviewZoneItem.title || '';
      zone.append(copy);
    }
  } else {
    zoneLabel.textContent = 'Zon 2 · Text';
    zone.append(zoneLabel);
    const copy = document.createElement('div');
    copy.className = 'draft-preview-zone-copy';
    copy.textContent = draftPreviewZoneText;
    zone.append(copy);
  }
  composition.append(zone);
  return composition;
}

function safePreviewUrl(value) {
  try {
    const url = new URL(String(value || ''));
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || /#token=/i.test(url.hash)) return null;
    return url;
  } catch {
    return null;
  }
}

function addPreviewMessage(frame, message, error = false) {
  const status = document.createElement('div');
  status.className = `draft-preview-live-status${error ? ' error' : ''}`;
  status.dataset.previewLiveStatus = '';
  status.setAttribute('role', 'status');
  status.setAttribute('aria-live', 'polite');
  status.textContent = message;
  frame.append(status);
  return status;
}

function startDraftFeedPreview(item, frame, generation) {
  if (frame.dataset.feedPreviewLoading === 'true') return;
  const controller = new AbortController();
  frame.dataset.feedPreviewLoading = 'true';
  draftPreviewAbortControllers.add(controller);
  loadDraftFeedPreview(item, frame, generation, controller.signal, controller)
    .catch(error => {
      if (generation !== draftPreviewGeneration) return;
      const status = frame.querySelector('[data-preview-live-status]') || addPreviewMessage(frame, '');
      status.classList.add('error');
      status.textContent = error?.message || 'Kunde inte hämta live-data.';
    })
    .finally(() => {
      draftPreviewAbortControllers.delete(controller);
      frame.dataset.feedPreviewLoading = 'false';
    });
}

async function loadDraftFeedPreview(item, frame, generation, signal, controller) {
  let payload;
  let fetchedAt;
  if (item.integration_id) {
    const { data, error } = await supabase.functions.invoke('preview-signage-feed', {
      body: { integration_id: item.integration_id }
    });
    if (generation !== draftPreviewGeneration) return;
    if (error) {
      const status = frame.querySelector('[data-preview-live-status]');
      if (status) { status.classList.add('error'); status.textContent = error.message || 'Kunde inte hämta live-data från Pulse.'; }
      return;
    }
    payload = data?.payload;
    fetchedAt = data?.fetched_at;
  } else {
    const url = safePreviewUrl(item.source_url);
    if (!url) {
      const status = frame.querySelector('[data-preview-live-status]');
      if (status) { status.classList.add('error'); status.textContent = 'Feeden saknar en giltig HTTP- eller HTTPS-adress.'; }
      return;
    }
    let timeout;
    try {
      timeout = setTimeout(() => {
        if (generation === draftPreviewGeneration) controller.abort();
      }, 10_000);
      const response = await fetch(url.href, {
        cache: 'no-store',
        credentials: 'omit',
        headers: { Accept: 'application/json', 'Cache-Control': 'no-cache' },
        signal
      });
      if (!response.ok) throw new Error(`Källan svarade med HTTP ${response.status}.`);
      if (Number(response.headers.get('content-length') || 0) > 1_500_000) throw new Error('Feed-svaret är för stort för en förhandsvisning.');
      payload = await response.json();
      fetchedAt = new Date().toISOString();
    } catch (error) {
      if (generation !== draftPreviewGeneration) return;
      const status = frame.querySelector('[data-preview-live-status]');
      if (status) {
        status.classList.add('error');
        status.textContent = error instanceof DOMException && error.name === 'AbortError'
          ? 'Feeden svarade inte inom tio sekunder.'
          : error instanceof TypeError
          ? 'Webbläsaren kunde inte läsa feeden. Källan måste tillåta CORS; öppna den på TV:n för att verifiera faktisk åtkomst.'
          : error.message || 'Kunde inte läsa live-data.';
      }
      return;
    } finally {
      clearTimeout(timeout);
    }
  }
  if (generation !== draftPreviewGeneration) return;
  renderLiveFeedPreview(item, payload, fetchedAt, frame);
}

function renderLiveFeedPreview(item, payload, fetchedAt, frame) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    const status = frame.querySelector('[data-preview-live-status]');
    if (status) { status.classList.add('error'); status.textContent = 'Feeden returnerade inte ett JSON-objekt.'; }
    return;
  }
  frame.querySelector('[data-preview-live-status]')?.remove();
  frame.querySelector('.draft-preview-dashboard')?.remove();
  const dashboard = document.createElement('div');
  dashboard.className = 'draft-preview-dashboard';
  const header = document.createElement('header');
  const title = document.createElement('strong');
  title.textContent = String(payload.title || item.title || 'Live-dashboard');
  const subtitle = document.createElement('span');
  subtitle.textContent = String(payload.subtitle || payload.message || '');
  header.append(title, subtitle);
  const timestamp = payload.updated_at || payload.generated_at || payload.timestamp || fetchedAt;
  const freshness = document.createElement('small');
  const parsed = timestamp ? new Date(timestamp) : null;
  freshness.textContent = parsed && !Number.isNaN(parsed.getTime())
    ? `LIVE · data uppdaterad ${parsed.toLocaleString('sv-SE')}`
    : `LIVE · hämtad ${new Date(fetchedAt || Date.now()).toLocaleTimeString('sv-SE')}`;
  header.append(freshness);
  dashboard.append(header);

  const metrics = Array.isArray(payload.metrics) ? payload.metrics.slice(0, 6) : [];
  if (!metrics.length && payload.global && typeof payload.global === 'object' && !Array.isArray(payload.global)) {
    for (const [label, value] of Object.entries(payload.global)) {
      if (value == null || typeof value === 'object') continue;
      metrics.push({ label, value });
      if (metrics.length === 6) break;
    }
  }
  if (metrics.length) {
    const grid = document.createElement('div');
    grid.className = 'draft-preview-metrics';
    metrics.forEach(metric => {
      if (!metric || typeof metric !== 'object') return;
      const card = document.createElement('article');
      const label = document.createElement('small');
      label.textContent = String(metric.label || metric.title || metric.name || 'MÄTVÄRDE').toLocaleUpperCase('sv-SE');
      const value = document.createElement('strong');
      value.textContent = previewValue(metric.value ?? metric.text ?? '–');
      const detail = document.createElement('span');
      detail.textContent = String(metric.detail || metric.trend || metric.subtitle || '');
      card.append(label, value, detail);
      grid.append(card);
    });
    dashboard.append(grid);
  }

  const listKey = ['items','alerts','rows','organizations','regions'].find(key => Array.isArray(payload[key]) && payload[key].length);
  const rows = listKey ? payload[listKey].slice(0, 10) : [];
  if (rows.length) {
    const list = document.createElement('div');
    list.className = 'draft-preview-live-list';
    const listTitle = document.createElement('strong');
    listTitle.textContent = String(payload.items_title || payload.section_title || listKey).toLocaleUpperCase('sv-SE');
    list.append(listTitle);
    rows.forEach((row, index) => {
      const line = document.createElement('article');
      const name = document.createElement('strong');
      name.textContent = String(row?.title || row?.name || row?.label || `Post ${index + 1}`);
      const detail = document.createElement('span');
      detail.textContent = String(row?.subtitle || row?.description || row?.detail || row?.organization_name || '');
      const status = document.createElement('small');
      status.textContent = String(row?.status || row?.severity || row?.value || '');
      line.append(name, detail, status);
      list.append(line);
    });
    dashboard.append(list);
  }

  if (!metrics.length && !rows.length) {
    const message = document.createElement('p');
    message.className = 'draft-preview-live-empty';
    message.textContent = String(payload.message || payload.value || payload.text || 'Live-data kom fram. Feeden saknar fält som kan visas som mätvärden eller lista.');
    dashboard.append(message);
  }
  frame.append(dashboard);
}

function previewValue(value) {
  if (typeof value === 'string') return value;
  if (value == null) return '–';
  try { return JSON.stringify(value); } catch { return String(value); }
}

$('#draftPreviewDialog').querySelector('[data-preview-close]').addEventListener('click', () => $('#draftPreviewDialog').close());
$('#draftPreviewTimeForm').addEventListener('submit', event => {
  event.preventDefault();
  refreshDraftPreviewForTime();
});
$('[data-preview-prev]').addEventListener('click', () => { draftPreviewIndex = Math.max(0, draftPreviewIndex - 1); renderDraftPreviewItem(); });
$('[data-preview-next]').addEventListener('click', () => { draftPreviewIndex = Math.min(draftPreviewItems.length - 1, draftPreviewIndex + 1); renderDraftPreviewItem(); });
$('[data-preview-refresh]').addEventListener('click', renderDraftPreviewItem);
$('#draftPreviewDialog').addEventListener('close', () => {
  draftPreviewGeneration++;
  clearInterval(draftPreviewRefreshTimer);
  draftPreviewRefreshTimer = null;
  draftPreviewAbortControllers.forEach(controller => controller.abort());
  draftPreviewAbortControllers.clear();
  $('[data-preview-stage]').replaceChildren();
});

function formatCommandStatus(command) {
  if (!command) return 'Inga fjärrkommandon ännu.';
  const time = command.completed_at || command.created_at;
  const clock = time ? new Date(time).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit' }) : '';
  if (command.status === 'pending') return `Väntar på TV:n · ${clock}`;
  if (command.status === 'running') return `TV:n utför kommandot · ${clock}`;
  if (command.status === 'failed') return `Misslyckades · ${command.error_message || 'okänt fel'} · ${clock}`;
  if (command.command === 'capture_preview') return `Livebild uppdaterad · ${clock}`;
  const label = command.command === 'restart_player' ? 'Omstart kvitterad' : 'Synk kvitterad';
  return `${label} · ${clock}`;
}

function updateCurrentPreview(container, screen, online) {
  if (!container) return;
  const key = online ? `${screen.preview_updated_at || ''}|${screen.preview_url || ''}|${screen.current_kind || ''}|${screen.current_title || ''}|${screen.current_body || ''}|${screen.current_source_url || ''}` : 'offline';
  if (container.dataset.previewKey === key) return;
  container.dataset.previewKey = key;
  container.replaceChildren();
  if (!online) {
    container.textContent = 'Ingen signal från spelaren';
    return;
  }
  if (screen.preview_url) {
    const image = document.createElement('img');
    image.src = screen.preview_url;
    image.alt = `Livebild från ${screen.name || 'skärmen'}`;
    image.onerror = () => {
      if (container.dataset.previewKey === key) renderContentPreview(container, screen);
    };
    container.append(image);
    return;
  }
  renderContentPreview(container, screen);
}

function renderDeviceDiagnostics(screen) {
  if (!screen.device_updated_at) return '<strong>Enhetsdiagnostik</strong><span>Väntar på att spelaren rapporterar enhetsinfo.</span>';
  const reported = new Date(screen.device_updated_at).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit' });
  const details = [screen.device_model, screen.android_version ? `Android ${screen.android_version}` : '', screen.display_size, screen.network_type].filter(Boolean).map(esc).join(' · ');
  return `<strong>${esc(screen.player_version ? `Spelare v${screen.player_version}` : 'Spelarversion okänd')}</strong><span>${details || 'Enhetsinformation saknas'}</span><small>Rapporterad ${esc(reported)}</small>`;
}

function publicationDeliverySummary(screen, publication) {
  if (!publication) return 'Ingen version att kvittera ännu';
  if (screen.applied_revision == null) return 'TV:n har ännu inte kvitterat en version';
  const applied = Number(screen.applied_revision);
  const current = Number(publication.revision);
  const when = screen.applied_revision_at
    ? new Date(screen.applied_revision_at).toLocaleString('sv-SE')
    : 'tid saknas';
  return applied < current
    ? `TV:n har kvitterat version ${applied} ${when}; väntar på version ${current}`
    : `TV:n har kvitterat version ${applied} ${when}`;
}

async function downloadScreenSupportBundle(screen, button) {
  button.disabled = true;
  try {
    const [{ data: healthEvents, error: healthError }, { data: feedStatuses, error: feedError }] = await Promise.all([
      supabase.from('screen_health_events').select('status,observed_at,last_seen_at')
        .eq('screen_id', screen.id).order('observed_at', { ascending: false }).limit(50),
      supabase.from('screen_feed_status').select('feed_title,source_host,status,last_attempt_at,last_success_at,last_http_status,last_error_code')
        .eq('screen_id', screen.id).order('last_attempt_at', { ascending: false }).limit(50)
    ]);
    if (healthError) return toast(`Kunde inte läsa skärmhistoriken: ${healthError.message}`, true);
    if (feedError) return toast(`Kunde inte läsa feedstatus: ${feedError.message}`, true);
    const group = screenGroups.find(item => item.id === screen.group_id);
    const commands = screenCommands.filter(item => item.screen_id === screen.id).slice(0, 50).map(item => ({
      command: item.command,
      status: item.status,
      created_at: item.created_at,
      completed_at: item.completed_at
    }));
    const bundle = {
      format: 'signage-studio-support-bundle-v1',
      generated_at: new Date().toISOString(),
      note: 'Content text, pairing codes, feed URLs, and credentials are intentionally excluded.',
      screen: {
        id: screen.id,
        name: screen.name,
        group: group?.name || null,
        is_active: screen.is_active,
        online_now: isOnline(screen),
        last_seen_at: screen.last_seen_at,
        player_version: screen.player_version,
        device_model: screen.device_model,
        android_version: screen.android_version,
        display_size: screen.display_size,
        network_type: screen.network_type,
        device_updated_at: screen.device_updated_at,
        playback_mode: screen.playback_mode,
        autostart_enabled: screen.autostart_enabled,
        layout_type: screen.layout_type,
        layout_split_percent: screen.layout_split_percent,
        layout_ticker_percent: screen.layout_ticker_percent,
        operating_weekdays: screen.operating_weekdays,
        operating_start_time: screen.operating_start_time,
        operating_end_time: screen.operating_end_time
      },
      screen_health: healthEvents || [],
      feed_health: feedStatuses || [],
      recent_commands: commands
    };
    const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    const safeName = String(screen.name || 'screen').normalize('NFKD').replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48) || 'screen';
    link.href = url;
    link.download = `signage-support-${safeName}-${new Date().toISOString().slice(0, 10)}.json`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast(`Felsökningspaketet för ”${screen.name}” laddades ned.`);
  } finally {
    button.disabled = false;
  }
}

function renderContentPreview(container, screen) {
  if (screen.current_kind === 'image' && /^https?:\/\//i.test(screen.current_source_url || '')) {
    const image = document.createElement('img');
    image.src = screen.current_source_url;
    image.alt = screen.current_title || 'Bild på skärmen';
    container.append(image);
  } else if (screen.current_kind === 'web' && /^https?:\/\//i.test(screen.current_source_url || '')) {
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

function scheduleFields(schedule = null) {
  const days = [['1', 'Mån'], ['2', 'Tis'], ['3', 'Ons'], ['4', 'Tor'], ['5', 'Fre'], ['6', 'Lör'], ['7', 'Sön']];
  const selectedDays = (schedule?.weekdays || []).map(Number);
  return `<div class="schedule-fields"><div class="weekday-picker" aria-label="Återkommande veckodagar">${days.map(([value, label]) => `<label><input type="checkbox" name="weekdays" value="${value}" ${selectedDays.includes(Number(value)) ? 'checked' : ''} /><span>${label}</span></label>`).join('')}</div><div class="inline-fields"><input class="schedule-input" name="from" type="datetime-local" value="${esc(localDateTimeInput(schedule?.active_from))}" aria-label="Visa från datum och tid" /><input class="schedule-input" name="until" type="datetime-local" value="${esc(localDateTimeInput(schedule?.active_until))}" aria-label="Visa till datum och tid" /></div><div class="inline-fields"><input class="schedule-input" name="daily_from" type="time" value="${esc(schedule?.daily_start_time || '')}" aria-label="Visa dagligen från" /><input class="schedule-input" name="daily_until" type="time" value="${esc(schedule?.daily_end_time || '')}" aria-label="Visa dagligen till" /></div><span class="schedule-help">Valda dagar och klockslag återkommer varje vecka. Lämna tomt för alltid.</span></div>`;
}

function renderScreen(screen, slides, assignedChannels = [], sameNameCount = 1, latestCommand = null, channelSlides = [], publication = null, publicationVersions = [], publicationRequests = []) {
  const canAdmin = currentRole === 'admin';
  const canEdit = canAdmin || currentRole === 'editor';
  const pendingPublicationRequest = publicationRequests.find(request => request.status === 'pending');
  const requestOwner = teamMembers.find(member => member.user_id === pendingPublicationRequest?.requested_by)?.email || 'Redaktör';
  const latestPublicationRequest = publicationRequests[0];
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
  const screenGroup = screenGroups.find(group => group.id === screen.group_id);
  card.innerHTML = `
    <div class="screen-head">
      <div class="screen-title-wrap"><input class="screen-select ${canEdit ? '' : 'hidden'}" type="checkbox" ${selectedScreenIds.has(screen.id) ? 'checked' : ''} aria-label="Välj ${esc(screen.name)}" /><div class="screen-icon">▣</div><div><div class="screen-name">${esc(screen.name)}</div><div class="screen-meta">${screen.is_active ? 'AKTIV' : 'PAUSAD'} · ${esc(screenGroup?.name || 'Ingen grupp')} · ${slides.length} objekt · skapad ${screen.created_at ? new Date(screen.created_at).toLocaleDateString('sv-SE') : 'okänt datum'}${sameNameCount > 1 ? ` · ${sameNameCount} profiler med samma namn` : ''}</div></div></div>
      <div class="screen-actions">${pending}<button class="button ghost small preview-screen" type="button">Förhandsvisa utkast</button><button class="button primary small request-publish-screen ${!canAdmin && canEdit ? '' : 'hidden'}" ${screen.is_active ? '' : 'disabled'}>Skicka för godkännande</button><button class="button primary small publish-screen ${canAdmin ? '' : 'hidden'}" ${screen.is_active ? '' : 'disabled'}>Publicera</button><button class="button ghost small renew-pairing ${canAdmin ? '' : 'hidden'}">Ny kod</button><button class="button ghost small toggle-screen ${canAdmin ? '' : 'hidden'}">${screen.is_active ? 'Pausa' : 'Aktivera'}</button><button class="button ghost small delete-screen ${canAdmin ? '' : 'hidden'}">Ta bort</button></div>
    </div>
    <div class="screen-publication-state">Senast publicerad ${publication ? `version ${esc(publication.revision)} · ${esc(new Date(publication.published_at).toLocaleString('sv-SE'))}` : 'inte ännu'} · ${esc(publicationDeliverySummary(screen, publication))} · ändringar ligger som utkast tills du publicerar.</div>
    ${pendingPublicationRequest ? `<div class="publication-request-state"><span><strong>Väntar på publiceringsgodkännande</strong><small>Inskickad av ${esc(requestOwner)} · ${esc(new Date(pendingPublicationRequest.requested_at).toLocaleString('sv-SE'))}</small></span>${canAdmin ? `<div><button class="button primary small review-publication" type="button" data-decision="approve" data-request-id="${esc(pendingPublicationRequest.id)}">Godkänn och publicera</button><button class="button ghost small review-publication" type="button" data-decision="reject" data-request-id="${esc(pendingPublicationRequest.id)}">Avslå</button></div>` : ''}</div>` : latestPublicationRequest?.status === 'rejected' ? `<div class="publication-request-state rejected"><span><strong>Senaste publiceringsbegäran avslogs</strong><small>${esc(latestPublicationRequest.review_note || 'Ingen kommentar från admin.')}</small></span></div>` : ''}
    ${publicationVersions.length > 1 ? `<details class="publication-history"><summary>Versionshistorik · ${publicationVersions.length} versioner</summary><div class="publication-history-list">${publicationVersions.map((version, index) => `<div class="publication-history-row"><span><strong>Version ${esc(version.revision)}${index === 0 ? ' · aktuell' : ''}</strong><small>${esc(new Date(version.published_at).toLocaleString('sv-SE'))}</small></span>${index > 0 && canEdit && screen.is_active ? `<button class="button ghost small restore-publication" type="button" data-revision="${esc(version.revision)}">Återställ</button>` : ''}</div>`).join('')}</div><p>Återställning publicerar innehållet som en ny version och synkar det till TV:n. Utkastet i spellistor och kanaler ändras inte.</p></details>` : ''}
    <div class="screen-status-row"><div class="screen-live-status ${isOnline(screen) ? 'online' : 'offline'}"><span class="status-indicator"></span><span class="status-label">${isOnline(screen) ? 'Online nu' : 'Offline'}</span><span class="last-seen">${screen.last_seen_at ? `Senast kontakt ${new Date(screen.last_seen_at).toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}` : 'Spelaren har inte rapporterat ännu'}</span></div><div class="current-content ${isOnline(screen) ? '' : 'stale'}"><span class="current-content-label">VISAS JUST NU</span><strong class="current-title">${esc(isOnline(screen) ? (screen.current_title || 'Väntar på innehåll') : 'Ingen livekontakt')}</strong><span class="current-kind">${esc(isOnline(screen) ? kindLabel(screen.current_kind) : 'Skärmen är offline')}</span><div class="current-preview"></div></div><div class="device-diagnostics">${renderDeviceDiagnostics(screen)}</div></div>
    <div class="screen-body">
      <p class="pair-help">${screen.pair_code ? 'Öppna Signage Player på TV:n och skriv koden ovan. Koden kan bara användas en gång.' : 'TV:n är parkopplad. Publicerat innehåll synkas till spelaren och sparas lokalt för offlinevisning.'}</p>
      <details class="screen-health-history"><summary>Drifthistorik</summary><div class="screen-health-events" data-screen-health-events>Öppna för att läsa skärmens senaste online- och offlinehändelser.</div></details>
      <label class="screen-location-assignment ${canAdmin ? '' : 'hidden'}">Plats<select class="screen-location-select">${screenLocationOptions(screen.location_id || '')}</select><span>Platsmedlemmar får läsåtkomst till skärmens publicerade innehåll och historik.</span></label>
      <label class="screen-group-assignment ${canAdmin ? '' : 'hidden'}">Skärmgrupp<select class="screen-group-select">${screenGroupOptions(screen.group_id || '')}</select><span>Använd grupper för att sortera skärmar efter plats eller team.</span></label>
      <form class="screen-operating-form ${canAdmin ? '' : 'hidden'}"><div class="operating-heading"><strong>Öppettider</strong><span>TV:n visar svart utanför tiderna men fortsätter vara ansluten. Tider följer TV:ns lokala klocka.</span></div><div class="operating-days">${operatingDays.map(([day, label]) => `<label><input type="checkbox" name="operating_weekdays" value="${day}" ${selectedOperatingDays.includes(day) ? 'checked' : ''} /><span>${label}</span></label>`).join('')}</div><div class="operating-times"><label>Från<input name="operating_start_time" type="time" value="${esc(screen.operating_start_time || '')}" /></label><label>Till<input name="operating_end_time" type="time" value="${esc(screen.operating_end_time || '')}" /></label></div><button class="button ghost small" type="submit">Spara öppettider</button></form>
      <label class="screen-playback-setting ${canAdmin ? '' : 'hidden'}">Uppspelningsläge<select class="screen-playback-mode"><option value="independent" ${!['sync', 'random'].includes(screen.playback_mode) ? 'selected' : ''}>Fristående · ordnad rotation</option><option value="sync" ${screen.playback_mode === 'sync' ? 'selected' : ''}>Synkad · gemensam tidslinje</option><option value="random" ${screen.playback_mode === 'random' ? 'selected' : ''}>Slumpmässig · blanda innehållet</option></select><span>Slumpmässigt läge väljer nästa aktiva objekt utan att direkt upprepa det föregående. Synkat läge kräver rätt klocka på TV-enheterna.</span></label>
      <label class="screen-autostart-setting ${canAdmin ? '' : 'hidden'}"><span><strong>Starta spelaren när TV:n slås på</strong><small>Spelaren öppnas automatiskt efter omstart eller strömavbrott.</small></span><input class="screen-autostart" type="checkbox" ${screen.autostart_enabled !== false ? 'checked' : ''} aria-label="Starta Signage Player automatiskt vid TV-start" /></label>
      <label class="playlist-assignment ${canAdmin ? '' : 'hidden'}">Spellista för den här skärmen<select class="screen-playlist">${playlistOptions}</select><span>En spellista kan delas av flera skärmar.</span></label>
      <form class="screen-layout-form ${canAdmin ? '' : 'hidden'}"><label>Skärmlayout<select name="layout_type"><option value="single" ${screen.layout_type === 'single' ? 'selected' : ''}>En zon · fullskärm</option><option value="bottom_ticker" ${screen.layout_type === 'bottom_ticker' ? 'selected' : ''}>Huvudyta + ticker längst ned</option><option value="side_panel" ${screen.layout_type === 'side_panel' ? 'selected' : ''}>Huvudyta + sidopanel</option></select></label><label>Huvudyta vid sidopanel (%)<input name="layout_split_percent" type="number" min="55" max="85" step="1" value="${Number(screen.layout_split_percent) || 72}" /><small>Andel av skärmbredden.</small></label><label>Tickerhöjd (%)<input name="layout_ticker_percent" type="number" min="10" max="25" step="1" value="${Number(screen.layout_ticker_percent) || 16}" /><small>Andel av skärmhöjden.</small></label><label>Spellista i zon 2<select name="zone_playlist_id"><option value="">Visa zontext</option>${playlists.map(playlist => `<option value="${esc(playlist.id)}" ${playlist.id === screen.zone_playlist_id ? 'selected' : ''}>${esc(playlist.name)}</option>`).join('')}</select></label><label class="layout-text-label">Zontext<input name="layout_text" maxlength="500" value="${esc(screen.layout_text || '')}" placeholder="Visas om zonspellistan saknar aktivt innehåll" /></label><button class="button ghost small" type="submit">Spara layout</button></form>
      <section class="channel-assignment ${canEdit ? '' : 'hidden'}"><div class="channel-heading"><div><strong>Kanalschema</strong><span>Aktiv kanal prioriteras framför skärmens grundspellista. Lägre prioritetstal vinner.</span></div></div><form class="channel-schedule-form"><select name="channel_id" required>${channelOptions}</select><input name="priority" type="number" min="0" max="1000" value="100" aria-label="Kanalprioritet" />${scheduleFields()}<button class="button ghost small" type="submit">＋ Schemalägg kanal</button></form><div class="channel-schedule-list">${assignedChannels.map(item => { const channel = channels.find(c => c.id === item.channel_id); return `<article class="channel-schedule-entry"><div class="channel-schedule-row"><div><strong>${esc(channel?.name || 'Okänd kanal')}</strong><span>Prioritet ${item.priority} · ${scheduleSummary(item)}</span></div><button class="button ghost small remove-channel-schedule" type="button" data-id="${esc(item.id)}">Ta bort</button></div><details class="channel-schedule-edit"><summary>Ändra tider och prioritet</summary><form data-channel-schedule-edit="${esc(item.id)}"><label>Prioritet<input name="priority" type="number" min="0" max="1000" value="${Number(item.priority)}" required /></label>${scheduleFields(item)}<button class="button ghost small" type="submit">Spara schema som utkast</button></form></details></article>`; }).join('') || '<div class="slide-sub">Inga kanaler schemalagda för den här skärmen.</div>'}</div></section>
      <div class="player-operations ${canEdit ? '' : 'hidden'}"><div><strong>Fjärråtgärder</strong><span class="player-command-status" data-command-status>${esc(formatCommandStatus(latestCommand))}</span></div><div class="player-operation-buttons"><button class="button ghost small" data-player-command="sync_now">Synka nu</button><button class="button ghost small" data-player-command="capture_preview" ${isOnline(screen) ? "" : "disabled"} title="${isOnline(screen) ? "Begär en ny skärmbild från TV:n." : "TV:n måste vara online för att skicka en ny skärmbild."}">Uppdatera livebild</button><button class="button ghost small" data-player-command="restart_player">Starta om spelaren</button><button class="button ghost small" data-support-bundle>Hämta felsökningspaket</button></div></div>
      <div class="playlist-control"><div><strong>Visningsläge</strong><span>${screen.forced_slide_id ? 'En post är vald manuellt.' : 'TV:n roterar innehållet i spellistan.'}</span></div><button class="button ghost small return-playlist ${screen.forced_slide_id && canEdit ? '' : 'hidden'}">Återgå till spellistan</button></div>
      <div class="playlist">${slides.map((slide, index) => renderSlide(slide, index, slides.length, canEdit)).join('') || '<div class="slide-sub">Spellistan är tom. Lägg till ett objekt nedan.</div>'}</div>
      ${channelSlides.length ? `<details class="screen-channel-content"><summary>Innehåll från skärmens kanaler · ${channelSlides.length} objekt</summary><div class="playlist">${channelSlides.map(slide => `<div class="slide-row"><div class="slide-thumb">${slide.kind === 'image' ? '▧' : slide.kind === 'video' ? '▶' : slide.kind === 'feed' || slide.kind === 'web' ? '↗' : slide.kind === 'clock' ? '◷' : 'T'}</div><div><div class="slide-title">${esc(slide.title || kindLabel(slide.kind))}</div><div class="slide-sub">${esc(kindLabel(slide.kind))} · ${esc(playlists.find(item => item.id === slide.playlist_id)?.name || 'spellista')}</div></div><div class="slide-buttons"><button class="button ghost small channel-show-now" data-id="${esc(slide.id)}" ${canEdit ? '' : 'hidden'}>Visa nu</button></div></div>`).join('')}</div></details>` : ''}
      <div class="slide-add-grid ${canEdit ? '' : 'hidden'}">
        <div class="add-box"><h3>Textmeddelande</h3><form class="text-slide-form add-text"><input name="title" maxlength="80" placeholder="Rubrik" required /><textarea name="body" maxlength="1200" placeholder="Meddelande" required></textarea><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="15" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Publicera text</button></div>${scheduleFields()}</form></div>
        <div class="add-box"><h3>Bild, video eller live-data</h3><form class="text-slide-form add-source"><select name="kind"><option value="video">Video (MP4-länk eller fil)</option><option value="image">Bild (URL eller fil)</option><option value="feed">Live-data / JSON-feed (API)</option></select><label class="feed-refresh-setting hidden">Uppdatera live-data var (sek) <input name="refresh_interval_seconds" type="number" min="10" max="3600" value="30" /></label><label class="feed-integration-setting hidden">Skyddad Pulse-anslutning <select name="integration_id"><option value="">Vanlig JSON-feed</option>${signageIntegrations.map(item => `<option value="${esc(item.id)}">Pulse · ${esc(item.name)}</option>`).join('')}</select></label><input name="title" maxlength="80" placeholder="Namn på innehåll" required /><input name="url" type="url" placeholder="https://… eller intern API-adress" /><label class="file-label hidden">Videofil (valfritt) <input name="file" type="file" accept="video/mp4,video/webm,video/quicktime" /></label><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="30" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till</button></div>${scheduleFields()}</form></div>
        <div class="add-box"><h3>Klocka & datum</h3><form class="text-slide-form add-clock"><input name="title" maxlength="80" placeholder="Rubrik, till exempel Välkommen" /><input name="body" maxlength="180" placeholder="Valfri underrad" /><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="20" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till klocka</button></div>${scheduleFields()}</form></div>
        <div class="add-box"><h3>Webbsida eller live-dashboard</h3><form class="text-slide-form add-web"><input name="title" maxlength="80" placeholder="Namn på sidan" required /><input name="url" type="url" placeholder="https://…" required /><label class="web-refresh-setting">Ladda om live-dashboard var (sek) <input name="refresh_interval_seconds" type="number" min="10" max="3600" value="30" required /><small>Spelaren hämtar sidan på nytt utan att använda HTTP-cache.</small></label><div class="inline-fields"><input name="duration" type="number" min="5" max="600" value="60" aria-label="Visningstid i sekunder" /><button class="button primary" type="submit">Lägg till sida</button></div>${scheduleFields()}</form></div>
      </div>
    </div>`;
  const screenBody = card.querySelector('.screen-body');
  const settingGroups = [
    ['overview', 'Översikt', ['.pair-help', '.screen-health-history', '.screen-location-assignment', '.screen-group-assignment']],
    ['content', 'Innehåll', ['.playlist-assignment', '.playlist-control', '.playlist', '.screen-channel-content', '.slide-add-grid']],
    ['schedule', 'Schema', ['.screen-operating-form', '.channel-assignment']],
    ['layout', 'Layout', ['.screen-layout-form']],
    ['device', 'Enhet & drift', ['.screen-playback-setting', '.screen-autostart-setting', '.player-operations']]
  ];
  const settingNav = document.createElement('nav');
  settingNav.className = 'screen-setting-navigation';
  settingNav.setAttribute('aria-label', 'Skärminställningar');
  const settingViews = document.createElement('div');
  settingViews.className = 'screen-setting-views';
  settingGroups.forEach(([key, label, selectors], index) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `screen-setting-tab${index === 0 ? ' active' : ''}`;
    button.dataset.screenSetting = key;
    button.textContent = label;
    if (index === 0) button.setAttribute('aria-current', 'page');
    settingNav.append(button);
    const view = document.createElement('section');
    view.className = 'screen-setting-view';
    view.dataset.screenSettingView = key;
    view.setAttribute('aria-label', label);
    view.classList.toggle('hidden', index !== 0);
    selectors.forEach(selector => {
      const node = screenBody.querySelector(selector);
      if (node) view.append(node);
    });
    if (!view.children.length) view.innerHTML = '<p class="screen-setting-empty">Inga inställningar i den här kategorin.</p>';
    settingViews.append(view);
  });
  screenBody.prepend(settingViews);
  screenBody.prepend(settingNav);
  settingNav.addEventListener('click', event => {
    const button = event.target.closest('[data-screen-setting]');
    if (!button) return;
    settingNav.querySelectorAll('.screen-setting-tab').forEach(tab => {
      const active = tab === button;
      tab.classList.toggle('active', active);
      if (active) tab.setAttribute('aria-current', 'page');
      else tab.removeAttribute('aria-current');
    });
    settingViews.querySelectorAll('[data-screen-setting-view]').forEach(view => {
      view.classList.toggle('hidden', view.dataset.screenSettingView !== button.dataset.screenSetting);
    });
  });
  card.querySelector('.preview-screen').addEventListener('click', () => openDraftPreview(
    screen,
    slides,
    channelSlides,
    assignedChannels,
    playlistSlides.filter(item => item.playlist_id === screen.zone_playlist_id)
  ));
  card.querySelector('.request-publish-screen').addEventListener('click', async event => {
    const button = event.currentTarget;
    button.disabled = true;
    const { error } = await supabase.rpc('request_screen_publication', { input_screen_id: screen.id });
    button.disabled = false;
    if (error) return toast(error.message, true);
    toast(`Utkastet för ”${screen.name}” skickades till admin för godkännande.`);
    await loadScreens();
  });
  card.querySelectorAll('.review-publication').forEach(button => button.addEventListener('click', async () => {
    const decision = button.dataset.decision;
    const note = decision === 'reject' ? prompt('Kort kommentar till redaktören (valfritt):') : null;
    if (decision === 'reject' && note === null) return;
    if (decision === 'approve' && !confirm(`Godkänn den inskickade versionen av ”${screen.name}” och publicera till TV:n?`)) return;
    button.disabled = true;
    const { data: revision, error } = await supabase.rpc('review_screen_publication', {
      input_request_id: button.dataset.requestId,
      input_decision: decision,
      input_review_note: note
    });
    button.disabled = false;
    if (error) return toast(error.message, true);
    toast(decision === 'approve' ? `Godkänd som version ${revision}. Synk köad till TV:n.` : 'Publiceringsbegäran avslogs.');
    await loadScreens();
  }));
  card.querySelectorAll('.restore-publication').forEach(button => button.addEventListener('click', async () => {
    const revisionToRestore = Number(button.dataset.revision);
    if (!Number.isInteger(revisionToRestore) || !confirm(`Återställ version ${revisionToRestore} till ”${screen.name}”? Den publiceras som en ny version och skickas till TV:n.`)) return;
    button.disabled = true;
    const { data: revision, error } = await supabase.rpc('restore_screen_publication', {
      input_screen_id: screen.id,
      input_revision: revisionToRestore
    });
    button.disabled = false;
    if (error) return toast(error.message, true);
    toast(`Version ${revisionToRestore} återställd som version ${revision}. Synk köad till spelaren.`);
    await loadScreens();
  }));
  card.querySelector('.screen-select').addEventListener('change', event => {
    if (event.currentTarget.checked) selectedScreenIds.add(screen.id);
    else selectedScreenIds.delete(screen.id);
    updateBulkScreenActions();
  });
  card.querySelector('.publish-screen').addEventListener('click', async event => {
    const button = event.currentTarget;
    button.disabled = true;
    const { data: revision, error } = await supabase.rpc('publish_screen_content', { input_screen_id: screen.id });
    button.disabled = false;
    if (error) return toast(error.message, true);
    toast(`Version ${revision} publicerades för “${screen.name}”. Synk köad till spelaren.`);
    await loadScreens();
  });
  card.querySelector('.screen-group-select').addEventListener('change', async event => {
    const group_id = event.currentTarget.value || null;
    const { error } = await supabase.from('screens').update({ group_id }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast(`”${screen.name}” flyttades till ”${screenGroups.find(group => group.id === group_id)?.name || 'Ingen grupp'}”.`);
    await loadScreens();
  });
  card.querySelector('.screen-location-select').addEventListener('change', async event => {
    const location_id = event.currentTarget.value || null;
    const { error } = await supabase.from('screens').update({ location_id }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast(`”${screen.name}” flyttades till ”${locations.find(item => item.id === location_id)?.name || 'Ingen plats'}”.`);
    await loadScreens();
  });
  updateCurrentPreview(card.querySelector('.current-preview'), screen, isOnline(screen));
  const healthHistory = card.querySelector('.screen-health-history');
  healthHistory.addEventListener('toggle', async () => {
    if (!healthHistory.open || healthHistory.dataset.loading === 'true') return;
    healthHistory.dataset.loading = 'true';
    healthHistory.dataset.loaded = 'loading';
    const container = healthHistory.querySelector('[data-screen-health-events]');
    container.textContent = 'Hämtar drifthistorik …';
    const { data, error } = await supabase.from('screen_health_events')
      .select('status,observed_at,last_seen_at')
      .eq('screen_id', screen.id)
      .order('observed_at', { ascending: false })
      .limit(50);
    if (error) {
      container.textContent = `Kunde inte läsa historiken: ${error.message}`;
      delete healthHistory.dataset.loading;
      return;
    }
    if (!data?.length) {
      container.textContent = 'Ingen historik ännu. Händelser visas efter att spelarens första status har registrerats.';
      delete healthHistory.dataset.loading;
      return;
    }
    const formatEventTime = value => value
      ? new Intl.DateTimeFormat('sv-SE', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
      : 'Okänd tid';
    container.innerHTML = data.map(event => `<article class="screen-health-event"><span class="health-event-mark ${event.status === 'online' ? 'online' : 'offline'}"></span><div><strong>${event.status === 'online' ? 'Spelaren upptäcktes online' : 'Spelaren upptäcktes offline'}</strong><time>${esc(formatEventTime(event.observed_at))}</time>${event.status === 'offline' ? `<small>Senaste heartbeat: ${esc(formatEventTime(event.last_seen_at))}</small>` : ''}</div></article>`).join('');
    delete healthHistory.dataset.loading;
  });

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
    const playback_mode = ['sync', 'random'].includes(event.currentTarget.value) ? event.currentTarget.value : 'independent';
    const { error } = await supabase.from('screens').update({ playback_mode }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    const label = { sync: 'Synkad', random: 'Slumpmässig', independent: 'Fristående' }[playback_mode];
    toast(`${label} uppspelning aktiveras på nästa synk.`);
    await loadScreens();
  });
  card.querySelector('.screen-autostart').addEventListener('change', async event => {
    const autostart_enabled = event.currentTarget.checked;
    const { error } = await supabase.from('screens').update({ autostart_enabled }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast(autostart_enabled ? 'Spelaren startar automatiskt när TV:n slås på.' : 'Autostart stängdes av för skärmen.');
    await loadScreens();
  });
  card.querySelector('.screen-playlist').addEventListener('change', async event => {
    const playlist_id = event.currentTarget.value || null;
    const { error } = await supabase.from('screens').update({ playlist_id, forced_slide_id: null }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast(playlist_id ? 'Spellistan tilldelades som utkast. Publicera skärmen för att skicka ändringen till TV:n.' : 'Skärmen använder sin egen spellista som utkast. Publicera skärmen för att skicka ändringen till TV:n.');
    await loadScreens();
  });
  card.querySelector('.screen-layout-form').addEventListener('submit', async event => {
    event.preventDefault();
    const f = new FormData(event.currentTarget);
    const layout_type = String(f.get('layout_type'));
    const layout_text = String(f.get('layout_text') || '').trim();
    const zone_playlist_id = String(f.get('zone_playlist_id') || '') || null;
    const layout_split_percent = Number(f.get('layout_split_percent'));
    const layout_ticker_percent = Number(f.get('layout_ticker_percent'));
    if (!Number.isInteger(layout_split_percent) || layout_split_percent < 55 || layout_split_percent > 85) return toast('Huvudytan måste vara mellan 55 och 85 procent.', true);
    if (!Number.isInteger(layout_ticker_percent) || layout_ticker_percent < 10 || layout_ticker_percent > 25) return toast('Tickerhöjden måste vara mellan 10 och 25 procent.', true);
    if (layout_type !== 'single' && !layout_text && !zone_playlist_id) return toast('Välj en zonspellista eller skriv zontext.', true);
    const { error } = await supabase.from('screens').update({ layout_type, layout_text, zone_playlist_id, layout_split_percent, layout_ticker_percent }).eq('id', screen.id);
    if (error) return toast(error.message, true);
    toast('Skärmlayouten och zonspellistan sparades som utkast. Publicera skärmen för att skicka ändringen till TV:n.');
    await loadScreens();
  });
  card.querySelector('.channel-schedule-form').addEventListener('submit', async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const f = new FormData(form);
    const values = scheduleValues(f);
    if (!values) return;
    const priority = schedulePriority(f);
    if (priority === null) return;
    if (assignedChannels.some(item => item.channel_id === f.get('channel_id'))) return toast('Den här kanalen är redan tilldelad. Ändra eller ta bort det befintliga schemat.', true);
    const { error } = await supabase.from('screen_channel_schedules').insert({ screen_id: screen.id, channel_id: String(f.get('channel_id')), priority, ...values });
    if (error) return toast(error.message, true);
    toast('Kanalschemat sparades som utkast. Publicera skärmen för att skicka schemat till TV:n.');
    await loadScreens();
  });
  card.querySelectorAll('[data-channel-schedule-edit]').forEach(form => form.addEventListener('submit', async event => {
    event.preventDefault();
    const values = new FormData(form);
    const schedule = scheduleValues(values);
    if (!schedule) return;
    const priority = schedulePriority(values);
    if (priority === null) return;
    const { error } = await supabase.from('screen_channel_schedules')
      .update({ priority, ...schedule })
      .eq('id', form.dataset.channelScheduleEdit)
      .eq('screen_id', screen.id);
    if (error) return toast(error.message, true);
    toast('Kanalschemat uppdaterades som utkast. Publicera skärmen för att skicka ändringen till TV:n.');
    await loadScreens();
  }));
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
      const commandLabel = button.dataset.playerCommand === 'restart_player' ? 'Omstart'
        : button.dataset.playerCommand === 'capture_preview' ? 'Ny livebild' : 'Synk';
      toast(`${commandLabel} köad för “${screen.name}”.`);
      refreshScreenStatus();
    } finally {
      button.disabled = false;
    }
  }));
  card.querySelector('[data-support-bundle]').addEventListener('click', event => downloadScreenSupportBundle(screen, event.currentTarget));
  card.querySelector('.delete-screen').addEventListener('click', async () => {
    if (!confirm(`Ta bort skärmen “${screen.name}” och dess spellista?`)) return;
    const { error } = await supabase.from('screens').delete().eq('id', screen.id);
    if (error) toast(error.message, true); else { toast('Skärmen togs bort.'); loadScreens(); }
  });
  card.querySelector('.add-text').addEventListener('submit', event => addSlide(event, screen, 'text'));
  card.querySelector('.add-clock').addEventListener('submit', event => addSlide(event, screen, 'clock'));
  const sourceForm = card.querySelector('.add-source');
  sourceForm.querySelector('[name="kind"]').addEventListener('change', event => {
    const kind = event.target.value;
    sourceForm.querySelector('.feed-refresh-setting').classList.toggle('hidden', kind !== 'feed');
    sourceForm.querySelector('.feed-integration-setting').classList.toggle('hidden', kind !== 'feed' || signageIntegrations.length === 0);
    syncFeedIntegrationField(sourceForm);
    const fileInput = sourceForm.querySelector('[name="file"]');
    fileInput.accept = kind === 'image' ? 'image/jpeg,image/png,image/webp' : kind === 'video' ? 'video/mp4,video/webm,video/quicktime' : '';
    sourceForm.querySelector('.file-label').classList.toggle('hidden', !['image', 'video'].includes(kind));
    sourceForm.querySelector('.file-label').firstChild.textContent = kind === 'image' ? 'Bildfil (valfritt) ' : 'Videofil (valfritt) ';
  });
  sourceForm.querySelector('[name="integration_id"]').addEventListener('change', () => syncFeedIntegrationField(sourceForm));
  sourceForm.querySelector('[name="kind"]').dispatchEvent(new Event('change'));
  sourceForm.addEventListener('submit', event => addSource(event, screen, slides.length));
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
  const liveRefresh = ['feed','web'].includes(slide.kind) ? ` · uppdateras var ${slide.refresh_interval_seconds || 30}s` : '';
  return `<div class="slide-row"><div class="slide-thumb">${slide.kind === 'image' ? '▧' : slide.kind === 'video' ? '▶' : slide.kind === 'feed' ? '↗' : slide.kind === 'web' ? '↗' : slide.kind === 'clock' ? '◷' : 'T'}</div><div><div class="slide-title">${esc(slide.title || kindLabel(slide.kind))}</div><div class="slide-sub">${esc(kindLabel(slide.kind))} · ${slide.duration_seconds}s${liveRefresh} · ${esc(detail)}</div></div><div class="slide-buttons"><button class="button ghost small show-now" data-slide-action="show-now" data-id="${slide.id}" ${canEdit ? '' : 'hidden'}>Visa nu</button><button class="icon-button" data-slide-action="up" data-id="${slide.id}" ${canEdit ? '' : 'hidden'} ${index === 0 ? 'disabled' : ''}>↑</button><button class="icon-button" data-slide-action="down" data-id="${slide.id}" ${canEdit ? '' : 'hidden'} ${index === count - 1 ? 'disabled' : ''}>↓</button><button class="icon-button delete" data-slide-action="delete" data-id="${slide.id}" ${canEdit ? '' : 'hidden'}>×</button></div></div>`;
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
  const refresh_interval_seconds = Number(f.get('refresh_interval_seconds') || 30);
  if (!Number.isInteger(refresh_interval_seconds) || refresh_interval_seconds < 10 || refresh_interval_seconds > 3600) return toast('Uppdateringsintervallet ska vara 10–3600 sekunder.', true);
  const { error } = await supabase.from('slides').insert({ ...contentOwner(screen), kind: 'web', title: String(f.get('title') || '').trim(), source_url, duration_seconds: Number(f.get('duration')) || 60, refresh_interval_seconds, sort_order: await nextOrder(screen), is_active: true, ...schedule });
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

function schedulePriority(formData) {
  const raw = String(formData.get('priority') ?? '').trim();
  const value = raw === '' ? 100 : Number(raw);
  if (!Number.isInteger(value) || value < 0 || value > 1000) {
    toast('Prioriteten ska vara ett heltal mellan 0 och 1000.', true);
    return null;
  }
  return value;
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
  const integration_id = kind === 'feed' ? String(f.get('integration_id') || '') || null : null;
  const integration = signageIntegrations.find(item => item.id === integration_id);
  if (integration) source_url = integration.endpoint_url;
  let uploadedFile = null;
  const file = f.get('file');
  const schedule = scheduleValues(f);
  if (!schedule) return;
  if (kind === 'feed' && file instanceof File && file.size > 0) return toast('JSON-feed använder en URL, inte en fil.', true);
  if (file instanceof File && file.size > 0) {
    if (!['image', 'video'].includes(kind)) return toast('Välj bild eller video för att ladda upp en fil.', true);
    const maxBytes = kind === 'image' ? 30 * 1024 * 1024 : 400 * 1024 * 1024;
    if (file.size > maxBytes) return toast(kind === 'image' ? 'Bildfilen får vara högst 30 MB.' : 'Videofilen får vara högst 400 MB.', true);
    if (kind === 'image' && !['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) return toast('Bilder ska vara JPEG, PNG eller WebP.', true);
    try {
      uploadedFile = await uploadSignageFile(file, { form, prefix: `screens/${screen.playlist_id || screen.id}` });
      source_url = uploadedFile.source_url;
    } catch (error) {
      return toast(error.message || 'Filen kunde inte laddas upp.', true);
    }
  }
  if (!source_url) return toast('Ange en bild-/videolänk, en feed-URL eller välj en fil.', true);
  if (integration_id && !integration) return toast('Den valda Pulse-anslutningen finns inte längre. Ladda om sidan.', true);
  if (kind === 'feed' && !integration_id && /#token=/i.test(source_url)) return toast('Lägg Pulse-token i en skyddad Pulse-anslutning under Integrationer, inte i feed-URL:en.', true);
  if (['image', 'video', 'feed'].includes(kind) && !/^https?:\/\//i.test(source_url)) return toast('Källan ska börja med HTTPS eller HTTP.', true);
  const refresh_interval_seconds = kind === 'feed' ? Number(f.get('refresh_interval_seconds') || 30) : 30;
  if (kind === 'feed' && (!Number.isInteger(refresh_interval_seconds) || refresh_interval_seconds < 10 || refresh_interval_seconds > 3600)) return toast('Uppdateringsintervallet ska vara 10–3600 sekunder.', true);
  const { error } = await supabase.from('slides').insert({ ...contentOwner(screen), kind, title: String(f.get('title') || '').trim(), source_url, integration_id, duration_seconds: Number(f.get('duration')) || 30, refresh_interval_seconds, sort_order: await nextOrder(screen), is_active: true, ...schedule });
  if (error) return toast(error.message, true);
  uploadedFile?.finalize();
  form.reset();
  form.querySelector('[name="kind"]').dispatchEvent(new Event('change'));
  toast('Innehållet publicerades.'); await loadScreens();
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
