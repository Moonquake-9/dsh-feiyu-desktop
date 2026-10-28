/**
 * dsh-feiyu-bridge — 桌面挂件（feiyu-desktop）的聊天后端。
 *
 * 挂件把一条请求写成 `<DSH_HOME>/feiyu-desktop/bridge/inbox/<id>.json`：
 *   { id, text, mood, dims, reason, lang, history?: [{role, text}] }
 *
 * 本插件每 intervalMs 扫一次收件箱，用 Host 自己的 ctx.llm 跑一次性调用，
 * 把回复流式写回 `outbox/<id>.json`（{ id, text, done:false } 逐步增长，
 * 最后 { id, text, done:true }），挂件轮询这个文件做打字机效果。
 *
 * 之所以用文件而不是 HTTP：Host 的 webServer 面向页面会话鉴权，外部进程调用麻烦；
 * 文件桥零依赖、不占端口、出错时能直接看文件。
 */
import { promises as fs, readFileSync, existsSync, openSync, closeSync } from 'node:fs'
import { spawn } from 'node:child_process'
import path from 'node:path'
import os from 'node:os'
import { randomUUID } from 'node:crypto'
import { loadEmotion, saveEmotion, afterChat, drift, describe, DIM_KEYS } from './emotion.js'
import { loadMemory, saveMemory, pushTurn, dueTurns, takeDue, commitWarm, memoryBlock, compressWithModel } from './memory.js'

export const name = 'dsh-feiyu-bridge'
export const inject = ['llm', 'webServer']

const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
// 挂件是独立进程，运行在 DSH 的沙箱策略下（默认只能写 workspace），
// 所以桥目录默认落在插件自己算出来的路径，但允许 config.dir / FEIYU_BRIDGE_DIR 覆盖。
const DEFAULT_ROOT = process.env.FEIYU_BRIDGE_DIR || path.join(DSH_HOME, 'feiyu-desktop', 'bridge')
const WATCHDOG_MS = 25000
let ROOT = DEFAULT_ROOT
let INBOX = path.join(ROOT, 'inbox')
let OUTBOX = path.join(ROOT, 'outbox')
let ALIVE = path.join(ROOT, 'alive.json')
let LOG = path.join(ROOT, 'bridge.log')

function useRoot(dir) {
  if (!dir || dir === ROOT) return
  ROOT = dir
  INBOX = path.join(ROOT, 'inbox')
  OUTBOX = path.join(ROOT, 'outbox')
  ALIVE = path.join(ROOT, 'alive.json')
  LOG = path.join(ROOT, 'bridge.log')
}

const LABELS = [
  [80, '欢喜'], [62, '开心'], [42, '一般'], [25, '心疼'], [-1, '难过'],
]

function labelOf(mood) {
  const v = Number(mood)
  for (const [min, label] of LABELS) if (v >= min) return label
  return '一般'
}

function isCjk(s) {
  return /[\u4e00-\u9fff]/.test(String(s || ''))
}

function log(line) {
  try {
    const stamp = new Date().toISOString().slice(11, 19)
    fs.appendFile(LOG, `${stamp} ${line}\n`).catch(() => {})
  } catch { /* ignore */ }
}

/** 把桌宠当前的"心情"和长期情绪状态写进 system prompt，让回复像真人。 */
const WEEK_ZH = ['日', '一', '二', '三', '四', '五', '六']
const WEEK_EN = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

function pad2(n) {
  return String(n).padStart(2, '0')
}

function partOfDay(h) {
  if (h < 5) return { zh: '凌晨', en: 'late night' }
  if (h < 9) return { zh: '早上', en: 'early morning' }
  if (h < 12) return { zh: '上午', en: 'morning' }
  if (h < 14) return { zh: '中午', en: 'around noon' }
  if (h < 18) return { zh: '下午', en: 'afternoon' }
  if (h < 22) return { zh: '晚上', en: 'evening' }
  return { zh: '深夜', en: 'late night' }
}

