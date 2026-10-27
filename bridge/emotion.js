import fs from 'node:fs/promises'
import path from 'node:path'

/**
 * 小鲸鱼的情绪系统：亲密度 / 信任 / 精力 / 愉悦度 / 关系阶段 / 情绪记忆。
 * 全部落盘在 bridge/emotion.json，重启不丢；聊天会改变情绪，时间会衰减和恢复。
 */

const STATE_VERSION = 2
const MAX_MEMORIES = 14

// 七维情绪：桌面聊天里每一句都会往对应维度加一点，平时按半衰期回落。
export const DIM_KEYS = ['happy', 'calm', 'sweet', 'heartache', 'worry', 'sad', 'jealous']
const DIM_TAGS = {
  happy: ['praise', 'happy', 'thanks'],
  calm: ['greeting', 'question'],
  sweet: ['affection', 'playful'],
  heartache: ['tired', 'sad'],
  worry: ['busy', 'tired'],
  sad: ['sad', 'complaint'],
  jealous: ['complaint', 'busy'],
}

function emptyDims() {
  const o = {}
  for (const k of DIM_KEYS) o[k] = 0
  return o
}

function moodViewOf(e) {
  const v = Number(e && e.valence) || 0
  const a = Number(e && e.affection) || 0
  return Math.max(1, Math.min(100, Math.round(50 + v * 0.45 + (a - 50) * 0.12)))
}

// 关键词打标：轻量启发式，不额外花模型调用。
const TAGS = [
  { tag: 'praise', w: 6, re: /(可爱|好可爱|乖|厉害|好棒|真棒|喜欢你|爱你|想你|聪明|贴心|温柔|萌|好看)/ },
  { tag: 'thanks', w: 5, re: /(谢谢|多谢|感谢|thank)/i },
  { tag: 'affection', w: 7, re: /(抱抱|摸摸|亲亲|贴贴|陪我|和你聊|喜欢你陪)/ },
  { tag: 'complaint', w: -9, re: /(滚|烦死|闭嘴|废物|垃圾|讨厌你|蠢|笨死|丑|闭嘴)/ },
  { tag: 'busy', w: -2, re: /(在忙|忙死|没空|别烦|等下|一会儿说|工作|加班|开会|写代码|debug|赶工)/i },
  { tag: 'tired', w: -3, re: /(累|困|好累|撑不住|熬夜|没睡|加班到|烦|难受|压力)/ },
  { tag: 'sad', w: -4, re: /(难过|伤心|想哭|委屈|失落|孤独|emo|崩溃)/ },
  { tag: 'happy', w: 5, re: /(开心|高兴|太好了|哈哈|笑死|爽|成了|搞定|通过了)/ },
  { tag: 'greeting', w: 2, re: /^(在吗|早上好|晚上好|晚安|早安|嗨|hi|hello|哈喽)/i },
  { tag: 'playful', w: 3, re: /(嘿嘿|嘿嘿嘿|~|～|调皮|逗你|开玩笑|傲娇)/ },
]

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v))
}

function now() {
  return Date.now()
}

export function defaultEmotion() {
  return {
    version: STATE_VERSION,
    affection: 12,
    trust: 18,
    energy: 82,
    valence: 10,
    relation: 'stranger',
    chatCount: 0,
    lastChatAt: 0,
    lastSeenAt: 0,
    streakDays: 1,
    dims: emptyDims(),
    moodView: 50,
    memories: [],
    updatedAt: 0,
  }
}

export function relationOf(e) {
  const a = Number(e?.affection) || 0
  if (a >= 78) return 'clingy'
  if (a >= 52) return 'close'
  if (a >= 26) return 'familiar'
  return 'stranger'
}

export const RELATION_TEXT = {
  stranger: '初次见面，还保持着礼貌的距离，会好奇但不会太黏',
  familiar: '已经是熟人了，会开玩笑、会撒娇，也会小小地闹脾气',
  close: '很亲近，说话随意，会惦记对方、偶尔闹小情绪后又自己贴回来',
  clingy: '非常黏人，会主动讨关注，被冷落会有点小委屈',
}

/** 时间流逝带来的自然变化：精力恢复、情绪回落、长时间没聊会想人。 */
export function drift(e, t = now()) {
  const out = { ...(e || defaultEmotion()) }
  const last = Number(out.updatedAt) || t
  const minutes = Math.max(0, (t - last) / 60000)
  if (minutes > 0) {
    out.energy = clamp(Number(out.energy) + Math.min(40, minutes * 0.75), 0, 100)
    // 愉悦度缓慢回落到各自的基线
    const baseline = out.relation === 'stranger' ? 8 : 22
    const k = Math.min(1, minutes / 180)
    out.valence = Number(out.valence) + (baseline - Number(out.valence)) * k
    // 太久没说话：想念 = 亲密度越高，愉悦度掉得越多（小小的委屈）
    const hoursSilent = (t - (Number(out.lastChatAt) || t)) / 3600000
    if (hoursSilent > 6 && out.relation !== 'stranger') {
      out.valence -= Math.min(10, (hoursSilent - 6) * 0.9)
    }
  }
  const dims = { ...emptyDims(), ...(out.dims || {}) }
  const decay = Math.exp(-minutes / 180 * Math.LN2)
  for (const k of DIM_KEYS) dims[k] = clamp(Number(dims[k]) * decay, 0, 100)
  out.dims = dims
  out.valence = clamp(Number(out.valence), -100, 100)
  out.energy = clamp(Number(out.energy), 0, 100)
  out.relation = relationOf(out)
  out.moodView = moodViewOf(out)
  out.updatedAt = t
  return out
}

