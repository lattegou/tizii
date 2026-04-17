import dns from 'dns'
import axios from 'axios'

const DEFAULT_TIMEOUT_MS = 1500

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return await new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), timeoutMs)
    promise
      .then((value) => {
        clearTimeout(timer)
        resolve(value)
      })
      .catch((error) => {
        clearTimeout(timer)
        reject(error)
      })
  })
}

export async function isOnline(timeoutMs: number = DEFAULT_TIMEOUT_MS): Promise<boolean> {
  try {
    await withTimeout(dns.promises.resolve('dns.google'), timeoutMs)
    return true
  } catch {
    try {
      const response = await withTimeout(
        axios.get('https://www.gstatic.com/generate_204', {
          timeout: timeoutMs,
          validateStatus: () => true
        }),
        timeoutMs
      )
      return response.status >= 200 && response.status < 400
    } catch {
      return false
    }
  }
}