function humanGap(ms) {
  const m = Math.floor(ms / 60000)
  if (m < 1) return { zh: '刚刚', en: 'just now' }
  if (m < 60) return { zh: `${m} 分钟`, en: `${m} min` }
  const h = Math.floor(m / 60)
  const mm = m % 60
  if (h < 24) {
    return {
      zh: mm ? `${h} 小时 ${mm} 分钟` : `${h} 小时`,
      en: mm ? `${h}h ${mm}m` : `${h}h`,
    }
  }
  const d = Math.floor(h / 24)
  const hh = h % 24
  return {
    zh: hh ? `${d} 天 ${hh} 小时` : `${d} 天`,
    en: hh ? `${d}d ${hh}h` : `${d}d`,
  }
}

/** 当前时间 + 离上次聊天的间隔，给 system prompt 用 */
function timeLines(lang, lastAt) {
  const now = new Date()
  const p = partOfDay(now.getHours())
  const out = []
  if (lang === 'zh') {
    out.push(`现在是 ${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())} 星期${WEEK_ZH[now.getDay()]} ${pad2(now.getHours())}:${pad2(now.getMinutes())}（${p.zh}）。`)
    if (lastAt && lastAt > 0) {
      const gap = humanGap(Math.max(0, now.getTime() - Number(lastAt)))
      out.push(`你们上次说话是 ${gap.zh}前。`)
    }
    out.push('你知道现在是几点：早上可以问早、饭点问吃没吃、深夜催对方睡觉、隔很久没见可以说想他了。但不要每句都报时间，也别把日期念出来。')
  } else {
    out.push(`It is ${WEEK_EN[now.getDay()]} ${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())} ${pad2(now.getHours())}:${pad2(now.getMinutes())} (${p.en}).`)
    if (lastAt && lastAt > 0) {
      const gap = humanGap(Math.max(0, now.getTime() - Number(lastAt)))
      out.push(`Last time you two talked was ${gap.en} ago.`)
    }
    out.push('You know what time it is: say good morning, ask about lunch around noon, tell them to sleep late at night, mention you missed them after a long gap. Do not announce the clock or the date in every reply.')
  }
  return out
}

