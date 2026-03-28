import { createHash, randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';

// Resolve postgres module from the monorepo
const require = createRequire(import.meta.url);
let postgres;
const paths = [
  './packages/db/node_modules/postgres',
  './server/node_modules/postgres',
  './node_modules/postgres',
  'postgres'
];
for (const p of paths) {
  try {
    const mod = await import(p);
    postgres = mod.default || mod;
    console.log('[bootstrap] Found postgres module at:', p);
    break;
  } catch {}
}
if (!postgres) {
  // Try require as fallback
  for (const p of paths) {
    try { postgres = require(p); console.log('[bootstrap] Found postgres via require at:', p); break; } catch {}
  }
}
if (!postgres) {
  console.error('[bootstrap] postgres module not found, skipping');
  process.exit(0);
}

const dbUrl = process.env.DATABASE_URL;
if (!dbUrl) {
  console.log('[bootstrap] No DATABASE_URL, skipping');
  process.exit(0);
}

function hashToken(token) {
  return createHash('sha256').update(token).digest('hex');
}

function createInviteToken() {
  return `pcp_bootstrap_${randomBytes(24).toString('hex')}`;
}

const baseUrl = (
  process.env.PAPERCLIP_PUBLIC_URL ||
  process.env.PAPERCLIP_AUTH_PUBLIC_BASE_URL ||
  process.env.BETTER_AUTH_URL ||
  process.env.BETTER_AUTH_BASE_URL ||
  'https://os.kai-it.pro'
).replace(/\/+$/, '');

let sql;
let exitCode = 0;
try {
  sql = postgres(dbUrl, { max: 1 });

  // Check if admin already exists
  const admins = await sql`SELECT COUNT(*)::int as cnt FROM instance_user_roles WHERE role = 'instance_admin'`;
  if (admins[0].cnt > 0) {
    console.log('[bootstrap] Admin already exists, skipping');
  } else {
    // Match Paperclip's normal bootstrap flow: revoke any active invite and mint a new one.
    await sql`
      UPDATE invites SET revoked_at = NOW(), updated_at = NOW()
      WHERE invite_type = 'bootstrap_ceo'
        AND revoked_at IS NULL
        AND accepted_at IS NULL
        AND expires_at > NOW()
    `;

    const token = createInviteToken();
    const tokenHash = hashToken(token);
    const expiresAt = new Date(Date.now() + 72 * 60 * 60 * 1000);

    await sql`
      INSERT INTO invites (id, invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id, created_at, updated_at)
      VALUES (gen_random_uuid(), 'bootstrap_ceo', ${tokenHash}, 'human', ${expiresAt}, 'system', NOW(), NOW())
    `;

    const inviteUrl = `${baseUrl}/invite/${token}`;
    console.log('');
    console.log('============================================');
    console.log('  BOOTSTRAP CEO INVITE CREATED');
    console.log('  URL: ' + inviteUrl);
    console.log('  Expires: ' + expiresAt.toISOString());
    console.log('============================================');
    console.log('');
  }

} catch (err) {
  console.error('[bootstrap] Error:', err.message || err);
  exitCode = 1;
} finally {
  await sql?.end?.({ timeout: 5 }).catch(async () => {
    await sql?.end?.().catch(() => undefined);
  });
  process.exit(exitCode);
}
