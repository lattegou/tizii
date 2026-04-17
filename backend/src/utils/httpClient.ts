export interface HttpRequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH'
  headers?: Record<string, string>
  body?: string | Buffer
  proxy?:
    | {
        protocol: 'http' | 'https' | 'socks5'
        host: string
        port: number
      }
    | false
  timeout?: number
  responseType?: 'text' | 'json' | 'arraybuffer'
  followRedirect?: boolean
  maxRedirects?: number
}

export interface HttpResponse<T = unknown> {
  data: T
  status: number
  statusText: string
  headers: Record<string, string>
  url: string
}

export interface HttpClient {
  request<T = unknown>(url: string, options?: HttpRequestOptions): Promise<HttpResponse<T>>
  get<T = unknown>(
    url: string,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>>
  post<T = unknown>(
    url: string,
    data: unknown,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>>
  put<T = unknown>(
    url: string,
    data: unknown,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>>
  del<T = unknown>(
    url: string,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>>
  patch<T = unknown>(
    url: string,
    data: unknown,
    options?: Omit<HttpRequestOptions, 'method' | 'body'>
  ): Promise<HttpResponse<T>>
}

let defaultClient: HttpClient | null = null

export function setDefaultHttpClient(client: HttpClient): void {
  defaultClient = client
}

export function getHttpClient(): HttpClient {
  if (!defaultClient) throw new Error('HttpClient not initialized')
  return defaultClient
}