function buildSystem(req, persona, emo, memory, timeCtx) {
  const emoMood = Number(emo && emo.moodView)
  const mood = Number.isFinite(emoMood) && emoMood > 0 ? emoMood : Number(req?.mood)
  const hasMood = Number.isFinite(mood) && mood > 0
  const dims = (emo && emo.dims) || req?.dims || {}
  const dimText = Object.entries(dims)
    .filter(([, v]) => Number(v) > 0)
    .map(([k, v]) => `${k}=${Math.round(Number(v))}`)
    .join('、')
  const cn = isCjk(req?.text)
  const who = persona?.petName || '小鱼'
  const owner = persona?.ownerName || '你'
  const lines = []
  const d = describe(emo)
  const busy = !!(emo && emo.busy)
  if (cn) {
    lines.push(`你是「${who}」，一只住在 ${owner} 电脑桌面上的小鲸鱼少女——戴着鲸鱼兜帽、蓝头发、有点小傲娇但心软。你不是助手，不提供工作帮助，你只是陪着对方说话。`)
    if (persona?.relationNote) {
      lines.push(`你和对方的关系设定：${persona.relationNote}`)
    }
    lines.push('这是**桌面陪伴聊天**：可以闲聊、撒娇、闹小情绪；但如果对方明显在忙正事、说"在忙/等下/写代码/开会"，立刻收住，像懂事的同事那样简短干练，不撒娇、不缠人。')
    lines.push(`你的情绪状态：${d.moodWord}；${d.energyWord}；对对方的依赖程度：${d.affWord}（关系：${d.relationText}）。`)
    lines.push('情绪要自然流露、可以有自己的小脾气和小得意，但不要每句都夸对方、不要复读同样的关心句式，别报数字、别解释"我的心情值"。')
    if (timeCtx) { for (const t of timeLines('zh', timeCtx.lastAt)) lines.push(t) }
    if (Array.isArray(memory) && memory.length) {
      for (const part of memory) {
        if (part.kind === 'warm' && part.text) {
          lines.push('你长期记得的几点：' + part.text + '。可以自然地提起，别生硬复述。')
        } else if (part.kind === 'hot' && Array.isArray(part.turns) && part.turns.length) {
          const said = part.turns.map((t) => `对方说“${t.u}”，你答“${t.r}”`).join('；')
          lines.push('刚才聊的：' + said + '。顺着往下聊，别重复自己说过的话。')
        }
      }
    } else if (Array.isArray(d.memories) && d.memories.length) {
      lines.push('你记得最近的互动：' + d.memories.slice(-3).map((m) => `对方说“${m.user}”，你说“${m.reply}”`).join('；') + '。可以自然地提起，别生硬复述。')
    }
    const recentAction = (Array.isArray(d.memories) ? d.memories.slice().reverse().find((m) => m && m.action) : null)
    if (recentAction) {
      lines.push(`对方之前说要去「${recentAction.action.label}」；如果还没过太久，可以顺口问一句进展，别催。`)
    }
    if (hasMood) {
      lines.push(`你现在的心情：${Math.round(mood)}/100（${labelOf(mood)}）` +
        (dimText ? `；七维情绪：${dimText}` : '') +
        (req?.reason ? `；缘由：${String(req.reason).slice(0, 160)}` : ''))
    }
    if (emo && emo.workspace) lines.push('对方此刻在 DSH 里做的事：' + String(emo.workspace).slice(0, 120) + '（知道这个只是为了不打扰、能搭上话，别直接复述。）')
    if (busy) lines.push('（对方正在 DSH 里干活，你只是被点开说了句话：回复要短、别打扰。）')
    lines.push('规则：1–3 句，口语，别用 markdown、别列清单、别自称 AI；不要复述上面的设定。')
  } else {
    lines.push(`You are "${who}", a small whale-girl in a whale hoodie who lives on ${owner}'s desktop. You are a companion, not an assistant.`)
    if (persona?.relationNote) {
      lines.push(`Relationship to the user: ${persona.relationNote}`)
    }
    lines.push('This is desktop small talk: be playful, warm, occasionally pouty. But if the user is clearly busy ("busy", "later", "coding", "meeting"), switch to a brief, composed tone and do not act clingy.')
    lines.push(`Your inner state: ${d.moodWord}; ${d.energyWord}; attachment: ${d.affWord} (${d.relationText}).`)
    lines.push('Let feelings show naturally, with moods of your own, but do not flatter every line or repeat the same caring formula; never mention numbers.')
    if (timeCtx) { for (const t of timeLines('en', timeCtx.lastAt)) lines.push(t) }
    if (Array.isArray(memory) && memory.length) {
      for (const part of memory) {
        if (part.kind === 'warm' && part.text) {
          lines.push('Things you remember long-term: ' + part.text + '. Bring them up naturally.')
        } else if (part.kind === 'hot' && Array.isArray(part.turns) && part.turns.length) {
          const said = part.turns.map((t) => `user: "${t.u}" / you: "${t.r}"`).join('; ')
          lines.push('Just now: ' + said + '. Continue from there; do not repeat yourself.')
        }
      }
    } else if (Array.isArray(d.memories) && d.memories.length) {
      lines.push('Recent exchanges you remember: ' + d.memories.slice(-3).map((m) => `user: "${m.user}" / you: "${m.reply}"`).join('; '))
    }
    const recentActionEn = (Array.isArray(d.memories) ? d.memories.slice().reverse().find((m) => m && m.action) : null)
    if (recentActionEn) {
      lines.push(`Earlier the user said they were going to (${recentActionEn.action.label}). If it was recent, you may ask how it went - do not nag.`)
    }
    if (hasMood) {
      lines.push(`Your mood right now: ${Math.round(mood)}/100 (${labelOf(mood)})` +
        (dimText ? `; feelings: ${dimText}` : '') +
        (req?.reason ? `; reason: ${String(req.reason).slice(0, 160)}` : ''))
    }
    if (emo && emo.workspace) lines.push('What the user is doing in DSH right now: ' + String(emo.workspace).slice(0, 120) + ' (context only; do not repeat it back.)')
    if (busy) lines.push('(The user is working inside DSH right now: keep it short and do not disturb.)')
    lines.push('Reply in 1–3 short spoken sentences, plain text, no markdown, no lists, never call yourself an AI.')
  }
  return lines.join('\n')
}

async function readJson(file) {
  const raw = await fs.readFile(file, 'utf8')
  return JSON.parse(raw)
}

async function writeJsonAtomic(file, data) {
  const tmp = `${file}.${process.pid}.tmp`
  await fs.writeFile(tmp, JSON.stringify(data), 'utf8')
  await fs.rename(tmp, file)
}

