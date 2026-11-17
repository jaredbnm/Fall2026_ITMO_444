const express = require('express')
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb')
const {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  ScanCommand
} = require('@aws-sdk/lib-dynamodb')
const app = express()
const PORT = process.env.PORT || 3000
const ZIP_API = process.env.ZIP_API_BASE || 'https://api.zippopotam.us'
const NWS_API = process.env.NWS_API_BASE || 'https://api.weather.gov'
// The National Weather Service asks every client to identify itself.
const USER_AGENT =
  process.env.NWS_USER_AGENT ||
  '(itmo-444-544 weather lab, student@example.com)'
// With no WEATHER_TABLE the service still works, it just does not store anything.
const TABLE = process.env.WEATHER_TABLE
const CACHE_SECONDS = Number(process.env.CACHE_SECONDS || 600)
const KEEP_SECONDS = 86400 // DynamoDB deletes saved lookups about a day after they were made
const DB_RETRY_MS = 30000 // after a database failure, leave the database alone for 30 seconds
// DYNAMODB_ENDPOINT is for local testing only. On EC2 the SDK finds the region and the role itself.
const ddb = DynamoDBDocumentClient.from(
  new DynamoDBClient({
    region: process.env.AWS_REGION,
    ...(process.env.DYNAMODB_ENDPOINT
      ? { endpoint: process.env.DYNAMODB_ENDPOINT }
      : {}),
    maxAttempts: 2
  })
)
const log = (event, fields = {}) =>
  console.log(
    JSON.stringify({ ts: new Date().toISOString(), event, ...fields })
  )
class UpstreamError extends Error {
  constructor (stage, status) {
    super(`${stage} failed`)
    this.stage = stage
    this.status = status
  }
}
// Fetch JSON with a timeout and one retry. Returns null on a 404, throws UpstreamError otherwise.
async function fetchJson (stage, url, headers = {}) {
  let status = 0
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const res = await fetch(url, {
        headers,
        signal: AbortSignal.timeout(8000)
      })
      status = res.status
      if (res.ok) return await res.json()
      if (res.status === 404) return null
      if (res.status < 500 && res.status !== 429) break // a client error will not fix itself
    } catch (err) {
      status = 0 // timeout or network failure
    }
    if (attempt < 2) await new Promise(resolve => setTimeout(resolve, 500))
  }
  throw new UpstreamError(stage, status)
}
// ---- Database helpers ------------------------------------------------------------------
let dbRetryAt = 0
// Run one database call. Any failure is logged, and the database is skipped for a short time,
// so a broken database costs each request nothing instead of a wait.
async function withDb (stage, fn) {
  if (!TABLE) return { state: 'disabled' }
  if (Date.now() < dbRetryAt) return { state: 'unavailable' }
  try {
    return { state: 'ok', value: await fn() }
  } catch (err) {
    dbRetryAt = Date.now() + DB_RETRY_MS
    log('db_error', { stage, message: err.name + ': ' + err.message })
    return { state: 'unavailable' }
  }
}
// One item per zip code: the newest lookup. Reading it is the cache check.
const findFresh = zip =>
  withDb('read', async () => {
    const r = await ddb.send(new GetCommand({ TableName: TABLE, Key: { zip } }))
    const item = r.Item
    if (item && Date.now() / 1000 - item.createdAt < CACHE_SECONDS)
      return item.payload
    return null
  })
const saveLookup = (zip, payload) =>
  withDb('write', () => {
    const now = Math.floor(Date.now() / 1000)
    return ddb.send(
      new PutCommand({
        TableName: TABLE,
        Item: { zip, payload, createdAt: now, expiresAt: now + KEEP_SECONDS }
      })
    )
  })
