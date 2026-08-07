// Coalesce staggered multi-parameter IV samples into one row per hour when
// each parameter appears at most once in that hour (e.g. temp at :00, gage
// and flow at :15). When any parameter repeats inside the hour (typical
// :00 / :30 full IV), keep the minute-level rows untouched.

/**
 * @typedef {{ t: string, values: Record<string, number|null|undefined>, sort: number }} ReadingRow
 */

/**
 * @param {ReadingRow[]} rows - minute-level rows for a single day (any order)
 * @param {string[]} columnKeys - parameter keys expected in the table
 * @param {(isoTimestamp: string) => string} hourKeyFor - maps a row timestamp to an hour bucket
 * @returns {Array<ReadingRow & { status: "ok" | "warn" }>}
 */
export function coalesceHourlyReadings(rows, columnKeys, hourKeyFor) {
  const columns = Array.isArray(columnKeys) ? columnKeys.filter(Boolean) : []
  const input = Array.isArray(rows) ? rows : []
  if (!input.length) return []

  const byHour = new Map()
  input.forEach((row) => {
    if (!row || row.t == null) return
    const hourKey = hourKeyFor(row.t)
    if (!hourKey) return
    if (!byHour.has(hourKey)) byHour.set(hourKey, [])
    byHour.get(hourKey).push(row)
  })

  const coalesced = []
  byHour.forEach((hourRows) => {
    coalesced.push(...coalesceHour(hourRows, columns))
  })

  return coalesced
    .sort((a, b) => b.sort - a.sort)
    .map((row) => withStatus(row, columns))
}

function coalesceHour(hourRows, columns) {
  const rows = hourRows
    .map((row) => ({
      t: row.t,
      sort: Number.isFinite(row.sort) ? row.sort : Date.parse(row.t),
      values: { ...(row.values || {}) }
    }))
    .filter((row) => Number.isFinite(row.sort))
    .sort((a, b) => a.sort - b.sort)

  if (rows.length <= 1) return rows

  const paramCounts = new Map()
  rows.forEach((row) => {
    Object.entries(row.values).forEach(([key, value]) => {
      if (value == null || !columns.includes(key)) return
      paramCounts.set(key, (paramCounts.get(key) || 0) + 1)
    })
  })

  // Any repeated parameter means distinct samples in this hour — do not merge.
  for (const count of paramCounts.values()) {
    if (count > 1) return rows
  }

  const values = {}
  let latest = rows[0]
  rows.forEach((row) => {
    Object.entries(row.values).forEach(([key, value]) => {
      if (value == null || !columns.includes(key)) return
      if (values[key] == null) values[key] = value
    })
    if (row.sort >= latest.sort) latest = row
  })

  return [{ t: latest.t, sort: latest.sort, values }]
}

function withStatus(row, columns) {
  const present = columns.filter((key) => row.values[key] != null).length
  return {
    ...row,
    status: columns.length > 0 && present === columns.length ? "ok" : "warn"
  }
}
