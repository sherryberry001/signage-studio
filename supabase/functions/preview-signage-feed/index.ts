import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};
const MAX_RESPONSE_BYTES = 1_500_000;

function respond(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function isSafeEndpoint(value: string) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    return url.protocol === 'https:'
      && !url.username && !url.password
      && host.includes('.')
      && !host.endsWith('.localhost')
      && !host.endsWith('.local')
      && !host.endsWith('.lan')
      && !host.endsWith('.home')
      && !host.endsWith('.internal')
      && !host.endsWith('.test')
      && !host.startsWith('[')
      && !/^\d{1,3}(\.\d{1,3}){3}$/.test(host);
  } catch {
    return false;
  }
}

async function readLimited(response: Response) {
  const declaredLength = Number(response.headers.get('content-length') || 0);
  if (declaredLength > MAX_RESPONSE_BYTES) throw new Error('Feed-svaret är för stort.');
  if (!response.body) throw new Error('Feeden returnerade inget innehåll.');

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_RESPONSE_BYTES) {
      await reader.cancel();
      throw new Error('Feed-svaret är för stort.');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return respond({ error: 'Method not allowed' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return respond({ error: 'Live-preview is not configured' }, 500);

  const authorization = request.headers.get('Authorization') || '';
  const accessToken = authorization.replace(/^Bearer\s+/i, '');
  if (!accessToken || accessToken === authorization) return respond({ error: 'Sign in to preview live feeds' }, 401);

  const caller = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await caller.auth.getUser(accessToken);
  if (authError || !authData.user) return respond({ error: 'Your session has expired. Sign in again.' }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: membership, error: membershipError } = await admin.from('team_members')
    .select('role').eq('user_id', authData.user.id).maybeSingle();
  if (membershipError) return respond({ error: 'Could not verify team permissions' }, 500);
  if (!['admin', 'editor'].includes(membership?.role || '')) return respond({ error: 'Only admins and editors can preview live feeds' }, 403);

  let input: { integration_id?: unknown };
  try {
    input = await request.json();
  } catch {
    return respond({ error: 'Request body must be JSON' }, 400);
  }
  const integrationId = typeof input?.integration_id === 'string' ? input.integration_id : '';
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(integrationId)) {
    return respond({ error: 'Choose a configured Pulse integration' }, 400);
  }

  const { data: integration, error: integrationError } = await admin.from('signage_integrations')
    .select('id,endpoint_url,provider').eq('id', integrationId).maybeSingle();
  if (integrationError) return respond({ error: 'Could not load the Pulse integration' }, 500);
  if (!integration || integration.provider !== 'dizparc_pulse' || !isSafeEndpoint(integration.endpoint_url)) {
    return respond({ error: 'The Pulse endpoint must use a public HTTPS address' }, 400);
  }
  const { data: secret, error: secretError } = await admin.from('signage_integration_secrets')
    .select('display_token').eq('integration_id', integrationId).maybeSingle();
  if (secretError) return respond({ error: 'Could not load the Pulse credential' }, 500);
  if (!secret?.display_token) return respond({ error: 'The Pulse integration has no display credential' }, 400);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8_000);
  try {
    const upstream = await fetch(integration.endpoint_url, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache, no-store, max-age=0',
        'Pragma': 'no-cache',
        'x-pulse-display-token': secret.display_token,
      },
      cache: 'no-store',
      redirect: 'error',
      signal: controller.signal,
    });
    if (!upstream.ok) return respond({ error: `Pulse svarade med HTTP ${upstream.status}.` }, 502);
    const raw = await readLimited(upstream);
    let payload: unknown;
    try {
      payload = JSON.parse(raw);
    } catch {
      return respond({ error: 'Pulse returnerade inte giltig JSON.' }, 502);
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      return respond({ error: 'Pulse-svaret måste vara ett JSON-objekt.' }, 502);
    }
    return respond({ payload: payload as Record<string, unknown>, fetched_at: new Date().toISOString() });
  } catch (error) {
    const timedOut = error instanceof DOMException && error.name === 'AbortError';
    return respond({ error: timedOut ? 'Pulse svarade inte inom åtta sekunder.' : 'Kunde inte nå Pulse-tjänsten.' }, 502);
  } finally {
    clearTimeout(timeout);
  }
});