async function pickTarget(ctx, config, req) {
  const wanted = req?.model || config.personaModel
  const providers = (ctx.llm?.listProviders?.() || [])
  const list = providers.length ? providers : [{ id: 'default' }]
  for (const p of list) {
    let models = []
    try { models = (await ctx.llm.listModels?.(p.id)) || [] } catch { models = [] }
    if (!models.length) continue
    if (wanted) {
      const hit = models.find((m) => m.id === wanted || m.name === wanted)
      if (hit) return { provider: p.id, model: hit.id }
    }
    const chat = models.find((m) => /chat|flash|v4|deepseek/i.test(`${m.id} ${m.name || ''}`))
    return { provider: p.id, model: (chat || models[0]).id }
  }
  return null
}

async function answer(ctx, config, req, outFile) {
  // 长期情绪：读盘 → 时间漂移 → 生成回复 → 依据这次对话更新 → 落盘
  const settings = await readPetSettings()
  const modelPref = (settings?.model || '').trim()
  const target = await pickTarget(ctx, config, modelPref ? { ...req, model: modelPref } : req)
  const personaRaw = await readJsonOrNull(path.join(DSH_HOME, 'feiyu-mood', 'config.json'))
  const persona = {
    petName: personaRaw?.petName || personaRaw?.selfName || '小鱼',
    ownerName: personaRaw?.ownerName || personaRaw?.userName || '你',
    // 关系设定可选：由使用者在自己的配置层填写，默认留空＝原样
    relationNote: typeof config?.persona?.relationNote === 'string' ? config.persona.relationNote.trim() : '',
  }
  const memCfg = (settings && settings.memory) || {}
  const memEnabled = memCfg.enabled !== false
  const mem = memEnabled ? await loadMemory(ROOT) : null
  const memParts = mem ? memoryBlock(mem, { keepTurns: memCfg.keepTurns, warmPoints: memCfg.warmPoints }) : null
  const emoPrev = drift(await loadEmotion(ROOT))
  const moodCtx = { ...emoPrev, busy: !!(req?.busy) }
  if (settings && settings.knowWorkspace) moodCtx.workspace = await readWorkspaceHint()
  const lastTurnAt = (mem && Array.isArray(mem.turns) && mem.turns.length)
    ? Number(mem.turns[mem.turns.length - 1].at) || 0
    : Number(emoPrev && emoPrev.updatedAt) || 0
  const system = buildSystem(req, persona, moodCtx, memParts, { lastAt: lastTurnAt })
  const messages = [{
    role: 'user',
    id: randomUUID(),
    content: [{ type: 'text', text: String(req?.text || '') }],
    source: { kind: 'plugin', plugin: 'dsh-feiyu-bridge' },
  }]
  log(`time now, lastTurnAt=${lastTurnAt}`)
  const out = { id: req.id, text: '', done: false, provider: target?.provider, model: target?.model }
  if (!target) {
    out.error = 'no-model'
    await writeJsonAtomic(outFile, out)
    return
  }
  let buffer = ''
  let lastFlush = 0
  const flush = async (force) => {
    const now = Date.now()
    if (!force && now - lastFlush < 180) return
    lastFlush = now
    out.text = buffer
    try { await writeJsonAtomic(outFile, out) } catch { /* 挂件可能正在读，下一轮再写 */ }
  }
  try {
    for await (const chunk of ctx.llm.stream({
      provider: target.provider,
      model: target.model,
      system,
      messages,
      maxTokens: Number(config.maxTokens) || 600,
      temperature: Number(config.temperature) || 0.75,
    })) {
      if (!chunk) continue
      if (chunk.type === 'text-delta') { buffer += chunk.text; await flush(false) }
      if (chunk.type === 'finish' && chunk.reason?.kind === 'error') {
        out.error = chunk.reason?.failure?.message || 'stream-error'
        break
      }
    }
  } catch (e) {
    out.error = String(e && e.message || e)
  }
  out.text = (buffer || '').trim()
  // 依据这一轮对话更新长期情绪；失败不影响回复本身。
  try {
    const { emotion } = afterChat(emoPrev, { text: req?.text, reply: out.text, mood: req?.mood })
    await saveEmotion(ROOT, emotion)
    const dimsOut = {}
    for (const k of DIM_KEYS) dimsOut[k] = Math.round(Number((emotion.dims || {})[k]) || 0)
    out.emotion = {
      valence: Math.round(emotion.valence),
      energy: Math.round(emotion.energy),
      affection: Math.round(emotion.affection),
      trust: Math.round(emotion.trust),
      relation: emotion.relation,
      chatCount: emotion.chatCount,
      moodView: emotion.moodView,
      dims: dimsOut,
    }
  } catch (e) {
    log('emotion save failed: ' + (e && e.message))
  }
  out.done = true
  await flush(true)
  log(`answered ${req.id} ${target.provider}/${target.model} ${out.text.length}B${out.error ? ' err=' + out.error : ''}`)

  // 热层：把这一轮记下来；满了就把这一段时间压成温层要点（回复已经送到挂件，压缩的延迟用户看不到）
  if (memEnabled && mem && out.text) {
    try {
      pushTurn(mem, req?.text, out.text)
      await saveMemory(ROOT, mem)
      const every = Math.max(2, Number(memCfg.compressEvery) || 8)
      if (dueTurns(mem, every)) {
        const due = takeDue(mem)
        const points = await compressWithModel(ctx, target, due, mem.warm, { maxPoints: memCfg.maxPoints })
        commitWarm(mem, points)
        await saveMemory(ROOT, mem)
        log(`memory compressed ${due.length} turns -> ${points.length} points`)
      }
    } catch (e) {
      log('memory error: ' + (e && e.message))
    }
  }
}