// ---- Routes ----------------------------------------------------------------------------
app.get('/', (req, res) => {
  res.json({
    service: 'weather',
    usage: '/weather?zip=60616',
    history: '/history'
  })
})
// The ten most recent lookups. The table is tiny, so a Scan and a sort is fine for this lab.
app.get('/history', async (req, res) => {
  const result = await withDb('history', async () => {
    const items = []
    let key
    do {
      const r = await ddb.send(
        new ScanCommand({
          TableName: TABLE,
          ExclusiveStartKey: key,
          Limit: 100
        })
      )
      items.push(...r.Items)
      key = r.LastEvaluatedKey
    } while (key && items.length < 500)
    return items
      .sort((a, b) => b.createdAt - a.createdAt)
      .slice(0, 10)
      .map(i => ({
        zip: i.zip,
        city: i.payload.city,
        state: i.payload.state,
        short_forecast: i.payload.forecast.shortForecast,
        temperature: i.payload.forecast.temperature,
        created_at: new Date(i.createdAt * 1000).toISOString()
      }))
  })
  if (result.state === 'disabled')
    return res.status(503).json({ error: 'database_disabled' })
  if (result.state === 'unavailable')
    return res.status(503).json({ error: 'database_unavailable' })
  return res.json({ count: result.value.length, lookups: result.value })
})
app.get('/weather', async (req, res) => {
  const zip = String(req.query.zip || '')
  if (!/^\d{5}$/.test(zip)) {
    log('weather_rejected', { reason: 'invalid_zip' })
    return res
      .status(400)
      .json({ error: 'invalid_zip', message: 'Give a 5 digit US zip code.' })
  }
  const started = Date.now()
  log('weather_request', { zip })
  // 0. Has anyone asked for this zip in the last few minutes? Then answer from DynamoDB.
  const cached = await findFresh(zip)
  if (cached.state === 'ok' && cached.value) {
    log('weather_success', { zip, cache: 'hit', ms: Date.now() - started })
    return res.json({ ...cached.value, cache: 'hit' })
  }
  try {
    // 1. The weather API wants coordinates, not zip codes, so look the zip code up first.
    const lookup = await fetchJson('zip_lookup', `${ZIP_API}/us/${zip}`)
    if (!lookup || !lookup.places || lookup.places.length === 0) {
      log('weather_rejected', { reason: 'zip_not_found', zip })
      return res.status(404).json({ error: 'zip_not_found' })
    }
    const place = lookup.places[0]
    const lat = Number(place.latitude).toFixed(4)
    const lon = Number(place.longitude).toFixed(4)
    // 2. Ask NWS which forecast grid covers those coordinates.
    const headers = { 'User-Agent': USER_AGENT, Accept: 'application/geo+json' }
    const point = await fetchJson(
      'nws_points',
      `${NWS_API}/points/${lat},${lon}`,
      headers
    )
    if (!point) {
      log('weather_rejected', { reason: 'no_nws_coverage', zip })
      return res.status(404).json({ error: 'no_nws_coverage' })
    }
    // 3. Fetch the forecast for that grid and keep the first period (now, or the next block).
    const forecast = await fetchJson(
      'nws_forecast',
      point.properties.forecast,
      headers
    )
    const period = forecast.properties.periods[0]
    const precip = period.probabilityOfPrecipitation
      ? period.probabilityOfPrecipitation.value
      : null
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
        isDaytime: period.isDaytime
      }
    }
    // 4. Keep a copy. This is both the cache for the next caller and the history.
    const saved = await saveLookup(zip, body)
    const cache = saved.state === 'ok' ? 'miss' : saved.state // 'miss', 'disabled' or 'unavailable'
    log('weather_success', { zip, cache, ms: Date.now() - started })
    return res.json({ ...body, cache })
  } catch (err) {
    if (err instanceof UpstreamError) {
      log('weather_error', { zip, stage: err.stage, status: err.status })
      return res.status(502).json({ error: 'upstream_error', stage: err.stage })
    }
    log('weather_error', { zip, stage: 'internal', message: err.message })
    return res.status(500).json({ error: 'internal_error' })
  }
})
app.listen(PORT, () =>
  log('weather_started', { port: PORT, table: TABLE || null })
)
