// GeolocationPositionError codes: PERMISSION_DENIED=1, POSITION_UNAVAILABLE=2, TIMEOUT=3
const PERMISSION_DENIED = 1
const TIMEOUT = 3

export function geolocationErrorMessage(error) {
  if (typeof navigator === "undefined" || !navigator.geolocation) {
    return {
      title: "Location not supported",
      body: "Your browser doesn’t support location services. Search for a station by name or browse the map instead."
    }
  }

  if (error?.code === PERMISSION_DENIED) {
    return {
      title: "Location permission denied",
      body: "Allow location access in your browser settings to use this feature, or search for a station by name instead."
    }
  }

  if (error?.code === TIMEOUT) {
    return {
      title: "Location request timed out",
      body: "We couldn’t determine your position in time. Try again, or search for a station by name."
    }
  }

  return {
    title: "Couldn’t get your location",
    body: "Your device couldn’t determine your position. Try again, or search for a station by name."
  }
}
