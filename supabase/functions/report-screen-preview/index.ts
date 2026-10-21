import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-screen-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function respond(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return respond({ error: 'Method not allowed' }, 405);

  const screenId = request.headers.get('x-screen-id') || '';
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(screenId)) {
    return respond({ error: 'Invalid screen id' }, 400);
  }
  const declaredLength = Number(request.headers.get('content-length') || 0);
  if (declaredLength > 2 * 1024 * 1024) return respond({ error: 'Preview is too large' }, 413);
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('image/jpeg')) {
    return respond({ error: 'Expected a JPEG image' }, 415);
  }

  const reader = request.body?.getReader();
  if (!reader) return respond({ error: 'Missing image body' }, 400);
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > 2 * 1024 * 1024) {
      await reader.cancel();
      return respond({ error: 'Preview is too large' }, 413);
    }
    chunks.push(value);
  }
  if (total < 4) return respond({ error: 'Empty image' }, 400);
  const image = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    image.set(chunk, offset);
    offset += chunk.byteLength;
  }
  if (image[0] !== 0xff || image[1] !== 0xd8 || image[2] !== 0xff) {
    return respond({ error: 'Invalid JPEG image' }, 415);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) return respond({ error: 'Preview service is not configured' }, 500);
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: screen, error: screenError } = await admin
    .from('screens')
    .select('id,activated_at,preview_updated_at')
    .eq('id', screenId)
    .maybeSingle();
  if (screenError) return respond({ error: 'Could not verify the screen' }, 500);
  if (!screen) return respond({ error: 'Screen not found' }, 404);
  if (!screen.activated_at) return respond({ error: 'Screen has not been paired' }, 403);
  if (screen.preview_updated_at && Date.now() - new Date(screen.preview_updated_at).getTime() < 20_000) {
    return respond({ error: 'Preview received too recently' }, 429);
  }

  const path = `screens/${screenId}/current.jpg`;
  const { error: uploadError } = await admin.storage.from('signage-previews').upload(path, image, {
    contentType: 'image/jpeg',
    cacheControl: '0',
    upsert: true,
  });
  if (uploadError) return respond({ error: 'Could not save the preview' }, 500);

  const { error: updateError } = await admin
    .from('screens')
    .update({ preview_updated_at: new Date().toISOString() })
    .eq('id', screenId);
  if (updateError) return respond({ error: 'Could not update preview status' }, 500);

  return respond({ ok: true });
});
