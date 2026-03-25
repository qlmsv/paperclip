const crypto = require('crypto');
const path = require('path');
const fs = require('fs');

// Find pg module in the monorepo
let Client;
const pgPaths = [
  path.join(__dirname, 'server', 'node_modules', 'pg'),
  path.join(__dirname, 'node_modules', 'pg'),
  path.join(__dirname, 'packages', 'db', 'node_modules', 'pg'),
  'pg'
];
for (const p of pgPaths) {
  try { Client = require(p).Client; break; } catch {}
}
if (!Client) {
  console.error('ERROR: pg module not found in any of:', pgPaths);
  process.exit(1);
}

async function main() {
  const dbUrl = process.env.DATABASE_URL;
  if (!dbUrl) {
    console.log('No DATABASE_URL set, skipping bootstrap');
    return;
  }

  const c = new Client({ connectionString: dbUrl });
  await c.connect();

  // Check if admin already exists
  const adminCheck = await c.query(
    "SELECT COUNT(*) as cnt FROM instance_user_roles WHERE role = 'instance_admin'"
  );
  if (parseInt(adminCheck.rows[0].cnt) > 0) {
    console.log('Instance admin already exists, skipping bootstrap');
    await c.end();
    return;
  }

  // Check if active invite exists
  const inviteCheck = await c.query(
    "SELECT COUNT(*) as cnt FROM invites WHERE invite_type = 'bootstrap_ceo' AND revoked_at IS NULL AND accepted_at IS NULL AND expires_at > NOW()"
  );
  if (parseInt(inviteCheck.rows[0].cnt) > 0) {
    console.log('Active bootstrap invite already exists, skipping');
    await c.end();
    return;
  }

  // Revoke any expired ones
  await c.query(
    "UPDATE invites SET revoked_at=NOW(), updated_at=NOW() WHERE invite_type='bootstrap_ceo' AND revoked_at IS NULL AND accepted_at IS NULL"
  );

  // Generate token
  const tokenRandom = crypto.randomBytes(24).toString('hex');
  const token = 'pcp_bootstrap_' + tokenRandom;
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
  const expiresAt = new Date(Date.now() + 72 * 3600 * 1000).toISOString();

  await c.query(
    "INSERT INTO invites (id, invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id, created_at, updated_at) VALUES (gen_random_uuid(), 'bootstrap_ceo', $1, 'human', $2::timestamptz, 'system', NOW(), NOW())",
    [tokenHash, expiresAt]
  );

  const baseUrl = process.env.PAPERCLIP_PUBLIC_URL || 'https://paperclip-7lyg.onrender.com';
  const inviteUrl = baseUrl + '/invite/' + token;

  console.log('');
  console.log('============================================');
  console.log('  BOOTSTRAP CEO INVITE CREATED');
  console.log('  URL: ' + inviteUrl);
  console.log('  Expires: ' + expiresAt);
  console.log('============================================');
  console.log('');

  await c.end();
}

main().catch(e => { console.error('Bootstrap error:', e.message); });
