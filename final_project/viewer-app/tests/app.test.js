const test = require('node:test')
const assert = require('node:assert')
const http = require('node:http')
const {
  createApp,
  highlight,
  renderResume,
  emailResumeLink,
  makeLimiter,
  EMAIL_PATTERN
} = require('../app.js')
process.env.SNS_TOPIC_ARN =
  process.env.SNS_TOPIC_ARN ||
  'arn:aws:sns:us-east-2:111122223333:resume-mailer'
const ID = 'a'.repeat(32)
const RESUME = {
  name: 'Ada <b>Student</b>',
  contact: ['ada@example.edu'],
  keywords: ['Python', 'AWS'],
  sections: [
    {
      title: 'EXPERIENCE',
      lines: ['Skills: <script>alert(1)</script> Python'],
      entries: [
        {
          heading: 'Acme',
          location: 'Chicago, IL',
          subheading: 'Intern',
          dates: '2025',
          bullets: ['Built Python tools on AWS']
        }
      ]
    }
  ]
}
test('highlight bolds whole-word keywords and escapes everything else', () => {
  assert.strictEqual(
    highlight('Used python & JavaScript', ['Python', 'Java']),
    'Used <strong>python</strong> &amp; JavaScript'
  )
})
test('renderResume cannot be used to inject HTML', () => {
  const html = renderResume(RESUME)
  assert.ok(!html.includes('<script>'))
  assert.ok(!html.includes('<b>Student'))
  assert.match(html, /&lt;script&gt;/)
  assert.match(html, /<strong>Python<\/strong> tools on <strong>AWS<\/strong>/)
})
test('email addresses are validated', () => {
  for (const ok of ['a@b.co', 'first.last+tag@school.edu'])
    assert.ok(EMAIL_PATTERN.test(ok), ok)
  for (const bad of ['', 'a', 'a@b', 'a b@c.com', '<x>@y.com', 'a@b.c"d'])
    assert.ok(!EMAIL_PATTERN.test(bad), bad)
})
// A fake SNS that remembers subscriptions and what was published.
function fakeSns (existing = []) {
  const state = { subs: [...existing], subscribed: [], published: [] }
  return Object.assign(state, {
    send: async cmd => {
      const name = cmd.constructor.name,
        i = cmd.input
      if (name === 'ListSubscriptionsByTopicCommand')
        return { Subscriptions: state.subs }
      if (name === 'SubscribeCommand') {
        state.subscribed.push(i)
        return {}
      }
      if (name === 'PublishCommand') {
        state.published.push(i)
        return {}
      }
      throw new Error('unexpected ' + name)
    }
  })
}
test('first use of an address requests a confirmation and publishes nothing', async () => {
  const sns = fakeSns()
  assert.strictEqual(
    await emailResumeLink(sns, 'a@b.com', 'https://x'),
    'confirmation_requested'
  )
  assert.strictEqual(sns.subscribed[0].Endpoint, 'a@b.com')
  assert.deepStrictEqual(
    JSON.parse(sns.subscribed[0].Attributes.FilterPolicy),
    { recipient: ['a@b.com'] }
  )
  assert.strictEqual(sns.published.length, 0)
})
test('a pending subscription publishes nothing', async () => {
  const sns = fakeSns([
    {
      Protocol: 'email',
      Endpoint: 'A@B.com',
      SubscriptionArn: 'PendingConfirmation'
    }
  ])
  assert.strictEqual(
    await emailResumeLink(sns, 'a@b.com', 'https://x'),
    'waiting_for_confirmation'
  )
  assert.strictEqual(sns.published.length + sns.subscribed.length, 0)
})
test('a confirmed address gets the link, addressed by the recipient attribute', async () => {
  const sns = fakeSns([
    {
      Protocol: 'email',
      Endpoint: 'a@b.com',
      SubscriptionArn: 'arn:aws:sns:x:1:t:abc'
    }
  ])
  assert.strictEqual(
    await emailResumeLink(sns, 'a@b.com', 'https://download.example/file'),
    'sent'
  )
  const p = sns.published[0]
  assert.ok(p.Message.includes('https://download.example/file'))
  assert.deepStrictEqual(p.MessageAttributes.recipient, {
    DataType: 'String',
    StringValue: 'a@b.com'
  })
  assert.ok(p.Subject.length <= 100 && /^[\x20-\x7E]+$/.test(p.Subject))
})
test('the limiter blocks the seventh request in an hour', () => {
  const allow = makeLimiter(6, 3600000)
  for (let i = 0; i < 6; i++) assert.ok(allow('ip', i))
  assert.ok(!allow('ip', 10))
})
// ---- routes with a fake S3 ----
async function request (app, method, path, body) {
  const server = await new Promise(r => {
    const s = app.listen(0, () => r(s))
  })
  try {
    return await new Promise((resolve, reject) => {
      const req = http.request(
        {
          port: server.address().port,
          method,
          path,
          headers: body
            ? {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Content-Length': Buffer.byteLength(body)
              }
            : {}
        },
        res => {
          let d = ''
          res.on('data', c => {
            d += c
          })
          res.on('end', () =>
            resolve({ status: res.statusCode, headers: res.headers, body: d })
          )
        }
      )
      req.on('error', reject)
      req.end(body)
    })
  } finally {
    server.close()
  }
}
const s3With = resume => ({
  send: async () => {
    if (!resume) {
      const e = new Error('denied')
      e.name = 'AccessDenied'
      throw e
    }
    return { Body: { transformToString: async () => JSON.stringify(resume) } }
  }
})
const presign = async (c, cmd, seconds) =>
  `https://signed.example/${cmd.input.Key}?ttl=${seconds}`
