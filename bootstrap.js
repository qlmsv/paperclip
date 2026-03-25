const crypto = require('crypto');
const { Client } = require('/app/server/node_modules/pg');

async function main() {
  const c = new Client(process.env.DATABASE_URL);
  await c.connect();
  
  await c.query(
    "UPDATE invites SET revoked_at=NOW(), updated_at=NOW() WHERE invite_type='bootstrap_ceo' AND revoked_at IS NULL AND accepted_at IS NULL AND expires_at > NOW()"
  );
  
  const tokenRandom = crypto.randomBytes(24).toString('hex');
  const token = 'pcp_bootstrap_' + tokenRandom;
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
  const expiresAt = new Date(Date.now() + 72*3600*1000).toISOString();
  
  await c.query(
    "INSERT INTO invites (id, invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id, created_at, updated_at) VALUES (gen_random_uuid(), 'bootstrap_ceo', $1, 'human', $2::timestamptz, 'system', NOW(), NOW())",
    [tokenHash, expiresAt]
  );
  
  const url = (process.env.PAPERCLIP_PUBLIC_URL || 'https://paperclip-7lyg.onrender.com') + '/invite/' + token;
  
  // Write to a file that persists
  require('fs').writeFileSync('/tmp/invite-url.txt', url);
  console.log('INVITE_URL=' + url);
  
  await c.end();
}

main().catch(e => { console.error(e); process.exit(1); });
