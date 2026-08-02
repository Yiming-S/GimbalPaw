export const TEST_STEP_DEGREES = 5;
export const TEST_DURATION_TENTHS = 10;

function int16LE(value: number): number[] {
  const normalized = value & 0xffff;
  return [normalized & 0xff, (normalized >>> 8) & 0xff];
}

export function crc16(bytes: number[]): number {
  let crc = 0xdf0c;

  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) !== 0 ? (crc >>> 1) ^ 0x8408 : crc >>> 1;
    }
  }

  return crc & 0xffff;
}

export function buildRotationMessage({
  yaw,
  pitch,
  roll = 0,
  mode = "relative",
  time = TEST_DURATION_TENTHS,
}: {
  yaw: number;
  pitch: number;
  roll?: number;
  mode?: "relative" | "absolute" | "speed";
  time?: number;
}): Uint8Array {
  const header = [0x55, 0x15, 0x04, 0xa9];
  const body = [0x02, 0x04, 0x01, 0x00, 0x00, 0x04];
  body.push(mode === "speed" ? 0x0c : 0x14);

  const modeByte = mode === "relative" ? 0x04 : mode === "absolute" ? 0x05 : 0x80;
  const payload = [
    ...int16LE(yaw),
    ...int16LE(roll),
    ...int16LE(pitch),
    modeByte,
    Math.max(0, Math.min(255, time)),
  ];
  const checksum = crc16([...body, ...payload]);

  return Uint8Array.from([
    ...header,
    ...body,
    ...payload,
    checksum & 0xff,
    (checksum >>> 8) & 0xff,
  ]);
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(" ");
}
