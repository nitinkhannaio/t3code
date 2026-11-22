export function isLockScreenPreviewVersion(version: string): boolean {
  return /^[^-+]+-preview\.\d{8}\.\d+\.lockscreen$/.test(version);
}
