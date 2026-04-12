const EARTH_RADIUS_M = 6_371_000;

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

/**
 * Haversine distance between two GPS coordinates.
 * Returns distance in meters.
 */
export function haversineMeters(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number
): number {
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);

  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;

  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Filter items within a radius of a point.
 * Each item must have lat/lng fields.
 */
export function filterWithinRadius<T extends { lat: number; lng: number }>(
  items: T[],
  centerLat: number,
  centerLng: number,
  radiusMeters: number
): T[] {
  return items.filter(
    (item) =>
      haversineMeters(centerLat, centerLng, item.lat, item.lng) <= radiusMeters
  );
}
