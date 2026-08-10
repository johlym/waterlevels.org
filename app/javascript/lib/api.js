// Headers required by Api::BaseController / FirstPartyApiRequest for
// first-party Stimulus fetches against `/api/*`.
export const FIRST_PARTY_API_HEADERS = {
  Accept: "application/json",
  "X-WaterLevels-Client": "web"
}

export function firstPartyApiFetch(url, options = {}) {
  return fetch(url, {
    ...options,
    headers: {
      ...FIRST_PARTY_API_HEADERS,
      ...(options.headers || {})
    },
    mode: "same-origin",
    credentials: "same-origin",
    cache: options.cache ?? "no-store"
  })
}
