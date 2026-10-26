/**
 * dsh-feiyu-bridge / memory.js — 桌宠的“热层 + 温层”记忆。
 *
 * 热层：最近几轮原话（截断后放进 system prompt，保证接得住上一句）。
 * 温层：每聊满 compressEvery 轮，把这段时间的对话压成几条要点存起来，
 *       之后只带要点、不带原文 —— 这是省 token 的关键。
 *
 * 文件：<bridge>/memory.json
 *   { version, turns:[{u,r,at}], warm:[{text,at}], compressedUpTo, lastCompressAt }
 */
import { promises as fs } from 'node:fs'
import path from 'node:path'

const MAX_TURNS = 40      // 落盘保留的原始轮数
let FILE_NAME = 'memory.json'

export function memoryFile(root) {
  return path.join(root, FILE_NAME)
}

function clip(s, n) {
  const t = String(s == null ? '' : s).replace(/\s+/g, ' ').trim()
  return t.length > n ? t.slice(0, n) + '…' : t
}

export function emptyMemory() {
  return { version: 1, turns: [], warm: [], compressedUpTo: 0, lastCompressAt: 0 }
}

export function normalizeMemory(raw) {
  const base = emptyMemory()
  if (!raw || typeof raw !== 'object') return base
  const turns = Array.isArray(raw.turns) ? raw.turns.filter((t) => t && (t.u || t.r)) : []
  const warm = Array.isArray(raw.warm) ? raw.warm.filter((w) => w && w.text) : []
  return {
    version: 1,
    turns: turns.slice(-MAX_TURNS).map((t) => ({ u: clip(t.u, 80), r: clip(t.r, 160), at: Number(t.at) || 0 })),
    warm: warm.slice(-12).map((w) => ({ text: clip(w.text, 120), at: Number(w.at) || 0 })),
    compressedUpTo: Math.max(0, Math.min(Number(raw.compressedUpTo) || 0, turns.length)),
    lastCompressAt: Number(raw.lastCompressAt) || 0,
  }
}

export async function loadMemory(root) {
  try {
    const raw = JSON.parse(await fs.readFile(memoryFile(root), 'utf8'))
    return normalizeMemory(raw)
  } catch {
    return emptyMemory()
  }
}

export async function saveMemory(root, mem) {
  const file = memoryFile(root)
  const tmp = `${file}.${process.pid}.tmp`
  await fs.writeFile(tmp, JSON.stringify(mem), 'utf8')
  await fs.rename(tmp, file)
}

export function pushTurn(mem, user, reply) {
  mem.turns.push({ u: clip(user, 80), r: clip(reply, 160), at: Date.now() })
  if (mem.turns.length > MAX_TURNS) {
    const drop = mem.turns.length - MAX_TURNS
    mem.turns = mem.turns.slice(drop)
    mem.compressedUpTo = Math.max(0, mem.compressedUpTo - drop)
  }
  return mem
}

/** 还没被压成要点的轮数到没到阈值 */
export function dueTurns(mem, every) {
  const n = Math.max(2, Number(every) || 8)
  return mem.turns.length - mem.compressedUpTo >= n
}

/** 取出等待压缩的那一段（不动 mem，调用方压完再推进 compressedUpTo） */
export function takeDue(mem) {
  return mem.turns.slice(mem.compressedUpTo)
}

/** 压完：推进指针 + 追加要点 */
export function commitWarm(mem, points) {
  const now = Date.now()
  for (const p of points) {
    const text = clip(p, 120)
    if (text) mem.warm.push({ text, at: now })
  }
  if (mem.warm.length > 12) mem.warm = mem.warm.slice(-12)
  mem.compressedUpTo = mem.turns.length
  mem.lastCompressAt = now
  return mem
}

