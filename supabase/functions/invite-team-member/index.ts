import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
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

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return respond({ error: 'Team invitation is not configured' }, 500);

  const authorization = request.headers.get('Authorization') || '';
  const accessToken = authorization.replace(/^Bearer\s+/i, '');
  if (!accessToken || accessToken === authorization) return respond({ error: 'Sign in as a team admin first' }, 401);

  const caller = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await caller.auth.getUser(accessToken);
  if (authError || !authData.user) return respond({ error: 'Your session has expired. Sign in again.' }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: callerRole, error: roleError } = await admin.from('team_members')
    .select('role').eq('user_id', authData.user.id).maybeSingle();
  if (roleError) return respond({ error: 'Could not verify team permissions' }, 500);
  if (callerRole?.role !== 'admin') return respond({ error: 'Only admins can invite team members' }, 403);

  let input: { email?: unknown; role?: unknown };
  try {
    input = await request.json();
  } catch {
    return respond({ error: 'Request body must be JSON' }, 400);
  }
  if (!input || typeof input !== 'object' || Array.isArray(input)) return respond({ error: 'Request body must be a JSON object' }, 400);
  const email = typeof input.email === 'string' ? input.email.trim().toLowerCase() : '';
  const role = typeof input.role === 'string' ? input.role : '';
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return respond({ error: 'Enter a valid email address' }, 400);
  if (!['admin', 'editor', 'viewer', 'group_member'].includes(role)) return respond({ error: 'Choose a valid team role' }, 400);

  const { data: userPage, error: listError } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (listError) return respond({ error: 'Could not look up the account' }, 500);
  let target = userPage.users.find((user) => user.email?.toLowerCase() === email);
  let invited = false;
  if (!target) {
    const { data: invitation, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email);
    if (inviteError) return respond({ error: `Invitation could not be sent: ${inviteError.message}` }, 502);
    target = invitation.user || undefined;
    invited = true;
  }
  if (!target) return respond({ error: 'Auth did not return the invited account' }, 502);

  const { error: memberError } = await admin.from('team_members').upsert({
    user_id: target.id,
    email,
    role,
    updated_at: new Date().toISOString(),
  }, { onConflict: 'user_id' });
  if (memberError) {
    if (invited) await admin.auth.admin.deleteUser(target.id);
    return respond({ error: 'The invitation was created but the team role could not be assigned' }, 500);
  }
  if (role !== 'group_member') {
    const { error: accessError } = await admin.from('screen_group_members').delete().eq('user_id', target.id);
    if (accessError) return respond({ error: 'The role was saved, but old group restrictions could not be cleared' }, 500);
  }

  return respond({ ok: true, invited, email, role });
});
