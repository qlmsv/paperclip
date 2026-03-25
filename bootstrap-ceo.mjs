#!/usr/bin/env node
// One-shot bootstrap script: creates a CEO invite token and prints the invite URL.
// Uses the pg driver already bundled with the Paperclip server.

import { createRequire } from 'module';
import crypto from 'crypto';

const require = createRequire(import.meta.url);

// Try to find pg from the server's dependencies
let Client;
try {
  Client = require('./server/node_modules/pg').Client;
} catch {
  try {
    Client = require('pg').Client;
  } catch {
    Client = require('./node_modules/pg').Client;
  }
}

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  console.error('ERROR: DATABASE_URL not set');
  process.exit(1);
}

const BASE_URL = process.env.PAPERCLIP_PUBLIC_URL || 'https://paperclip-7lyg.onrender.com';

const client = new Client({ connectionString: DATABASE_URL });
await client.connect();

// Revoke any existing pending bootstrap invites
await client.query(`
  UPDATE invites SET revoked_at = NOW(), updated_at = NOW()
  WHERE invite_type = 'bootstrap_ceo'
    AND revoked_at IS NULL
    AND accepted_at IS NULL
    AND expires_at > NOW()
`);

// Generate token
const tokenRandom = crypto.randomBytes(24).toString('hex');
const token = `pcp_bootstrap_${tokenRandom}`;
const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
const expiresAt = new Date(Date.now() + 72 * 60 * 60 * 1000).toISOString();

// Insert new bootstrap invite
await client.query(`
  INSERT INTO invites (id, invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id, created_at, updated_at)
  VALUES (gen_random_uuid(), 'bootstrap_ceo', $1, 'human', $2::timestamptz, 'system', NOW(), NOW())
`, [tokenHash, expiresAt]);

const inviteUrl = `${BASE_URL}/invite/${token}`;
console.log('');
console.log('=== BOOTSTRAP CEO INVITE ===');
console.log(`Invite URL: ${inviteUrl}`);
console.log(`Expires: ${expiresAt}`);
console.log('============================');
console.log('');

await client.end();
