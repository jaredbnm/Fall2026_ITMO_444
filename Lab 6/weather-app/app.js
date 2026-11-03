const fs = require('fs');
const express = require('express');
const { Pool } = require('pg');
const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');

const app = express();
const PORT = process.env.PORT || 3000;
const ZIP_API = process.env.ZIP_API_BASE || 'https://api.zippopotam.us';
const NWS_API = process.env.NWS_API_BASE || 'https://api.weather.gov';
// The National Weather Service asks every client to identify itself.
const USER_AGENT = process.env.NWS_USER_AGENT || '(itmo-444-544 weather lab, student@example.com)';

// Database settings. With no DB_HOST the service still works, it just does not store anything.
const DB_HOST = process.env.DB_HOST;
const DB_PORT = Number(process.env.DB_PORT || 5432);
const DB_NAME = process.env.DB_NAME || 'weather';
const DB_USER = process.env.DB_USER || 'weatherapp';
const DB_PASSWORD_PARAM = process.env.DB_PASSWORD_PARAM || '/itmo-444-544/db-password';
const DB_CA_FILE = process.env.DB_CA_FILE || '/opt/app/rds-ca.pem';
const CACHE_SECONDS = Number(process.env.CACHE_SECONDS || 600);
const DB_RETRY_MS = 30000; // after a database failure, leave the database alone for 30 seconds

const ssm = new SSMClient({ region: process.env.AWS_REGION });

const log = (event, fields = {}) =>
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, ...fields }));

class UpstreamError extends Error {
  constructor(stage, status) {
    super(`${stage} failed`);
    this.stage = stage;
    this.status = status;
  }
}

// Fetch JSON with a timeout and one retry. Returns null on a 404, throws UpstreamError otherwise.
async function fetchJson(stage, url, headers = {}) {
  let status = 0;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const res = await fetch(url, { headers, signal: AbortSignal.timeout(8000) });
      status = res.status;
      if (res.ok) return await res.json();
      if (res.status === 404) return null;
      if (res.status < 500 && res.status !== 429) break; // a client error will not fix itself
    } catch (err) {
      status = 0; // timeout or network failure
    }
    if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new UpstreamError(stage, status);
}

// ---- Database helpers ------------------------------------------------------------------

let poolPromise = null;
let dbRetryAt = 0;

async function readDbPassword() {
  if (process.env.DB_PASSWORD) return process.env.DB_PASSWORD; // local development only
  const out = await ssm.send(new GetParameterCommand({ Name: DB_PASSWORD_PARAM, WithDecryption: true }));
  return out.Parameter.Value;
}