/** 给 system prompt 用的记忆段落 */
export function memoryBlock(mem, opts = {}) {
  const keepTurns = Math.max(0, Math.min(6, Number(opts.keepTurns) || 3))
  const warmPoints = Math.max(0, Math.min(6, Number(opts.warmPoints) || 4))
  const lines = []
  const warm = (mem?.warm || []).slice(-warmPoints)
  if (warm.length) {
    lines.push({ kind: 'warm', text: warm.map((w) => w.text).join('；') })
  }
  const hot = (mem?.turns || []).slice(-keepTurns)
  if (hot.length) {
    lines.push({ kind: 'hot', turns: hot })
  }
  return lines
}

/** 没有模型可用时的兜底：规则抽要点 */
export function fallbackDigest(turns) {
  const out = []
  for (const t of turns) {
    const u = clip(t.u, 40)
    const r = clip(t.r, 40)
    if (u && r) out.push(`对方提到“${u}”，你回应“${r}”`)
    else if (u) out.push(`对方提到“${u}”`)
    if (out.length >= 4) break
  }
  return out
}

/**
 * 用模型把一段对话压成 3–5 条要点。
 * 失败时退回 fallbackDigest，保证永远不会因为压缩失败而丢记忆。
 */
export async function compressWithModel(ctx, target, turns, warmSoFar, opts = {}) {
  const maxPoints = Math.max(3, Math.min(6, Number(opts.maxPoints) || 5))
  const sys = [
    '你是一个记忆整理器。把下面这段“桌面聊天记录”压缩成 3–5 条要点，供以后回忆。',
    '要求：每条不超过 30 个字；只写事实与情绪（对方在忙什么、喜欢什么、说过的承诺、聊过的话题、情绪变化）；',
    '不要编号、不要分点符号、不要引号、不要复述原话，用“；”分隔，只输出要点本身。',
  ].join('')
  const body = turns.map((t, i) => `${i + 1}. 对方：${t.u}\n你：${t.r}`).join('\n')
  const context = (warmSoFar || []).slice(-3).map((w) => w.text).join('；')
  const userText = (context ? `已有的旧要点：${context}\n\n` : '') + `这次要压缩的对话：\n${body}`
  if (!target || !ctx?.llm?.stream) return fallbackDigest(turns)
  let buf = ''
  let err = null
  try {
    for await (const chunk of ctx.llm.stream({
      provider: target.provider,
      model: target.model,
      system: sys,
      messages: [{ role: 'user', id: 'mem-' + Date.now(), content: [{ type: 'text', text: userText }] }],
      maxTokens: 220,
      temperature: 0.3,
    })) {
      if (!chunk) continue
      if (chunk.type === 'text-delta') buf += chunk.text
      if (chunk.type === 'finish' && chunk.reason?.kind === 'error') {
        err = chunk.reason?.failure?.message || 'stream-error'
        break
      }
    }
  } catch (e) {
    err = String((e && e.message) || e)
  }
  if (err || !buf.trim()) return fallbackDigest(turns)
  const split = (s) => s.replace(/^[\s\-*·•\d一二三四五六七八九十.、)）]+/, '').trim()
  const tidy = (s) => {
    let t = split(s).replace(/^对方(最近|刚才|先前|说|提到|喜欢|在)/, '').trim()
    t = t.replace(/[，,\s]+$/, '')
    if (t.length <= 40) return t
    // 太长就用逗号切，取前两小句，凑成一句短要点
    const parts = t.split(/[，,]/).map((p) => p.trim()).filter(Boolean)
    let out = ''
    for (const p of parts) {
      if ((out + (out ? '，' : '') + p).length > 40) break
      out = out ? out + '，' + p : p
    }
    if (!out) out = t.slice(0, 40)
    return out
  }
  let points = buf
    .split(/[；;\n。]+/)
    .map(tidy)
    .filter((s) => s.length >= 4 && s.length <= 44)
    .slice(0, maxPoints)
  if (points.length < 3) {
    for (const p of fallbackDigest(turns)) {
      if (points.length >= Math.min(3, maxPoints)) break
      if (!points.includes(p)) points.push(p)
    }
  }
  return points.length ? points : fallbackDigest(turns)
}
