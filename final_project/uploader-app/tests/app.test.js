const test = require('node:test')
const assert = require('node:assert')
const http = require('node:http')
const {
  createApp,
  cleanText,
  parseResume,
  splitRuns,
  buildDocx,
  makeLimiter,
  UserError
} = require('../app.js')
const JOB =
  'We need a developer with Python, AWS and SQL. Experience with C++ is a plus.'
const GOOD = JSON.stringify({
  name: 'Ada Student',
  contact: ['Chicago, IL', 'ada@example.edu'],
  sections: [
    {
      title: 'education',
      entries: [
        {
          heading: 'Example University',
          location: 'Chicago, IL',
          subheading: 'BS Computer Science',
          dates: '2022 to 2026',
          bullets: ['Built a Python tool on AWS']
        }
      ],
      lines: []
    },
    { title: 'Skills', entries: [], lines: ['Technical: Python, SQL'] }
  ],
  keywords: ['Python', 'AWS', 'SQL', 'Kubernetes']
})
test('cleanText strips a BOM and control characters, and rejects bad files', () => {
  const text = cleanText(
    Buffer.from('Hello\r\nworld\u0007 ' + 'x'.repeat(60)),
    'resume'
  )
  assert.ok(text.startsWith('Hello\nworld'))
  assert.ok(!text.includes('\u0007'))
  assert.throws(() => cleanText(Buffer.from('short'), 'resume'), UserError)
  assert.throws(() => cleanText(Buffer.from([0, 1, 2, 3]), 'resume'), UserError)
  assert.throws(
    () => cleanText(Buffer.from('x'.repeat(30001)), 'resume'),
    e => e.status === 413
  )
})
test('parseResume accepts good output and upper-cases section titles', () => {
  const r = parseResume(GOOD, JOB)
  assert.strictEqual(r.name, 'Ada Student')
  assert.deepStrictEqual(
    r.sections.map(s => s.title),
    ['EDUCATION', 'SKILLS']
  )
})
test('parseResume drops keywords that are not in the job description', () => {
  assert.deepStrictEqual(parseResume(GOOD, JOB).keywords, [
    'Python',
    'AWS',
    'SQL'
  ])
})
test('parseResume accepts JSON wrapped in a code fence', () => {
  assert.ok(parseResume('```json\n' + GOOD + '\n```', JOB))
})
test('parseResume rejects unusable output', () => {
  assert.throws(() => parseResume('not json', JOB), /not_json/)
  assert.throws(
    () => parseResume('{"name":"A","sections":[]}', JOB),
    /no_sections/
  )
  assert.throws(
    () => parseResume('{"sections":[{"title":"X","lines":["a"]}]}', JOB),
    /missing_name/
  )
})
test('parseResume caps lengths and ignores wrong types', () => {
  const raw = JSON.stringify({
    name: 'N'.repeat(500),
    sections: [{ title: 'Skills', lines: ['a'.repeat(900), null] }]
  })
  const r = parseResume(raw, JOB)
  assert.strictEqual(r.name.length, 80)
  assert.strictEqual(r.sections[0].lines.length, 1)
  assert.strictEqual(r.sections[0].lines[0].length, 300)
})
test('splitRuns marks whole-word keywords only, ignoring case', () => {
  const runs = splitRuns('Wrote python and JavaScript, then C++ tools', [
    'Python',
    'Java',
    'C++'
  ])
  assert.deepStrictEqual(
    runs.filter(r => r.bold).map(r => r.text),
    ['python', 'C++']
  )
  assert.strictEqual(
    runs.map(r => r.text).join(''),
    'Wrote python and JavaScript, then C++ tools'
  )
})
test('buildDocx produces a real .docx (a zip file)', async () => {
  const buffer = await buildDocx(parseResume(GOOD, JOB))
  assert.strictEqual(buffer.subarray(0, 2).toString(), 'PK')
  assert.ok(buffer.length > 1000)
})
test('the limiter allows N hits per window, then recovers', () => {
  const allow = makeLimiter(2, 1000)
  assert.ok(allow('a', 0))
  assert.ok(allow('a', 1))
  assert.ok(!allow('a', 2))
  assert.ok(allow('b', 2))
  assert.ok(allow('a', 1500))
})
// ---- the whole POST /generate route, with fake S3 and a fake Gemini ----
function multipart (parts) {
  const boundary = '----t' + Math.random().toString(16).slice(2)
  const chunks = parts.map(
    p => `--${boundary}\r\nContent-Disposition: form-data; name="${p.name}";
filename="${p.filename}"\r\nContent-Type: ${p.type || 'text/plain'}\r\n\r\n${
      p.body
    }\r\n`
  )
  return {
    type: `multipart/form-data; boundary=${boundary}`,
    body: chunks.join('') + `--${boundary}--\r\n`
  }
}
async function post (app, parts) {
  const server = await new Promise(r => {
    const s = app.listen(0, () => r(s))
  })
  try {
    const { type, body } = multipart(parts)
    return await new Promise((resolve, reject) => {
      const req = http.request(
        {
          port: server.address().port,
          method: 'POST',
          path: '/generate',
          headers: {
            'Content-Type': type,
            'Content-Length': Buffer.byteLength(body),
            Host: 'myalb.example.com:8080'
          }
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
const RESUME_FILE = {
  name: 'resume',
  filename: 'r.txt',
  body: 'Ada Student. Built Python tools on AWS at a summer internship. '.repeat(
    3
  )
}
const JOB_FILE = { name: 'job', filename: 'j.txt', body: JOB.repeat(2) }
test('route: saves both files to S3 and redirects to the viewer', async () => {
  const puts = []
  const app = createApp({
    s3: {
      send: async c => {
        puts.push(c.input)
      }
    },
    askGemini: async () => GOOD
  })
  const res = await post(app, [RESUME_FILE, JOB_FILE])
  assert.strictEqual(res.status, 303)
  assert.match(
    res.headers.location,
    /^http:\/\/my-alb\.example\.com:8081\/resume\/[a-f0-9]{32}$/
  )
  assert.deepStrictEqual(puts.map(p => p.Key.split('.').pop()).sort(), [
    'docx',
    'json'
  ])
  assert.ok(puts.every(p => p.Key.startsWith('resumes/')))
})
test('route: a missing file is a 400 and Gemini is never called', async () => {
  let called = false
  const app = createApp({
    s3: { send: async () => {} },
    askGemini: async () => {
      called = true
      return GOOD
    }
  })
  const res = await post(app, [RESUME_FILE])
  assert.strictEqual(res.status, 400)
  assert.strictEqual(called, false)
})
test('route: a non-txt upload is refused', async () => {
  const app = createApp({
    s3: { send: async () => {} },
    askGemini: async () => GOOD
  })
  const res = await post(app, [
    { ...RESUME_FILE, filename: 'r.pdf', type: 'application/pdf' },
    JOB_FILE
  ])
  assert.strictEqual(res.status, 415)
})
test('route: Gemini quota errors and junk output become friendly pages', async () => {
  const quota = createApp({
    s3: { send: async () => {} },
    askGemini: async () => {
      const e = new Error('x')
      e.status = 429
      throw e
    }
  })
  assert.strictEqual((await post(quota, [RESUME_FILE, JOB_FILE])).status, 503)
  const junk = createApp({
    s3: { send: async () => {} },
    askGemini: async () => 'sorry, I cannot do that'
  })
  assert.strictEqual((await post(junk, [RESUME_FILE, JOB_FILE])).status, 502)
})