test('route: bad ids are 404 before S3 is touched', async () => {
  let touched = false
  const app = createApp({
    s3: {
      send: async () => {
        touched = true
      }
    },
    sns: fakeSns(),
    presign
  })
  assert.strictEqual(
    (await request(app, 'GET', '/resume/..%2Fsecret')).status,
    404
  )
  assert.strictEqual((await request(app, 'GET', '/resume/short')).status, 404)
  assert.strictEqual(touched, false)
})
test('route: a missing resume is a 404, and a found one is drawn', async () => {
  assert.strictEqual(
    (
      await request(
        createApp({ s3: s3With(null), sns: fakeSns(), presign }),
        'GET',
        `/resume/${ID}`
      )
    ).status,
    404
  )
  const ok = await request(
    createApp({ s3: s3With(RESUME), sns: fakeSns(), presign }),
    'GET',
    `/resume/${ID}`
  )
  assert.strictEqual(ok.status, 200)
  assert.match(ok.body, /Download \.docx/)
})
test('route: download redirects to a short-lived signed link', async () => {
  const res = await request(
    createApp({ s3: s3With(RESUME), sns: fakeSns(), presign }),
    'GET',
    `/resume/${ID}/download`
  )
  assert.strictEqual(res.status, 302)
  assert.match(
    res.headers.location,
    new RegExp(`resumes/${ID}\\.docx\\?ttl=300`)
  )
})
test('route: email publishes a one hour link for a confirmed address', async () => {
  const sns = fakeSns([
    {
      Protocol: 'email',
      Endpoint: 'a@b.com',
      SubscriptionArn: 'arn:aws:sns:x:1:t:abc'
    }
  ])
  const res = await request(
    createApp({ s3: s3With(RESUME), sns, presign }),
    'POST',
    `/resume/${ID}/email`,
    'email=A%40B.com'
  )
  assert.strictEqual(res.status, 200)
  assert.ok(sns.published[0].Message.includes('ttl=3600'))
})
test('route: an invalid address is a 400 and SNS is never called', async () => {
  const sns = fakeSns()
  const res = await request(
    createApp({ s3: s3With(RESUME), sns, presign }),
    'POST',
    `/resume/${ID}/email`,
    'email=nope'
  )
  assert.strictEqual(res.status, 400)
  assert.strictEqual(sns.subscribed.length + sns.published.length, 0)
})
test('route: an SNS failure is a friendly page, not a crash', async () => {
  const sns = {
    send: async () => {
      throw new Error('boom')
    }
  }
  const res = await request(
    createApp({ s3: s3With(RESUME), sns, presign }),
    'POST',
    `/resume/${ID}/email`,
    'email=a%40b.com'
  )
  assert.strictEqual(res.status, 502)
})