async function createPool() {
  const password = await readDbPassword();
  // Verify the server certificate against the RDS CA bundle, so the connection is encrypted
  // and we know we are talking to RDS and not to something in the middle.
  const ssl = process.env.DB_SSL === 'off' ? false : { ca: fs.readFileSync(DB_CA_FILE, 'utf8') };
  const pool = new Pool({
    host: DB_HOST, port: DB_PORT, database: DB_NAME, user: DB_USER, password, ssl,
    max: 4, connectionTimeoutMillis: 3000, idleTimeoutMillis: 30000, statement_timeout: 3000,
  });
  pool.on('error', (err) => log('db_error', { stage: 'pool', message: err.message }));
  try {
    await pool.query(`CREATE TABLE IF NOT EXISTS lookups (
      id BIGSERIAL PRIMARY KEY,
      zip CHAR(5) NOT NULL,
      payload JSONB NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    await pool.query('CREATE INDEX IF NOT EXISTS lookups_zip_created ON lookups (zip, created_at DESC)');
  } catch (err) {
    await pool.end().catch(() => {});
    throw err;
  }
  return pool;
}

// Returns a ready pool, or throws. A failed attempt is not remembered, so the next try starts fresh.
function getPool() {
  if (!poolPromise) {
    poolPromise = createPool().catch((err) => {
      poolPromise = null;
      throw err;
    });
  }
  return poolPromise;
}

// Run one database call. Any failure is logged, and the database is skipped for a short time,
// so a broken database costs each request nothing instead of a 3 second wait.
async function withDb(stage, fn) {
  if (!DB_HOST) return { state: 'disabled' };
  if (Date.now() < dbRetryAt) return { state: 'unavailable' };
  try {
    return { state: 'ok', value: await fn(await getPool()) };
  } catch (err) {
    dbRetryAt = Date.now() + DB_RETRY_MS;
    log('db_error', { stage, message: err.message });
    return { state: 'unavailable' };
  }
}

const findFresh = (zip) => withDb('read', async (pool) => {
  const r = await pool.query(
    `SELECT payload FROM lookups
      WHERE zip = $1 AND created_at > now() - make_interval(secs => $2)
      ORDER BY created_at DESC LIMIT 1`, [zip, CACHE_SECONDS]);
  return r.rows.length ? r.rows[0].payload : null;
});

const saveLookup = (zip, payload) => withDb('write', (pool) =>
  pool.query('INSERT INTO lookups (zip, payload) VALUES ($1, $2)', [zip, JSON.stringify(payload)]));

// ---- Routes ----------------------------------------------------------------------------

app.get('/', (req, res) => {
  res.json({ service: 'weather', usage: '/weather?zip=60616', history: '/history' });
});

// The ten most recent lookups that were saved in the database.
app.get('/history', async (req, res) => {
  const result = await withDb('history', async (pool) => {
    const r = await pool.query(
      `SELECT id, zip, payload->>'city' AS city, payload->>'state' AS state,
              payload->'forecast'->>'shortForecast' AS short_forecast,
              payload->'forecast'->>'temperature' AS temperature, created_at
         FROM lookups ORDER BY created_at DESC LIMIT 10`);
    return r.rows;
  });
  if (result.state === 'disabled') return res.status(503).json({ error: 'database_disabled' });
  if (result.state === 'unavailable') return res.status(503).json({ error: 'database_unavailable' });
  return res.json({ count: result.value.length, lookups: result.value });
});

app.get('/weather', async (req, res) => {
  const zip = String(req.query.zip || '');
  if (!/^\d{5}$/.test(zip)) {
    log('weather_rejected', { reason: 'invalid_zip' });
    return res.status(400).json({ error: 'invalid_zip', message: 'Give a 5 digit US zip code.' });
  }

  const started = Date.now();
  log('weather_request', { zip });

  // 0. Has anyone asked for this zip in the last few minutes? Then answer from the database.
  const cached = await findFresh(zip);
  if (cached.state === 'ok' && cached.value) {
    log('weather_success', { zip, cache: 'hit', ms: Date.now() - started });
    return res.json({ ...cached.value, cache: 'hit' });
  }

  try {
    // 1. The weather API wants coordinates, not zip codes, so look the zip code up first.
    const lookup = await fetchJson('zip_lookup', `${ZIP_API}/us/${zip}`);
    if (!lookup || !lookup.places || lookup.places.length === 0) {
      log('weather_rejected', { reason: 'zip_not_found', zip });
      return res.status(404).json({ error: 'zip_not_found' });
    }
    const place = lookup.places[0];
    const lat = Number(place.latitude).toFixed(4);
    const lon = Number(place.longitude).toFixed(4);

    // 2. Ask NWS which forecast grid covers those coordinates.
    const headers = { 'User-Agent': USER_AGENT, Accept: 'application/geo+json' };
    const point = await fetchJson('nws_points', `${NWS_API}/points/${lat},${lon}`, headers);
    if (!point) {
      log('weather_rejected', { reason: 'no_nws_coverage', zip });
      return res.status(404).json({ error: 'no_nws_coverage' });
    }

    // 3. Fetch the forecast for that grid and keep the first period (now, or the next block).
    const forecast = await fetchJson('nws_forecast', point.properties.forecast, headers);
    const period = forecast.properties.periods[0];
    const precip = period.probabilityOfPrecipitation ? period.probabilityOfPrecipitation.value : null;

    const body = {
      zip,
      city: place['place name'],
      state: place['state abbreviation'],
      latitude: lat,
      longitude: lon,
      forecast: {
        name: period.name,
        temperature: period.temperature,
        temperatureUnit: period.temperatureUnit,
        shortForecast: period.shortForecast,
        windSpeed: period.windSpeed,
        precipitationChance: precip,
        isDaytime: period.isDaytime,
      },
    };

    // 4. Keep a copy. This is both the cache for the next caller and the history table.
    const saved = await saveLookup(zip, body);
    const cache = saved.state === 'ok' ? 'miss' : saved.state; // 'miss', 'disabled' or 'unavailable'
    log('weather_success', { zip, cache, ms: Date.now() - started });
    return res.json({ ...body, cache });
  } catch (err) {
    if (err instanceof UpstreamError) {
      log('weather_error', { zip, stage: err.stage, status: err.status });
      return res.status(502).json({ error: 'upstream_error', stage: err.stage });
    }
    log('weather_error', { zip, stage: 'internal', message: err.message });
    return res.status(500).json({ error: 'internal_error' });
  }
});

app.listen(PORT, () => log('weather_started', { port: PORT }));