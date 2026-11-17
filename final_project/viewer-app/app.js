// Resume viewer (tier 2): shows the finished resume, lets you download the .docx, and emails a
// download link to your inbox through Amazon SNS.
const express = require('express')
const { S3Client, GetObjectCommand } = require('@aws-sdk/client-s3')
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner')
const {
  SNSClient,
  SubscribeCommand,
  PublishCommand,
  ListSubscriptionsByTopicCommand
} = require('@aws-sdk/client-sns')
const PORT = process.env.PORT || 3000
const BUCKET = process.env.BUCKET_NAME
const TOPIC_ARN = process.env.SNS_TOPIC_ARN
const LINK_SECONDS = 3600 // how long the emailed download link works
const ID_PATTERN = /^[a-f0-9]{32}$/
const EMAIL_PATTERN = /^[^\s@<>"']+@[^\s@<>"']+\.[^\s@<>"']+$/
const log = (event, fields = {}) =>
  console.log(
    JSON.stringify({ ts: new Date().toISOString(), event, ...fields })
  )
const esc = s =>
  String(s).replace(
    /[&<>"']/g,
    c =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[
        c
      ])
  )
function makeLimiter (max, windowMs) {
  const hits = new Map()
  return function allow (key, now = Date.now()) {
    const recent = (hits.get(key) || []).filter(t => now - t < windowMs)
    if (recent.length >= max) {
      hits.set(key, recent)
      return false
    }
    recent.push(now)
    hits.set(key, recent)
    if (hits.size > 5000) hits.clear()
    return true
  }
}
// ---- drawing the resume as HTML ---------------------------------------------------------
const escapeRegExp = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
// Escapes the text and wraps each key word in <strong>. The escaping happens FIRST on each piece,
// so text that came from the AI service can never add tags to the page.
function highlight (text, keywords) {
  if (!keywords.length) return esc(text)
  const words = [...keywords]
    .sort((a, b) => b.length - a.length)
    .map(escapeRegExp)
    .join('|')
  const pattern = new RegExp(`(?<![A-Za-z0-9])(${words})(?![A-Za-z0-9])`, 'gi')
  return text
    .split(pattern)
    .filter(p => p !== '')
    .map(p =>
      keywords.some(k => k.toLowerCase() === p.toLowerCase())
        ? `<strong>${esc(p)}</strong>`
        : esc(p)
    )
    .join('')
}
function renderResume (r) {
  const kw = r.keywords || []
  const parts = [`<h1 class="name">${esc(r.name)}</h1>`]
  if (r.contact.length)
    parts.push(
      `<p class="contact">${r.contact.map(esc).join(' &nbsp;|&nbsp; ')}</p>`
    )
  for (const s of r.sections) {
    parts.push(`<h2>${esc(s.title)}</h2>`)
    for (const e of s.entries) {
      parts.push(
        `<div class="row"><b>${esc(e.heading)}</b><b>${esc(
          e.location
        )}</b></div>`
      )
      parts.push(
        `<div class="row"><i>${esc(e.subheading)}</i><span>${esc(
          e.dates
        )}</span></div>`
      )
      if (e.bullets.length)
        parts.push(`<ul>${e.bullets
          .map(b => `<li>${highlight(b, kw)}</li>`)
          .join('')}
</ul>`)
    }
    for (const l of s.lines)
      parts.push(`<p class="line">${highlight(l, kw)}</p>`)
  }
  return parts.join('\n')
}
const STYLE = `
body { font-family: system-ui, sans-serif; background: #eef0f3; margin: 0; color: #222; }
.bar { max-width: 8.5in; margin: 1rem auto; padding: 0 .5rem; }
.paper { max-width: 7in; margin: 0 auto 1rem; background: #fff; padding: .75in; box-shadow: 0 1px 6px #0003;
font-family: 'Times New Roman', Times, serif; font-size: 11pt; line-height: 1.25; }
.name { text-align: center; font-size: 15pt; margin: 0; letter-spacing: .5px; text-transform: uppercase; }
.contact { text-align: center; font-size: 10pt; margin: .2rem 0 .5rem; }
h2 { font-size: 11pt; margin: .9rem 0 .3rem; border-bottom: 1px solid #000; text-transform: uppercase; }
.row { display: flex; justify-content: space-between; gap: 1rem; margin-top: .2rem; }
ul { margin: .15rem 0 .2rem 1.1rem; padding: 0; } li { margin: 0; }
.line { margin: .1rem 0; }
.panel { background: #fff; padding: 1rem 1.2rem; border-radius: 6px; margin-bottom: 1rem; }
.panel input[type=email] { width: 18rem; max-width: 100%; padding: .45rem; font-size: 1rem; }
button, .btn { padding: .5rem 1.1rem; font-size: 1rem; cursor: pointer; text-decoration: none;
background: #1f4e79; color: #fff; border: 0; border-radius: 4px; display: inline-block; }
.msg { padding: .7rem 1rem; border-radius: 6px; margin-bottom: 1rem; background: #e8f3e8; border: 1px solid
#a8cfa8; }
.msg.bad { background: #fde8e8; border-color: #e0a0a0; }
.note { color: #555; font-size: .9rem; }
@media print { body { background: #fff; } .bar { display: none; } .paper { box-shadow: none; padding: 0;
margin: 0; } }`
function resumePage (id, resume, message) {
  const msg = message
    ? `<div class="msg ${message.bad ? 'bad' : ''}">${esc(message.text)}</div>`
    : ''
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Your resume</title>
<style>${STYLE}</style></head><body>
<div class="bar">
${msg}
<div class="panel">
<a class="btn" href="/resume/${id}/download">Download .docx</a>
<form method="POST" action="/resume/${id}/email" style="margin-top:1rem">
<label for="email"><b>Email me the file</b></label><br>
<input id="email" type="email" name="email" placeholder="you@example.com" required maxlength="254">
<button type="submit">Send</button>
<p class="note">The email contains a download link that works for 1 hour. The first time you use an
address, Amazon SNS sends a confirmation email first. Click Confirm in it, then press Send again.</p>
</form>
</div>
</div>
<div class="paper">${renderResume(resume)}</div>
<p class="note" style="text-align:center">Drafted by an AI service from your resume. Check every line before you
send it to anyone.</p>
</body></html>`
}
const simplePage = (
  title,
  text
) => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(
  title
)}</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem}</style></head>
<body><h1>${esc(title)}</h1><p>${esc(text)}</p></body></html>`
// ---- emailing through SNS ---------------------------------------------------------------
// SNS delivers plain text only: it cannot attach files. So the email carries a link to the .docx.
// One topic serves every visitor. To keep one person's link out of another person's inbox, each
// subscription has a filter policy ({"recipient": ["their address"]}) and every message is
// published with a matching "recipient" attribute.
async function findSubscription (sns, email) {
  let token
  do {
    const page = await sns.send(
      new ListSubscriptionsByTopicCommand({
        TopicArn: TOPIC_ARN,
        NextToken: token
      })
    )
    const hit = (page.Subscriptions || []).find(
      s => s.Protocol === 'email' && String(s.Endpoint).toLowerCase === email
    )
    if (hit) return hit
    token = page.NextToken
  } while (token)
  return null
}
// Returns 'sent', 'confirmation_requested' or 'waiting_for_confirmation'.
async function emailResumeLink (sns, email, url) {
  const sub = await findSubscription(sns, email)
  if (!sub) {
    await sns.send(
      new SubscribeCommand({
        TopicArn: TOPIC_ARN,
        Protocol: 'email',
        Endpoint: email,
        ReturnSubscriptionArn: true,
        Attributes: { FilterPolicy: JSON.stringify({ recipient: [email] }) }
      })
    )
    return 'confirmation_requested'
  }
  if (sub.SubscriptionArn === 'PendingConfirmation')
    return 'waiting_for_confirmation'
  await sns.send(
    new PublishCommand({
      TopicArn: TOPIC_ARN,
      Subject: 'Your Harvard style resume',
      Message:
        `Hello,\n\nYour resume is ready. Download it here (the link works for 1 hour):\n\n${url}\n\n` +
        'The text was drafted by an AI service from the resume you uploaded. Please check every line before you use it.\n',
      MessageAttributes: {
        recipient: { DataType: 'String', StringValue: email }
      }
    })
  )
  return 'sent'
}
// ---- the web app ------------------------------------------------------------------------
function createApp (deps = {}) {
  const s3 = deps.s3 || new S3Client({ region: process.env.AWS_REGION })
  const sns = deps.sns || new SNSClient({ region: process.env.AWS_REGION })
  const presign =
    deps.presign ||
    ((client, command, seconds) =>
      getSignedUrl(client, command, { expiresIn: seconds }))
  const emailLimit = makeLimiter(6, 60 * 60 * 1000) // 6 email requests per hour for each visitor
  const docxUrl = (id, seconds) =>
    presign(
      s3,
      new GetObjectCommand({
        Bucket: BUCKET,
        Key: `resumes/${id}.docx`,
        ResponseContentDisposition: 'attachment; filename="resume.docx"'
      }),
      seconds
    )
  async function loadResume (id) {
    try {
      const out = await s3.send(
        new GetObjectCommand({ Bucket: BUCKET, Key: `resumes/${id}.json` })
      )
      return JSON.parse(await out.Body.transformToString())
    } catch (e) {
      // Without s3:ListBucket, S3 answers a missing key with AccessDenied. Treat both as "not found".
      if (
        e.name === 'NoSuchKey' ||
        e.name === 'AccessDenied' ||
        e.$metadata?.httpStatusCode === 404
      )
        return
      null
      throw e
    }
  }
  const app = express()
  app.disable('x-powered-by')
  app.set('trust proxy', 1)
  app.use((req, res, next) => {
    res.set('X-Content-Type-Options', 'nosniff')
    res.set(
      'Content-Security-Policy',
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"
    )
    next()
  })
  app.use(express.urlencoded({ extended: false, limit: '2kb' }))
  app.get('/', (req, res) =>
    res.send(
      simplePage(
        'Resume viewer',
        'Build a resume with the uploader first. You will be sent here automatically.'
      )
    )
  )
  app.param('id', (req, res, next, id) => {
    if (!ID_PATTERN.test(id))
      return res
        .status(404)
        .send(simplePage('Not found', 'That resume does not exist.'))
    next()
  })
  const notFound = res =>
    res
      .status(404)
      .send(
        simplePage('Not found', 'That resume does not exist or has expired.')
      )
  app.get('/resume/:id', async (req, res) => {
    try {
      const resume = await loadResume(req.params.id)
      if (!resume) return notFound(res)
      res.send(resumePage(req.params.id, resume))
    } catch (e) {
      log('error', { stage: 'view', message: e.message })
      res
        .status(500)
        .send(simplePage('Something went wrong', 'Please try again.'))
    }
  })
  app.get('/resume/:id/download', async (req, res) => {
    try {
      if (!(await loadResume(req.params.id))) return notFound(res)
      res.redirect(302, await docxUrl(req.params.id, 300))
    } catch (e) {
      log('error', { stage: 'download', message: e.message })
      res
        .status(500)
        .send(simplePage('Something went wrong', 'Please try again.'))
    }
  })
  app.post('/resume/:id/email', async (req, res) => {
    const id = req.params.id
    const show = async (status, text, bad = false) => {
      const resume = await loadResume(id)
      if (!resume) return notFound(res)
      return res.status(status).send(resumePage(id, resume, { text, bad }))
    }
    try {
      const email = String((req.body && req.body.email) || '')
        .trim()
        .toLowerCase()
      if (email.length > 254 || !EMAIL_PATTERN.test(email))
        return await show(400, 'Please enter a valid email address.', true)
      if (!emailLimit(req.ip))
        return await show(
          429,
          'Too many email requests. Please try again later.',
          true
        )
      const url = await docxUrl(id, LINK_SECONDS)
      const result = await emailResumeLink(sns, email, url)
      log('email_request', { result })
      const text = {
        sent: `Sent. Check the inbox of ${email} (and the spam folder) for a message from Amazon SNS.`,
        confirmation_requested: `We asked Amazon SNS to confirm ${email}. Open that email, click "Confirm
subscription", then press Send again here.`,
        waiting_for_confirmation: `${email} has not been confirmed yet. Open the confirmation email from Amazon
SNS, click "Confirm subscription", then press Send again.`
      }[result]
      return await show(200, text)
    } catch (e) {
      log('error', { stage: 'email', message: e.name + ': ' + e.message })
      return show(
        502,
        'The email could not be sent. Please try again in a minute.',
        true
      ).catch(() => res.status(500).end())
    }
  })
  return app
}
if (require.main === module) {
  createApp().listen(PORT, () =>
    log('viewer_started', { port: PORT, topic: TOPIC_ARN })
  )
}
module.exports = {
  createApp,
  highlight,
  renderResume,
  emailResumeLink,
  makeLimiter,
  EMAIL_PATTERN
}