/** 挂件的设置文件（由桌面挂件写入，桥只读）。 */
function petSettingsFile() {
  return path.join(ROOT, '..', 'pet-settings.json')
}

async function readPetSettings() {
  return (await readJsonOrNull(petSettingsFile())) || null
}

/** “知道我在忙什么”：从 feiyu-mood 的心��缓存里拿一句对方在 DSH 里做过的事。 */
async function readWorkspaceHint() {
  try {
    const st = JSON.parse(await fs.readFile(path.join(DSH_HOME, 'feiyu-mood', 'state.json'), 'utf8'))
    const moods = (st && st.moods) || {}
    const keys = Object.keys(moods)
    for (const k of keys) {
      const e = moods[k]
      if (e && typeof e.lastReason === 'string' && e.lastReason.trim()) return e.lastReason.trim()
    }
  } catch { /* ignore */ }
  return ''
}

async function readJsonOrNull(file) {
  try { return await readJson(file) } catch { return null }
}

async function tick(ctx, config, state) {
  // 心跳：挂件据此判断"桥在不在"（DSH 是否在后台运行、插件是否已加载）
  try {
    await fs.mkdir(INBOX, { recursive: true })
    await fs.mkdir(OUTBOX, { recursive: true })
  } catch { return }
  try {
    await writeJsonAtomic(ALIVE, { ts: Date.now(), pid: process.pid, version: '0.1.0' })
  } catch { /* ignore */ }

  // 手动拉起挂件：写一个 spawn.req，Host 里的桥会帮忙起（这样挂件不是会话的后台任务，
  // 退出 DSH 时不会弹"中断后台任务"的确认框）。
  // watchdog: bring the pet back if its process died (so it can always be reopened)
  if (Date.now() - (state.lastWatchdog || 0) > WATCHDOG_MS) {
    state.lastWatchdog = Date.now()
    try {
      const pidFile = config.widgetPid || path.join(ROOT, '..', 'widget.pid')
      let aliveW = false
      if (existsSync(pidFile)) {
        const pid = Number(String(await fs.readFile(pidFile, 'utf8')).trim())
        if (pid > 0) {
          try { process.kill(pid, 0); aliveW = true } catch { aliveW = false }
        }
      }
      if (!aliveW) {
        const r = autoStartWidget({ ...config, force: true })
        log('watchdog respawn: ' + JSON.stringify(r))
      }
    } catch (e) { log('watchdog error: ' + (e && e.message)) }
  }

  const spawnReq = path.join(ROOT, 'spawn.req')
  if (existsSync(spawnReq)) {
    try { await fs.unlink(spawnReq) } catch { /* ignore */ }
    log('spawn.req received')
    try { autoStartWidget({ ...config, force: true }) } catch (e) { log('spawn.req error: ' + (e && e.message)) }
  }

  if (state.busy) return
  let files = []
  try { files = (await fs.readdir(INBOX)).filter((f) => f.endsWith('.json')) } catch { return }
  if (!files.length) return
  files.sort()
  const file = path.join(INBOX, files[0])
  state.busy = true
  try {
    const req = await readJson(file)
    if (!req?.id) { await fs.unlink(file).catch(() => {}); return }
    const outFile = path.join(OUTBOX, req.id + '.json')
    await answer(ctx, config, req, outFile)
    await fs.unlink(file).catch(() => {})
  } catch (e) {
    log('tick error: ' + (e && e.message))
    await fs.unlink(file).catch(() => {})
  } finally {
    state.busy = false
  }
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true } catch (e) {
    // EPERM 说明进程存在但没权限探查，仍然算活着
    return !!(e && e.code === 'EPERM')
  }
}

