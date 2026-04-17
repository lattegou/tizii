import axios, { AxiosInstance, AxiosRequestConfig, ResponseType } from 'axios'
import type { HttpClient, HttpRequestOptions, HttpResponse } from './httpClient'

function mapResponseType(rt?: string): ResponseType | undefined {
  if (rt === 'arraybuffer') return 'arraybuffer'
  if (rt === 'json') return 'json'
  return undefined
}

function buildAxiosConfig(url: string, options: HttpRequestOptions = {}): AxiosRequestConfig {
  const {
    method = 'GET',
    headers = {},
    body,
    proxy,
    timeout = 30000,
    responseType,
    maxRedirects = 20
  } = options

  const config: AxiosRequestConfig = {
    url,
    method,
    headers,
    timeout,
    maxRedirects,
    responseType: mapResponseType(responseType),
    validateStatus: () => true
  }

  if (body) {
    config.data = body
  }

  if (proxy) {
    config.proxy = {
      protocol: proxy.protocol === 'socks5' ? 'http' : proxy.protocol,
      host: proxy.host,
      port: proxy.port
    }
  } else if (proxy === false) {
    config.proxy = false
  }

  return config
}

function toHttpResponse<T>(axiosRes: import('axios').AxiosResponse): HttpResponse<T> {
  const headers: Record<string, string> = {}
  for (const [k, v] of Object.entries(axiosRes.headers || {})) {
    if (typeof v === 'string') headers[k] = v
    else if (Array.isArray(v)) headers[k] = v.join(', ')
  }
  return {
    data: axiosRes.data as T,
    status: axiosRes.status,
    statusText: axiosRes.statusText,
    headers,
    url: axiosRes.config?.url || ''
  }
}

function prepareBody(
  data: unknown,
  headers: Record<string, string>
): { body: string | Buffer; headers: Record<string, string> } {
  if (typeof data === 'string' || Buffer.isBuffer(data)) {
    return { body: data as string | Buffer, headers }
  }
  const newHeaders = { ...headers }
  if (!newHeaders['content-type']) {
    newHeaders['content-type'] = 'application/json'
  }
  return { body: JSON.stringify(data), headers: newHeaders }
}

export class NodeHttpClient implements HttpClient {
  private instance: AxiosInstance

  constructor() {
    this.instance = axios.create()
  }

  async request<T = unknown>(url: string, options?: HttpRequestOptions): Promise<HttpResponse<T>> {
    const config = buildAxiosConfig(url, options)
    const res = await this.instance.request(config)
    return toHttpResponse<T>(res)
  }

  async get<T = unknown>(
    url: string,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>> {
    return this.request<T>(url, { ...options, method: 'GET' })
  }

  async post<T = unknown>(
    url: string,
    data: unknown,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>> {
    const { body, headers } = prepareBody(data, options?.headers || {})
    return this.request<T>(url, { ...options, method: 'POST', body, headers })
  }

  async put<T = unknown>(
    url: string,
    data: unknown,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>> {
    const { body, headers } = prepareBody(data, options?.headers || {})
    return this.request<T>(url, { ...options, method: 'PUT', body, headers })
  }

  async del<T = unknown>(
    url: string,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>> {
    return this.request<T>(url, { ...options, method: 'DELETE' })
  }

  async patch<T = unknown>(
    url: string,
    data: unknown,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>> {
    const { body, headers } = prepareBody(data, options?.headers || {})
    return this.request<T>(url, { ...options, method: 'PATCH', body, headers })
  }
}

export function createNodeHttpClient(): HttpClient {
  return new NodeHttpClient()
}
