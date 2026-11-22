// Preload installs desktopBridge before web code runs, so module-load detection is reliable.
export const isElectron = typeof window !== "undefined" && window.desktopBridge !== undefined;

// Only a macOS desktop build whose lock-screen helper supports this OS version reports this.
export const isLockScreenActivityAvailable =
  isElectron && window.desktopBridge?.getLockScreenActivityAvailable?.() === true;