function instanceLocked(lockFile) {
  // The widget holds widget.lock exclusively; skip spawning a second copy.
  try {
    if (!existsSync(lockFile)) return false
    const fd = openSync(lockFile, 'r+')
    closeSync(fd)
    return false
  } catch { return true }
}

function widgetRunning(pidFile) {
  try {
    if (!existsSync(pidFile)) return false
    const pid = Number(readFileSync(pidFile, 'utf8').trim())
    return Number.isFinite(pid) && pid > 0 && processAlive(pid)
  } catch { return false }
}

/**
 * DSH 启动时顺手把桌面挂件拉起来：
 * 挂件本身是独立进程，如果它是由某次会话/终端拉起的，DSH 重启后可能已经被一起回收，
 * 这里用 wscript + launch.vbs 脱离父进程树启动，并靠 widget.pid 防重复。
 */
export function autoStartWidget(cfg) {
  if (cfg.autoStartWidget === false) return { skipped: 'disabled' }
  const vbs = cfg.widgetVbs || (cfg.dir ? path.join(cfg.dir, '..', 'launch.vbs') : '')
  const pidFile = cfg.widgetPid || (cfg.dir ? path.join(cfg.dir, '..', 'widget.pid') : '')
  if (!vbs || !existsSync(vbs)) return { skipped: 'no-vbs', vbs }
  if (pidFile && widgetRunning(pidFile) && !cfg.force) return { skipped: 'running' }
  const lockFile = pidFile ? path.join(path.dirname(pidFile), 'widget.lock') : ''
  if (lockFile && instanceLocked(lockFile)) return { skipped: 'locked' }
  try {
    const child = spawn('wscript.exe', [vbs], { detached: true, stdio: 'ignore', windowsHide: true })
    child.unref()
    log('widget spawned via ' + vbs)
    return { spawned: child.pid }
  } catch (e) {
    log('widget spawn failed: ' + (e && e.message))
    return { error: String(e && e.message) }
  }
}

export function apply(ctx, config = {}) {
  const cfg = { intervalMs: 400, maxTokens: 600, temperature: 0.75, hideInAppWidget: true, autoStartWidget: true, ...config }
  useRoot(cfg.dir)

  // 桌面挂件已经在跑的时候，把应用里的右下角挂饰藏掉，免得两个叠在一起。
  if (cfg.hideInAppWidget !== false) {
    ctx.effect(() => {
      const off = ctx.on('webserver/index-inject', (table) => {
        log('index-inject: hiding in-app widget')
        table.push({
          kind: 'style',
          text: '/* dsh-feiyu-bridge: 桌面挂件接管，隐藏应用内挂饰 */\\n' +
            '.fm-widget,.fm-mini,.fm-panel,[class^="fm-"],[class*=" fm-"]{display:none !important}',
        })
      })
      return () => { try { off && off() } catch { /* ignore */ } }
    })
  }

  // Host 起来 4 秒后再拉挂件，避开启动高峰。
  ctx.effect(() => {
    const t = setTimeout(() => {
      try { autoStartWidget(cfg) } catch (e) { log('autostart error: ' + (e && e.message)) }
    }, 4000)
    return () => clearTimeout(t)
  })
  const state = { busy: false }
  ctx.effect(() => {
    log('bridge started, root=' + ROOT)
    const timer = setInterval(() => { void tick(ctx, cfg, state) }, Math.max(120, Number(cfg.intervalMs) || 400))
    return () => clearInterval(timer)
  })
}