function tagsOf(text) {
  const s = String(text || '')
  const hits = []
  let w = 0
  for (const t of TAGS) {
    if (t.re.test(s)) { hits.push(t.tag); w += t.w }
  }
  if (/[?？]/.test(s)) hits.push('question')
  return { hits, w }
}

/** 一次聊天之后更新情绪，返回 { emotion, memory }。 */
export function afterChat(prev, { text, reply, mood }) {
  const t = now()
  const e = drift(prev, t)
  const { hits, w } = tagsOf(text)

  let dValence = w
  const len = String(text || '').length
  if (len > 40) dValence += 1
  if (hits.includes('busy')) dValence -= 2
  // 对方在应付/敷衍时（很短、无情绪词），小委屈
  if (len <= 3 && hits.length === 0) dValence -= 2

  e.chatCount = (Number(e.chatCount) || 0) + 1
  e.affection = clamp(Number(e.affection) + 1.6 + (hits.includes('praise') || hits.includes('affection') ? 2.4 : 0) - (hits.includes('complaint') ? 4 : 0), 0, 100)
  e.trust = clamp(Number(e.trust) + (hits.includes('tired') || hits.includes('sad') ? 2.2 : 0.5) + (hits.includes('complaint') ? -2 : 0), 0, 100)
  e.energy = clamp(Number(e.energy) - 2.6 - (len > 80 ? 1 : 0), 0, 100)
  e.valence = clamp(Number(e.valence) + dValence * 0.7, -100, 100)
  if (Number.isFinite(Number(mood)) && Number(mood) > 0) {
    // 与 DSH 会话里的心情（feiyu-mood）做温和融合
    e.valence = clamp(Number(e.valence) * 0.7 + (Number(mood) - 50) * 0.6, -100, 100)
  }
  const dims = { ...emptyDims(), ...(e.dims || {}) }
  for (const k of DIM_KEYS) dims[k] = Number(dims[k]) * 0.88
  if (w > 0) dims.happy += 5 * Math.min(1, w / 6)
  for (const [k, tags] of Object.entries(DIM_TAGS)) {
    let hits2 = 0
    for (const tg of tags) if (hits.includes(tg)) hits2 += 1
    if (hits2) dims[k] += 3.2
  }
  if (hits.includes('complaint')) { dims.sad += 3; dims.jealous += 2 }
  if (hits.includes('tired')) dims.heartache += 2.5
  if (hits.includes('sad')) dims.sad += 3
  for (const k of DIM_KEYS) dims[k] = clamp(Math.round(dims[k] * 10) / 10, 0, 100)
  e.dims = dims
  e.moodView = moodViewOf(e)
  e.relation = relationOf(e)
  e.lastChatAt = t
  e.lastSeenAt = t

  const memory = {
    at: t,
    user: String(text || '').slice(0, 80),
    reply: String(reply || '').slice(0, 80),
    valence: Math.round(Number(e.valence)),
    tags: hits.slice(0, 4),
  }
  e.memories = [...(e.memories || []), memory].slice(-MAX_MEMORIES)
  e.updatedAt = t
  return { emotion: e, memory }
}

/** 把数字情绪翻译成给模型看的中文描述（不暴露原始数值）。 */
export function describe(e) {
  const emo = e || defaultEmotion()
  const v = Number(emo.valence) || 0
  const moodWord = v >= 55 ? '心情很好，话会多一点、语气轻快'
    : v >= 22 ? '心情不错，语气温和放松'
    : v >= -12 ? '心情平稳，正常聊天'
    : v >= -45 ? '有点低落，话少一点、语气软，但不至于消沉'
    : '情绪很低落，回复会短、会有点回避，被关心时又会软下来'
  const energy = Number(emo.energy) || 0
  const energyWord = energy >= 70 ? '精神很好'
    : energy >= 40 ? '有点懒懒的'
    : energy >= 18 ? '很困、反应慢半拍'
    : '困到快睡着了，字会少'
  const aff = Number(emo.affection) || 0
  const affWord = aff >= 78 ? '非常依赖对方，会主动撒娇讨关注，被冷落会委屈'
    : aff >= 52 ? '很亲近，会开玩笑、会闹小脾气再自己贴回来'
    : aff >= 26 ? '渐渐熟了，愿意分享自己的事'
    : '还比较客气，好奇但保持距离'
  return {
    moodWord, energyWord, affWord,
    relation: emo.relation || 'stranger',
    v, energy, aff,
    moodView: Number.isFinite(Number(emo.moodView)) ? Number(emo.moodView) : moodViewOf(emo),
    dims: { ...emptyDims(), ...(emo.dims || {}) },
    relationText: RELATION_TEXT[emo.relation] || RELATION_TEXT.stranger,
    memories: Array.isArray(emo.memories) ? emo.memories : [],
  }
}

const FILE = 'emotion.json'

export async function loadEmotion(root) {
  const file = path.join(root, FILE)
  try {
    const raw = await fs.readFile(file, 'utf8')
    const parsed = JSON.parse(raw)
    const base = defaultEmotion()
    return { ...base, ...parsed, memories: Array.isArray(parsed.memories) ? parsed.memories : [] }
  } catch {
    return defaultEmotion()
  }
}

export async function saveEmotion(root, e) {
  const file = path.join(root, FILE)
  const tmp = `${file}.${process.pid}.tmp`
  await fs.writeFile(tmp, JSON.stringify(e, null, 2), 'utf8')
  await fs.rename(tmp, file)
}
