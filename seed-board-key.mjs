// One-time seed script to create a board API key from env var
// Runs before the server starts
import { createHash } from 'node:crypto';
import postgres from '/app/packages/db/node_modules/postgres/src/index.js';

const seedToken = process.env.PAPERCLIP_SEED_BOARD_KEY;
if (!seedToken) {
  console.log('[seed] PAPERCLIP_SEED_BOARD_KEY not set, skipping');
  process.exit(0);
}

const dbUrl = process.env.DATABASE_URL;
if (!dbUrl) {
  console.log('[seed] DATABASE_URL not set, skipping');
  process.exit(0);
}

try {
  const sql = postgres(dbUrl, { ssl: 'prefer' });
  const seedHash = createHash('sha256').update(seedToken).digest('hex');

  // Check if key already exists
  const existing = await sql`
    SELECT id FROM board_api_keys WHERE key_hash = ${seedHash} AND revoked_at IS NULL
  `;
  if (existing.length > 0) {
    console.log('[seed] Board API key already exists');
    await sql.end();
    process.exit(0);
  }

  // Find first instance_admin user
  const admin = await sql`
    SELECT user_id FROM instance_user_roles WHERE role = 'instance_admin' LIMIT 1
  `;
  if (admin.length === 0) {
    console.log('[seed] No instance_admin user found, skipping');
    await sql.end();
    process.exit(0);
  }

  const userId = admin[0].user_id;
  const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

  await sql`
    INSERT INTO board_api_keys (id, user_id, name, key_hash, expires_at, created_at)
    VALUES (gen_random_uuid(), ${userId}, 'seed-board-key', ${seedHash}, ${expiresAt}, NOW())
  `;

  console.log('[seed] Board API key created successfully');
  await sql.end();
} catch (err) {
  console.error('[seed] Error:', err.message);
}
process.exit(0);
