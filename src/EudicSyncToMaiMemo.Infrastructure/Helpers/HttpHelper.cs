using System.Text;

using Microsoft.Extensions.Logging;

namespace EudicSyncToMaiMemo.Infrastructure.Helpers
{
    /// <summary>
    /// 基于 IHttpClientFactory 的 HTTP 请求实现
    /// </summary>
    public class HttpHelper(IHttpClientFactory httpClientFactory, ILogger<HttpHelper> logger) : IHttpHelper
    {
        private readonly HttpClient _httpClient = httpClientFactory.CreateClient();

        /// <inheritdoc />
        public async Task<string> GetAsync(
            string uri,
            Dictionary<string, string>? headers = null,
            CancellationToken cancellationToken = default)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);

            if (headers != null)
            {
                foreach (var header in headers)
                {
                    request.Headers.Add(header.Key, header.Value);
                }
            }

            using var response = await _httpClient.SendAsync(request, cancellationToken);
            await EnsureSuccessAsync(request, response, cancellationToken);

            return await response.Content.ReadAsStringAsync(cancellationToken);
        }

        /// <inheritdoc />
        public async Task<string> PostAsync(
            string uri,
            string requestJson,
            Dictionary<string, string>? headers = null,
            CancellationToken cancellationToken = default)
        {
            var content = new StringContent(requestJson, Encoding.UTF8, "application/json");
            using var request = new HttpRequestMessage(HttpMethod.Post, uri)
            {
                Content = content
            };

            if (headers != null)
            {
                foreach (var header in headers)
                {
                    request.Headers.Add(header.Key, header.Value);
                }
            }

            using var response = await _httpClient.SendAsync(request, cancellationToken);
            await EnsureSuccessAsync(request, response, cancellationToken);

            return await response.Content.ReadAsStringAsync(cancellationToken);
        }

        /// <inheritdoc />
        public async Task<(string response, Dictionary<string, string> cookie)> PostFoRmAsync(
            string uri,
            FormUrlEncodedContent formData,
            Dictionary<string, string>? headers = null,
            CancellationToken cancellationToken = default)
        {
            var handler = new HttpClientHandler
            {
                CookieContainer = new System.Net.CookieContainer()
            };

            using var httpClient = new HttpClient(handler);
            using var request = new HttpRequestMessage(HttpMethod.Post, uri)
            {
                Content = formData
            };

            if (headers != null)
            {
                foreach (var header in headers)
                {
                    request.Headers.Add(header.Key, header.Value);
                }
            }

            using var response = await httpClient.SendAsync(request, cancellationToken);

            await EnsureSuccessAsync(request, response, cancellationToken);
            string responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

            var cookieCollection = handler.CookieContainer.GetCookies(new Uri(uri));
            var cookies = cookieCollection
                .Cast<System.Net.Cookie>()
                .ToDictionary(cookie => cookie.Name, cookie => cookie.Value);

            return (responseBody, cookies);
        }

        private async Task EnsureSuccessAsync(
            HttpRequestMessage request,
            HttpResponseMessage response,
            CancellationToken cancellationToken)
        {
            if (response.IsSuccessStatusCode)
            {
                return;
            }

            string body;
            try
            {
                body = await response.Content.ReadAsStringAsync(cancellationToken);
            }
            catch (Exception ex) when (ex is HttpRequestException or IOException)
            {
                // 不记录读取异常的 Message，它也可能包含未经脱敏的 URL 或响应内容。
                body = "[无法读取错误响应正文]";
            }

            var diagnostics = await HttpErrorDiagnostics.CreateAsync(request, body, cancellationToken);
            logger.LogError(
                "HTTP 请求失败：{Method} {RequestUrl}；状态码 {StatusCode} ({Status})；服务器错误：{ResponseBody}",
                request.Method.Method,
                diagnostics.Url,
                (int)response.StatusCode,
                response.StatusCode,
                diagnostics.Body);

            // 上层也会记录异常；只携带已脱敏的信息，不附加原始响应或原始异常。
            throw new HttpRequestException(
                $"HTTP {(int)response.StatusCode} ({response.StatusCode}): {request.Method} {diagnostics.Url}; 服务器错误：{diagnostics.Body}",
                inner: null,
                statusCode: response.StatusCode);
        }
    }
}
